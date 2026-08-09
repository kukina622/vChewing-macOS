// (c) 2026 and onwards The vChewing Project (MIT-NTL License).
// ====================
// This code is released under the MIT license (SPDX-License-Identifier: MIT)
// ... with NTL restriction stating that:
// No trademark license is granted to use the trade names, trademarks, service
// marks, or product names of Contributor, except as required to fulfill notice
// requirements defined in MIT License.

import Foundation

// MARK: - RerankCandidate

/// 待重排的候選，以及融合最終分數所需的各路訊號。
///
/// 對應設計文件 `DevLab/AICandidateSelection_Design.md` §4.4 的三分工：
///
/// ```
/// 最終 = Homa 分數 + λ_LM × LM 分數 + λ_POM × POM 分數
///        ^^^^^^^^^                     ^^^^^^^^^
///        priorScore                    pomScore
/// ```
///
/// 中間那項（LM 分數）不在本型別內——它由重排器自己依 `leftContext` 算出來。
public struct RerankCandidate: Hashable, Sendable {
  // MARK: Lifecycle

  public init(value: String, priorScore: Double, pomScore: Double = 0) {
    self.value = value
    self.priorScore = priorScore
    self.pomScore = pomScore
  }

  // MARK: Public

  public let value: String

  /// 詞庫先驗：Homa 的 `Gram.probability`（對數機率，實測落在 -9.5 ~ -2.3）。
  public let priorScore: Double

  /// 漸退記憶（POM）對這個候選的支持度。**0 表示 POM 對它沒有記憶**，越大越支持。
  ///
  /// 刻意不直接沿用 `LXPerceptor` 回傳的原始權重：那個值的方向性有既有疑義
  /// （`calculateWeight()` 的 `score = -base × 常數`，但挑選時取最大值），
  /// 本型別因此只收「已正規化的支持度」，由呼叫端負責換算。
  /// vChewing 的接法見 `InputHandlerProtocol.applyContextualReranking()`。
  public let pomScore: Double
}

// MARK: - CandidateReranker

/// 候選重排器。設計依據見 `DevLab/AICandidateSelection_Design.md` §4.2、§4.7。
///
/// 三個落地階段（MLP → LSTM → 加 GBDT 融合層）共用這個協定，換模型只是換實作。
///
/// ## 契約
///
/// 1. **決定性**：同樣輸入必須回傳同樣輸出。使用者體驗不能是隨機的。
/// 2. **長度相符**：回傳陣列的長度與順序必須對應輸入的 `candidates`。
/// 3. **不遺失候選**：本協定回傳的是分數而非重排後的清單，因此候選不可能被丟掉——
///    這是型別層面的保證，不需要仰賴實作自律。
/// 4. **退化安全**：模型不可用時應退回 `NoOpReranker`，靜默沿用詞庫順序，不得崩潰。
/// 5. **分數只在同一次呼叫內可比**：實作可以省略對所有候選都相同的常數項
///    （`CharLMReranker` 就利用這點跳過 log-softmax 的分母）。因此回傳值只能
///    拿來決定這一組候選的先後，**不得跨節點比較、也不得當成機率解讀**。
public protocol CandidateReranker: Sendable {
  /// 回傳每個候選的最終分數（越大越優先）。
  /// - Parameters:
  ///   - candidates: 待重排的候選，順序即詞庫給的原始順序。
  ///   - leftContext: 該候選左側**已經定案**的字面文字，供上下文模型取用。
  /// - Returns: 與 `candidates` 等長、同序的分數陣列。
  func rescore(_ candidates: [RerankCandidate], leftContext: String) -> [Double]
}

extension CandidateReranker {
  /// 依重排分數由高到低回傳候選索引。分數相同時保留原始順序（穩定排序）。
  ///
  /// 之所以回傳索引而非候選本身，是為了讓呼叫端能把分數對應回自己的資料結構
  /// （例如 Homa 的 `CandidatePairWeighted`）。
  public func rankedIndices(
    _ candidates: [RerankCandidate],
    leftContext: String
  )
    -> [Int] {
    let scores = rescore(candidates, leftContext: leftContext)
    guard scores.count == candidates.count else { return Array(candidates.indices) }
    return candidates.indices.sorted { lhs, rhs in
      scores[lhs] == scores[rhs] ? lhs < rhs : scores[lhs] > scores[rhs]
    }
  }
}

// MARK: - NoOpReranker

/// 原樣回傳詞庫先驗分數的重排器。
///
/// 用於：模型檔缺失或損毀時的退化路徑、以及作為 A/B 對照組的基線。
/// **刻意不理會 `pomScore`**——它要當的是「完全沒有本功能」的對照組。
public struct NoOpReranker: CandidateReranker {
  // MARK: Lifecycle

  public init() {}

  // MARK: Public

  public func rescore(_ candidates: [RerankCandidate], leftContext _: String) -> [Double] {
    candidates.map(\.priorScore)
  }
}
