// (c) 2026 and onwards The vChewing Project (MIT-NTL License).
// ====================
// This code is released under the MIT license (SPDX-License-Identifier: MIT)
// ... with NTL restriction stating that:
// No trademark license is granted to use the trade names, trademarks, service
// marks, or product names of Contributor, except as required to fulfill notice
// requirements defined in MIT License.

import Accelerate
import Foundation

// MARK: - CharLM

/// 固定窗字元語言模型的推論實作。設計依據見 `DevLab/AICandidateSelection_Design.md` §4.3。
///
/// ```
/// 前 window 個字元索引
///     ↓ Embedding (vocabSize × embDim)
/// window × embDim
///     ↓ Linear + ReLU
///     ↓ Linear + ReLU
///     ↓ Linear                      （投影層）
/// embDim
///     ↓ × Eᵀ                        （輸出層與 embedding 綁定）
/// vocabSize 個 logit
/// ```
///
/// ## 為什麼分成 `hiddenState` / `logit` / `logSumExp` 三段
///
/// 設計文件 §4.3 主張「推論時只計算候選字那幾列」以取得約 780 倍的加速。
/// 那個加速**只在不需要正規化時成立**——log-softmax 的分母得掃過整個詞彙表。
///
/// 分母何時可以省掉，取決於要比較的候選之間上下文是否相同：
///
/// - **同一位置的單字候選**：所有候選共用同一組上下文，`logSumExp` 是共同常數，
///   比大小時會消掉。此時只需 `logit(hidden:token:)`，每個候選 embDim 次乘加。
/// - **多字候選**：第 2 個字起，各候選的上下文已經分岔（左文 + 自己的前綴），
///   分母彼此不同，**必須**逐位置呼叫 `logSumExp`。
///
/// `logProbabilities(context:candidates:)` 走的是正確但較慢的路徑；
/// `logits(context:candidates:)` 走的是快路徑。呼叫端要自己確認前提成立。
public struct CharLM: Sendable {
  // MARK: Lifecycle

  public init(weights: Weights) {
    self.weights = weights
  }

  public init(contentsOf url: URL) throws {
    self.init(weights: try Weights(contentsOf: url))
  }

  // MARK: Public

  public let weights: Weights

  public var window: Int { weights.window }
  public var vocabSize: Int { weights.vocabSize }

  /// `<bos>` 的 token id。左文不足 `window` 時用它補齊，與訓練時的行為一致。
  public var bosID: Int { Self.bosID }
  /// `<unk>` 的 token id。詞彙表外的字元一律映至此。
  public var unknownID: Int { Self.unknownID }

  /// 字元 → token id；不在詞彙表內者回傳 `<unk>`。
  public func tokenID(for character: Character) -> Int {
    weights.stoi[character] ?? Self.unknownID
  }

  /// 把左文字串轉成長度為 `window` 的 token 序列，左側不足處以 `<bos>` 補齊。
  ///
  /// 訓練時每行開頭都插了 `<bos>`，行首附近的樣本左側也是靠 `<bos>` 補齊，
  /// 因此這裡的補齊方式與訓練分佈一致。
  public func context(from text: some StringProtocol) -> [Int] {
    let tail = text.suffix(window)
    var result = [Int](repeating: Self.bosID, count: window - tail.count)
    result.append(contentsOf: tail.map(tokenID(for:)))
    return result
  }

  /// 前三層（兩個隱藏層 + 投影層）的輸出，長度為 `embDim`。
  ///
  /// 同一組上下文只需算一次，即可用來評分任意多個候選字。
  /// - Parameter context: 長度必須等於 `window`；越界的 id 會被夾到合法範圍。
  public func hiddenState(context: [Int]) -> [Float] {
    precondition(
      context.count == window,
      "上下文長度必須等於 window（\(window)），實得 \(context.count)"
    )
    let embDim = weights.embDim
    let hidden = weights.hidden

    // 查表串接：e = concat(emb[c] for c in context)
    var input = [Float](repeating: 0, count: window * embDim)
    weights.embedding.withUnsafeBufferPointer { table in
      input.withUnsafeMutableBufferPointer { output in
        for (slot, rawToken) in context.enumerated() {
          let token = Swift.max(0, Swift.min(rawToken, weights.vocabSize - 1))
          let source = table.baseAddress! + token * embDim
          let destination = output.baseAddress! + slot * embDim
          destination.update(from: source, count: embDim)
        }
      }
    }

    var layer1 = weights.hidden1Bias
    Self.multiplyAccumulate(
      matrix: weights.hidden1Weight, rows: hidden, columns: window * embDim,
      vector: input, into: &layer1
    )
    Self.rectify(&layer1)

    var layer2 = weights.hidden2Bias
    Self.multiplyAccumulate(
      matrix: weights.hidden2Weight, rows: hidden, columns: hidden,
      vector: layer1, into: &layer2
    )
    Self.rectify(&layer2)

    var projected = weights.projectionBias
    Self.multiplyAccumulate(
      matrix: weights.projectionWeight, rows: embDim, columns: hidden,
      vector: layer2, into: &projected
    )
    return projected
  }

