// (c) 2026 and onwards The vChewing Project (MIT-NTL License).
// ====================
// This code is released under the MIT license (SPDX-License-Identifier: MIT)
// ... with NTL restriction stating that:
// No trademark license is granted to use the trade names, trademarks, service
// marks, or product names of Contributor, except as required to fulfill notice
// requirements defined in MIT License.

import Foundation
import Homa
import RerankerCore

// MARK: - SentenceReranker

/// 在 Homa 的 DP 結果之上重排同音詞，並以弱覆寫寫回組字器。
///
/// 對應設計文件 `DevLab/AICandidateSelection_Design.md` §4.2 的位置 ③：
///
/// ```
/// ① Homa DP 決定斷詞（既有能力，不改）
///         ↓  assembledSentence: [GramInPath]
/// ② 沿路徑展開各節點的同音詞
///         ↓
/// ③ CandidateReranker 打分（Homa 先驗 + λ_LM × LM + λ_POM × POM）
///         ↓
/// ④ 以 overrideCandidate() 弱覆寫寫回
/// ```
///
/// ## 為什麼是「沿路徑變動元圖」而非「列舉多條路徑」
///
/// 設計文件 §1.5 講得很明白：用 k-shortest-paths 列舉路徑得到的是一堆**斷詞**變體
/// （手機號碼／手機號 碼／手 機 號碼），但每個節點仍然只出 `grams[0]`，
/// 同音詞從頭到尾沒變過，對本問題毫無幫助。
///
/// 因此這裡只在 DP 選定的斷詞框架**內**替換同音詞：**斷詞歸 DP，同音詞歸 reranker。**
///
/// ## 這是貪婪的，不是 beam search
///
/// 逐節點由左至右處理，每個節點的左文用的是**前面節點已經定案後**的字面。
/// 沒有回溯：第 3 個節點的選擇不會反過來改變第 2 個節點。
///
/// 這是刻意的取捨——真正的 beam search 需要維護 N 條假設並在每個節點展開，
/// 成本是節點數的指數級而非線性，放不進每次按鍵的熱路徑（§3 約束 B）。
/// 而字元語言模型的上下文只有 4 個字，回溯能挽回的收益本來就有限。
@MainActor
public struct SentenceReranker: Sendable {
  // MARK: Lifecycle

  public init(
    reranker: CandidateReranker,
    configuration: Configuration = .init()
  ) {
    self.reranker = reranker
    self.configuration = configuration
  }

  // MARK: Public

  /// 查詢某個節點各候選的 POM 支持度。
  ///
  /// - Parameters:
  ///   - assembledSentence: 當前組句結果（供 POM 取用前文脈絡）。
  ///   - location: 該節點起點在讀音陣列裡的索引。
  /// - Returns: 候選字面 → 支持度。**沒有記憶的候選不必出現在字典裡**（視同 0）。
  ///
  /// 之所以做成注入的閉包而非型別相依：POM（`LXPerceptor`）住在
  /// `vChewing_LangModelAssembly`，而本套件反過來是它的相依項，不能倒著引用。
  public typealias POMScoreProvider = @MainActor (
    _ assembledSentence: [Homa.GramInPath],
    _ location: Int
  ) -> [String: Double]

  public let reranker: CandidateReranker
  public let configuration: Configuration

  /// 對組字器的當前組句結果做同音詞重排，並把勝出者寫回。
  ///
  /// - Parameters:
  ///   - assembler: 目標組字器。呼叫端必須確保它已經 `assemble()` 過。
  ///   - pomScores: 選用的 POM 支持度查詢器，見 `POMScoreProvider`。
  /// - Returns: 實際發生的替換紀錄，依處理順序排列。沒有任何替換時為空陣列。
  @discardableResult
  public func apply(
    to assembler: Homa.Assembler,
    pomScores: POMScoreProvider? = nil
  )
    -> [Change] {
    guard !assembler.keys.isEmpty else { return [] }

    // ⚠️ 必須避免的回饋迴圈（設計文件 §4.5 結尾）：
    // `overrideCandidateAgainst` 會在 defer 裡呼叫 `(perceptionHandler ?? perceptor)?(intel)`。
    // 若不擋掉，reranker 自己的覆寫會被 POM 記成「使用者的選擇」，
    // 模型將訓練於自己的輸出，偏誤被放大。
    //
    // 這裡把 perceptor 暫時取下而非傳入 no-op handler：後者會讓
    // `shouldObserve` 為真，白白多跑一次 `assemble()`。
    let savedPerceptor = assembler.perceptor
    assembler.perceptor = nil
    defer { assembler.perceptor = savedPerceptor }

    var changes = [Change]()
    var sentence = assembler.assembledSentence
    var index = 0
    var position = 0
    var leftText = ""

    // 以「快照 + 只在覆寫後重新定位」推進，而不是每個節點都去問一次 `findGram()`：
    // 後者每次都會重建 border-point map，讓整趟變成 O(節點數²) 的記憶體配置抖動。
    while index < sentence.count {
      let node = sentence[index]
      let location = position
      // `segLength` 恆 ≥ 1，因此 position 每輪嚴格遞增、迴圈必然終止。
      position += node.segLength

      let replacement = rerank(
        node,
        at: location,
        leftContext: leftText,
        in: assembler,
        sentence: sentence,
        pomScores: pomScores
      )

      guard let replacement else {
        leftText = Self.trimmed(leftText + node.value, to: configuration.maxContextCharacters)
        index += 1
        continue
      }

      changes.append(replacement)

      // 覆寫會讓組字器重新組句，先前的快照就此失效。弱覆寫理論上不改變斷詞，
      // 但 `withTopGramScore` 提高了該候選的分數，DP 仍有可能挑出不同的路徑。
      sentence = assembler.assembledSentence
      guard let landing = Self.locate(
        position, in: sentence, maxContextCharacters: configuration.maxContextCharacters
      ) else {
        // 邊界被移動到對不上的位置。與其猜，不如就此收手——已完成的替換保留，
        // 其餘節點沿用 Homa 原本的選擇（契約 4：退化安全）。
        break
      }
      index = landing.index
      leftText = landing.leftText
    }
    return changes
  }

