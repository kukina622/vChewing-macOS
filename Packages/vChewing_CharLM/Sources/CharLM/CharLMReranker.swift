// (c) 2026 and onwards The vChewing Project (MIT-NTL License).
// ====================
// This code is released under the MIT license (SPDX-License-Identifier: MIT)
// ... with NTL restriction stating that:
// No trademark license is granted to use the trade names, trademarks, service
// marks, or product names of Contributor, except as required to fulfill notice
// requirements defined in MIT License.

import Foundation
import RerankerCore

// MARK: - CharLMReranker

/// 以 CharLM 提供上下文訊號的重排器。
///
/// ```
/// 最終 = Homa 分數 + λ_LM × LM 分數 + λ_POM × POM 分數
/// ```
///
/// 三者的分工見設計文件 §4.4：詞庫答「這串讀音**通常**是哪個詞」（先驗）、
/// LM 答「這個詞在**這段話裡**合不合理」（上下文）、POM 答「**你**上次選了什麼」（個人化）。
///
/// `λ_LM` 的實測最佳值為 **1.0**（見 §4.4、§4.8）。該值高於初版設計預期的 0.2–0.5，
/// 成因是原廠詞庫的機率解析度偏低——16.7% 的候選共用同一個 `DEFAULT_PROB`，
/// 先驗攜帶的資訊比理論假設少得多。λ ∈ [0.5, 1.5] 的實測差距全部落在一個標準誤之內。
public struct CharLMReranker: CandidateReranker {
  // MARK: Lifecycle

  public init(
    model: CharLM,
    lambdaLM: Double = CharLMReranker.defaultLambdaLM,
    lambdaPOM: Double = CharLMReranker.defaultLambdaPOM,
    minimumLeftContext: Int = CharLMReranker.defaultMinimumLeftContext,
    normalization: CharLM.Normalization = .acrossCandidates
  ) {
    self.model = model
    self.lambdaLM = lambdaLM
    self.lambdaPOM = lambdaPOM
    self.minimumLeftContext = Swift.max(0, minimumLeftContext)
    self.normalization = normalization
  }

  // MARK: Public

  /// 於保留集實測得出的最佳上下文權重（設計文件 §4.8）。
  public static let defaultLambdaLM: Double = 1.0

  /// 見 `minimumLeftContext`。
  public static let defaultMinimumLeftContext: Int = 1

  /// 個人化權重，**以「每個字元」為單位**計入（見 `rescore` 的說明）。
  ///
  /// 由端到端掃描定出（`MainAssemblyTests_ContextualReranking.swift` 的 `test603`）：
  /// 在「敵人發動ㄍㄨㄥ-ㄕˋ」這個 2 字節點上，讓 POM 記憶勝出所需的總加分落在
  /// 10 與 15 之間，換算成每字元即 5–7.5。取 **12.0** 是刻意給足餘裕——
  /// POM 記的是使用者**親手改過**的字，它該穩定壓過統計模型，而不是跟它拉鋸。
  ///
  /// 仍會讓位給真人的當下選字：那條路徑由 `skipsExplicitlyOverridden` 保護，
  /// 根本不會進到打分階段。
  ///
  /// > ⚠️ 這是單一案例掃出來的值。案例集補到 100–200 條之後（設計文件待辦第 2 項）
  /// > 應該重掃一次。
  public static let defaultLambdaPOM: Double = 12.0

  /// LM 至少需要幾個字元的左文才准參與評分。預設 1，亦即**左文為空時 LM 不表態**。
  ///
  /// 這不是保守起見，是實測逼出來的。在 500 條保留語料案例上，被重排「弄壞」的
  /// 案例幾乎全部集中在組字區的第一個節點：
  ///
  /// ```
  /// 但最近主演電影面臨上映  →  石最近⋯
  /// 名士兵幾乎斷手          →  明士兵⋯
  /// 賽後他在                →  塞後他在
  /// ```
  ///
  /// 成因很直接：左文為空時模型只能拿 `<bos>` 補齊，實際上沒有任何資訊可用，
  /// 卻仍吃滿 `λ_LM` 的權重，於是把詞庫先驗推翻掉。體感上就是
  /// 「每開始打一句新話，第一個字容易被亂改」——這比偶爾選錯惱人得多。
  ///
  /// 若日後發現只有 1 個字的左文也一樣弱，把這個值調到 2 即可。
  public let minimumLeftContext: Int