  /// 單一 token 的**未正規化** logit。成本為 `embDim` 次乘加。
  public func logit(hidden: [Float], token: Int) -> Float {
    let embDim = weights.embDim
    guard weights.itos.indices.contains(token) else { return -.infinity }
    var result: Float = 0
    weights.embedding.withUnsafeBufferPointer { table in
      hidden.withUnsafeBufferPointer { state in
        vDSP_dotpr(
          table.baseAddress! + token * embDim, 1,
          state.baseAddress!, 1,
          &result, vDSP_Length(embDim)
        )
      }
    }
    return result + weights.outputBias[token]
  }

  /// log-softmax 的分母（對數形式）。需掃過整個詞彙表，是本模型最貴的一步。
  ///
  /// 比較「同一組上下文下的不同候選」時這個值會消掉，不必呼叫。
  public func logSumExp(hidden: [Float]) -> Float {
    let embDim = weights.embDim
    let vocabSize = weights.vocabSize

    var logits = weights.outputBias
    Self.multiplyAccumulate(
      matrix: weights.embedding, rows: vocabSize, columns: embDim,
      vector: hidden, into: &logits
    )

    var maximum: Float = 0
    vDSP_maxv(logits, 1, &maximum, vDSP_Length(vocabSize))
    // 先減去最大值再取 exp，避免溢位；這是 log-sum-exp 的標準寫法。
    var shift = -maximum
    vDSP_vsadd(logits, 1, &shift, &logits, 1, vDSP_Length(vocabSize))
    var count = Int32(vocabSize)
    vvexpf(&logits, logits, &count)
    var total: Float = 0
    vDSP_sve(logits, 1, &total, vDSP_Length(vocabSize))
    return maximum + Foundation.log(total)
  }

  /// 候選 token 的**未正規化** logit。
  ///
  /// 快路徑：僅適用於「所有候選共用這一組上下文」的比較，例如同一節點下的單字同音詞。
  /// 跨位置累加分數時不可使用——那種情況下各位置的分母不同，請改用
  /// `logProbabilities(context:candidates:)`。
  public func logits(context: [Int], candidates: [Int]) -> [Float] {
    let hidden = hiddenState(context: context)
    return candidates.map { logit(hidden: hidden, token: $0) }
  }

  /// 候選 token 的對數機率（已正規化）。
  public func logProbabilities(context: [Int], candidates: [Int]) -> [Float] {
    let hidden = hiddenState(context: context)
    let denominator = logSumExp(hidden: hidden)
    return candidates.map { logit(hidden: hidden, token: $0) - denominator }
  }

  /// 一整個候選字串在給定左文之下的對數機率總和，逐字前推。
  ///
  /// ```
  /// score("公式") = log P(公|左文) + log P(式|左文公)
  /// ```
  ///
  /// 同一個同音組內的候選字數必定相同（音節數即字數），因此各候選的加總項數
  /// 一致，比較時不需要長度正規化。
  public func logProbability(of candidate: some StringProtocol, following left: some StringProtocol) -> Float {
    logProbabilities(of: [String(candidate)], following: left)[0]
  }