  // MARK: Private

  /// 在 `sentence` 內找出起點恰為 `position` 的節點，並一併算出它左側的定案字面。
  ///
  /// 回傳 `nil` 代表 `position` 落在某個節點的中間——重新組句後邊界移動了，
  /// 此時沒有任何一個「左文」的定義是乾淨的。
  private static func locate(
    _ position: Int,
    in sentence: [Homa.GramInPath],
    maxContextCharacters: Int
  )
    -> (index: Int, leftText: String)? {
    var cursor = 0
    var text = ""
    for (index, gram) in sentence.enumerated() {
      if cursor == position { return (index, trimmed(text, to: maxContextCharacters)) }
      guard cursor < position else { return nil }
      text += gram.value
      cursor += gram.segLength
    }
    guard cursor == position else { return nil }
    return (sentence.count, trimmed(text, to: maxContextCharacters))
  }

  private static func trimmed(_ text: String, to limit: Int) -> String {
    text.count <= limit ? text : String(text.suffix(limit))
  }

  /// 評估單一節點，必要時執行覆寫。
  /// - Returns: 實際發生替換時的紀錄；沒動它則為 `nil`。
  private func rerank(
    _ node: Homa.GramInPath,
    at location: Int,
    leftContext: String,
    in assembler: Homa.Assembler,
    sentence: [Homa.GramInPath],
    pomScores: POMScoreProvider?
  )
    -> Change? {
    guard shouldProcess(node) else { return nil }

    // 先確認這個節點真的有得選，再去問 POM：單一候選的節點沒有重排的餘地，
    // 而 POM 查詢會掃過整個組句結果去組三元圖的鍵，白問就是白付 O(節點數) 的成本。
    let fetched = rawCandidates(for: node, at: location, in: assembler)
    guard fetched.count > 1 else { return nil }

    // 刻意不寫成 `pomScores.map { … }`：Optional.map 的閉包是 nonisolated 的，
    // 會擋掉對主執行緒隔離的 POM 查詢器的呼叫。
    let pomScoreMap: [String: Double] = pomScores?(sentence, location) ?? [:]
    let alternatives = prune(fetched, current: node.value, pomScores: pomScoreMap)
    guard alternatives.count > 1 else { return nil }

    let scores = reranker.rescore(alternatives, leftContext: leftContext)
    guard scores.count == alternatives.count else { return nil } // 契約被違反時靜默跳過

    guard let winnerIndex = scores.indices.max(by: { scores[$0] < scores[$1] }),
          let currentIndex = alternatives.firstIndex(where: { $0.value == node.value })
    else { return nil }
    let winner = alternatives[winnerIndex]
    guard winner.value != node.value else { return nil }

    // 邊際優勢不足時不動它：把「模型只是稍微偏好另一個」的雜訊擋掉，
    // 避免使用者看到組字區無謂地跳動。
    let margin = scores[winnerIndex] - scores[currentIndex]
    guard margin >= configuration.minimumMargin else { return nil }

    do {
      try assembler.overrideCandidate(
        Homa.CandidatePair(keyArray: node.keyArray, value: winner.value),
        at: location,
        // 弱覆寫：只把該候選提到節點首位，不強制壓過 DP 的斷詞判斷。
        // 這與 POM 在非 forceHighScoreOverride 時的作法一致（§4.5）。
        type: .withTopGramScore,
        // 絕對不能是 true：那會讓 POM 與後續邏輯把它當成使用者的明確選擇。
        isExplicitlyOverridden: false,
        enforceRetokenization: false
      )
    } catch {
      // 覆寫失敗不是致命錯誤——沿用 Homa 原本的選擇即可（契約 4：退化安全）。
      return nil
    }
    return Change(
      position: location,
      keyArray: node.keyArray,
      from: node.value,
      to: winner.value,
      margin: margin
    )
  }