  public let model: CharLM
  public let lambdaLM: Double
  public let lambdaPOM: Double

  /// 多字候選的累加方式。
  ///
  /// 預設 `.acrossCandidates`：Homa 已依讀音把候選篩過一輪，首字只可能是那幾個之一，
  /// 把這個約束納入考量正是受限解碼的標準作法。`.perPosition` 在多字節點上會踩到
  /// 自身文件所載的 label bias（見 `CharLM.Normalization`），實測還慢約 3.4 倍。
  ///
  /// 兩者對**單字**候選等價（分母是共同常數），而設計文件 §4.8 的 +20.83pt 有 83.3%
  /// 的案例是單字，所以那個數字並不構成保留 `.perPosition` 的理由。
  public let normalization: CharLM.Normalization

  /// ```
  /// 最終 = Homa 分數 + λ_LM × LM 分數 + λ_POM × POM 分數 × 字元數
  ///                                                     ^^^^^^^^
  /// ```
  ///
  /// **為什麼 POM 項要乘上字元數**：LM 分數是逐字加總的（`Σ log P(字|上下文)`），
  /// 尺度會隨候選字數線性成長——2 字節點的分數跨度大約是 1 字節點的兩倍。
  /// POM 若維持固定加分，就會在短節點上過度強勢、在長節點上壓不住 LM，
  /// 於是**不存在任何在各種長度下都成立的 λ_POM**。乘上字元數讓兩者站在同一尺度，
  /// λ_POM 才有「每字元權重」這個穩定語意。
  ///
  /// （實測：λ_POM = 6 在 1 字節點足夠、在 2 字節點不足，正是這個問題的病徵。）
  public func rescore(_ candidates: [RerankCandidate], leftContext: String) -> [Double] {
    guard !candidates.isEmpty else { return [] }
    // 單一候選沒有可比對象，直接省掉整段推論。
    guard candidates.count > 1 else {
      let only = candidates[0]
      return [only.priorScore + lambdaPOM * only.pomScore * Double(only.value.count)]
    }

    // 左文不足時 LM 不表態：只留下詞庫先驗與 POM。
    //
    // POM 刻意保留。它的鍵是「前前詞 + 前詞 + 當前詞」的三元組，位置 0 沒有前文
    // 可比對，`fetchPOMSuggestion` 本來就查不到東西、自然回空——它是自我設限的。
    // 而真的查到時，代表使用者確實在這個情境下親手改過字，那正是個人化該生效的
    // 時刻：句首恰恰最需要 POM，因為那裡沒有任何上下文訊號可用。
    guard leftContext.count >= minimumLeftContext else {
      return candidates.map {
        $0.priorScore + lambdaPOM * $0.pomScore * Double($0.value.count)
      }
    }

    let isAllSingleCharacter = candidates.allSatisfy { $0.value.count == 1 }
    let contextScores: [Double] = isAllSingleCharacter
      ? singleCharacterScores(candidates, leftContext: leftContext)
      : model.logProbabilities(
        of: candidates.map(\.value),
        following: leftContext,
        normalization: normalization
      ).map(Double.init)

    return zip(candidates, contextScores).map { candidate, contextScore in
      candidate.priorScore
        + lambdaLM * contextScore
        + lambdaPOM * candidate.pomScore * Double(candidate.value.count)
    }
  }

  // MARK: Private

  /// 全部都是單字候選時的快路徑。
  ///
  /// 這些候選共用同一組上下文，log-softmax 的分母是共同常數、比大小時會消掉，
  /// 因此可以跳過掃描整個詞彙表的 `logSumExp`——這正是設計文件 §4.3 所述
  /// 「候選集限定輸出」的加速來源，也是本模型能待在每次按鍵熱路徑上的關鍵。
  /// 實測：13.1 µs／節點（12 個候選），相對於走分母的 251 µs。
  ///
  /// 得到的是未正規化的 logit。由於缺的是一個對所有候選都相同的常數，
  /// 融合之後的**排序**與用正規化分數完全一致。
  private func singleCharacterScores(
    _ candidates: [RerankCandidate],
    leftContext: String
  )
    -> [Double] {
    let context = model.context(from: leftContext)
    let hidden = model.hiddenState(context: context)
    return candidates.map { candidate in
      guard let character = candidate.value.first else { return 0 }
      return Double(model.logit(hidden: hidden, token: model.tokenID(for: character)))
    }
  }
}