  /// 一批候選各自的對數機率總和，共用前綴的計算只做一次。
  ///
  /// 同音組內的候選大量共用前綴——「公司 / 公式 / 公事」在評分第 2 個字時，
  /// 左文都是「⋯公」，隱藏層與 log-softmax 分母完全相同。以「左文 + 前綴」
  /// 為鍵記憶化之後，全詞彙表掃描的次數從「候選數 × 字數」降到「相異前綴數」，
  /// 而後者在實務上小得多。
  ///
  /// - Parameter normalization: 見 `Normalization`。單字候選兩者等價。
  /// - Returns: 與 `candidates` 等長、同序的分數陣列。
  public func logProbabilities(
    of candidates: [some StringProtocol],
    following left: some StringProtocol,
    normalization: Normalization = .perPosition
  )
    -> [Float] {
    guard !candidates.isEmpty else { return [] }
    let base = context(from: left)

    // 鍵為候選的前綴；空前綴代表「還沒吃進任何候選字元」的起始狀態。
    // 隱藏層與分母都只取決於前綴，因此一起快取。
    var cache = [String: (hidden: [Float], denominator: Float)]()

    func state(forPrefix prefix: String) -> (hidden: [Float], denominator: Float) {
      if let cached = cache[prefix] { return cached }
      var tokens = base
      for character in prefix {
        tokens.removeFirst()
        tokens.append(tokenID(for: character))
      }
      let hidden = hiddenState(context: tokens)
      // 全域正規化不需要分母，那正是它便宜的原因：省掉掃描整個詞彙表。
      let denominator: Float = normalization == .perPosition ? logSumExp(hidden: hidden) : 0
      let result = (hidden, denominator)
      cache[prefix] = result
      return result
    }

    return candidates.map { candidate in
      var prefix = ""
      var total: Float = 0
      for character in candidate {
        let (hidden, denominator) = state(forPrefix: prefix)
        total += logit(hidden: hidden, token: tokenID(for: character)) - denominator
        prefix.append(character)
      }
      return total
    }
  }

  // MARK: Private

  private static let bosID = 1
  private static let unknownID = 2

  /// `result += matrix · vector`，matrix 為 row-major 的 [rows, columns]。
  private static func multiplyAccumulate(
    matrix: [Float], rows: Int, columns: Int,
    vector: [Float], into result: inout [Float]
  ) {
    matrix.withUnsafeBufferPointer { a in
      vector.withUnsafeBufferPointer { x in
        result.withUnsafeMutableBufferPointer { y in
          cblas_sgemv(
            CblasRowMajor, CblasNoTrans,
            Int32(rows), Int32(columns),
            1.0, a.baseAddress!, Int32(columns),
            x.baseAddress!, 1,
            1.0, y.baseAddress!, 1
          )
        }
      }
    }
  }

  private static func rectify(_ values: inout [Float]) {
    var floor: Float = 0
    vDSP_vthres(values, 1, &floor, &values, 1, vDSP_Length(values.count))
  }
}

// MARK: - CharLM.Normalization

extension CharLM {
  /// 多字候選的分數怎麼累加。**對單字候選兩者等價**——分母是共同常數，比大小時會消掉。
  public enum Normalization: Sendable {
    /// 每個位置各自做 log-softmax，加總後是嚴格意義上的 `log P(候選|左文)`。
    ///
    /// 缺點是 label bias：第 1 個字的分母在全部詞彙上計算，而模型在那個位置
    /// 還沒看到後續音節的讀音，該項幾乎全是雜訊，會淹掉後續字的正確判斷。
    ///
    /// ```
    /// 「我寫了一支電腦＿」 讀音 ㄔㄥˊ-ㄕˋ
    ///   城市   城 -7.34 + 市 -2.09 = -9.44   ← 逐位置正規化下勝出
    ///   程式   程 -8.40 + 式 -1.16 = -9.56
    ///              ↑ 首字錯 1.06     ↑ 次字對 0.93
    /// ```
    case perPosition

    /// 累加未正規化的 logit，只在候選集之間比較。
    ///
    /// Homa 已依讀音篩選過候選，首字只可能是那幾個之一；把這個約束納入考量
    /// 正是受限解碼的標準作法。附帶好處是完全不需要 `logSumExp`，
    /// 多字節點的延遲從數百微秒降到十幾微秒。
    case acrossCandidates
  }
}

// MARK: - CharLM.Error

extension CharLM {
  public enum Error: Swift.Error, CustomStringConvertible {
    case badMagic
    case unsupportedVersion(Int)
    case unsupportedDType(Int)
    case missingTensor(String)
    case shapeMismatch(name: String, expected: [Int], actual: [Int])
    case truncated(offset: Int, needed: Int, available: Int)
    case malformed(String)

    // MARK: Public

    public var description: String {
      switch self {
      case .badMagic:
        "不是 VCLM 權重檔（magic 不符）。"
      case let .unsupportedVersion(version):
        "不支援的 VCLM 版本 \(version)。"
      case let .unsupportedDType(dtype):
        "不支援的資料型別代號 \(dtype)。"
      case let .missingTensor(name):
        "權重檔缺少張量「\(name)」。"
      case let .shapeMismatch(name, expected, actual):
        "張量「\(name)」形狀應為 \(expected)，實得 \(actual)。"
      case let .truncated(offset, needed, available):
        "檔案在位移 \(offset) 處被截斷：需要 \(needed) bytes，只剩 \(available)。"
      case let .malformed(reason):
        "權重檔格式有誤：\(reason)"
      }
    }
  }
}