  /// 這個節點該不該碰。
  private func shouldProcess(_ node: Homa.GramInPath) -> Bool {
    // 使用者已經明確選過的節點，永遠不要跟他搶。
    //
    // ⚠️ 這道閘**擋不住 POM**：`retrievePOMSuggestions` 覆寫時沒有傳
    // `isExplicitlyOverridden`（預設 false），所以 POM 選中的節點在這裡看起來
    // 與未覆寫的節點無異。POM 的意見改由 `pomScore` 參與融合，見 §4.4 的三分工。
    if configuration.skipsExplicitlyOverridden, node.isExplicit { return false }
    // 標點的讀音以底線開頭，沒有同音詞可言。
    if node.keyArray.first?.first == "_" { return false }
    // 讀音與字面對不上的節點（例如以西文直接輸入者）不在重排範圍內。
    if node.isReadingMismatched { return false }
    return true
  }

  /// 取出與該節點**讀音完全相同**的候選，依詞庫分數由高到低排序。
  ///
  /// 只收 `keyArray` 完全相符者：斷詞已由 DP 決定，reranker 不改變幅節長度，
  /// 也不跨讀音替換（那會變成改讀音而非選同音字）。
  private func rawCandidates(
    for node: Homa.GramInPath,
    at location: Int,
    in assembler: Homa.Assembler
  )
    -> [(value: String, weight: Double)] {
    let fetched = assembler.fetchCandidates(at: location, filter: .beginAt)
    var seen = Set<String>()
    var result = [(value: String, weight: Double)]()
    for candidate in fetched where candidate.pair.keyArray == node.keyArray {
      guard seen.insert(candidate.pair.value).inserted else { continue }
      result.append((candidate.pair.value, candidate.weight))
    }
    // fetchCandidates 是依 (幅節長度, 讀音, 權重) 排序的，這裡要的是純粹的詞庫分數序。
    result.sort { $0.weight > $1.weight }
    return result
  }

  /// 剪枝：保留詞庫分數最高的前 N 個，但當前選中者與 POM 記得的候選一定要留著。
  ///
  /// 前者若被剪掉，它就不在比較之列，會導致無條件被替換；
  /// 後者若被剪掉，使用者辛苦教會的個人化訊號就白學了。
  private func prune(
    _ candidates: [(value: String, weight: Double)],
    current: String,
    pomScores: [String: Double]
  )
    -> [RerankCandidate] {
    var pruned = Array(candidates.prefix(configuration.maxCandidatesPerNode))
    var kept = Set(pruned.map(\.value))
    for mustKeep in candidates where !kept.contains(mustKeep.value) {
      guard mustKeep.value == current || pomScores[mustKeep.value] != nil else { continue }
      pruned.append(mustKeep)
      kept.insert(mustKeep.value)
    }
    return pruned.map {
      RerankCandidate(
        value: $0.value,
        priorScore: $0.weight,
        pomScore: pomScores[$0.value] ?? 0
      )
    }
  }
}

// MARK: - SentenceReranker.Configuration

extension SentenceReranker {
  public struct Configuration: Sendable {
    // MARK: Lifecycle

    public init(
      maxCandidatesPerNode: Int = 12,
      maxContextCharacters: Int = 8,
      minimumMargin: Double = 0,
      skipsExplicitlyOverridden: Bool = true
    ) {
      self.maxCandidatesPerNode = Swift.max(1, maxCandidatesPerNode)
      self.maxContextCharacters = Swift.max(1, maxContextCharacters)
      self.minimumMargin = minimumMargin
      self.skipsExplicitlyOverridden = skipsExplicitlyOverridden
    }

    // MARK: Public

    /// 每個節點最多送幾個候選進模型。
    ///
    /// 這是延遲的主要旋鈕。單字節點走快路徑、候選數幾乎不影響耗時；
    /// 多字節點則是「相異前綴數 × 一次前向」，候選愈多愈貴。
    public var maxCandidatesPerNode: Int

    /// 餵給模型的左文長度上限。模型窗口只有 4 個字，多給的部分會被丟掉，
    /// 但保留餘裕以便日後換成窗口更長的模型（§4.7 第 2 步）而不必改這裡。
    public var maxContextCharacters: Int

    /// 勝出者必須比當前選擇高出多少分才寫回。
    ///
    /// 預設 0（只要更高就換）。調高可以換取穩定度——組字區在打字過程中
    /// 反覆跳動比偶爾選錯更惱人。
    public var minimumMargin: Double

    /// 是否跳過使用者已明確選過的節點。預設為真，且**不建議關閉**。
    public var skipsExplicitlyOverridden: Bool
  }
}

// MARK: - SentenceReranker.Change

extension SentenceReranker {
  /// 一次實際發生的替換。供測試斷言與除錯輸出使用。
  public struct Change: Hashable, Sendable {
    public let position: Int
    public let keyArray: [String]
    public let from: String
    public let to: String
    public let margin: Double

    public var description: String {
      "\(keyArray.joined(separator: "-")) @\(position)： \(from) → \(to)"
        + String(format: "（+%.3f）", margin)
    }
  }
}
