// (c) 2026 and onwards The vChewing Project (MIT-NTL License).
// ====================
// This code is released under the MIT license (SPDX-License-Identifier: MIT)
// ... with NTL restriction stating that:
// No trademark license is granted to use the trade names, trademarks, service
// marks, or product names of Contributor, except as required to fulfill notice
// requirements defined in MIT License.

import Foundation
import Homa
import HomaSharedTestComponents
import RerankerCore
import Testing

@testable import HomaReranker

// MARK: - 測試素材

/// 刻意設計的小詞庫：
/// - `shi4` 有三個同音單字，詞庫順序為 是 > 事 > 式
/// - `gao1-xing4` 有兩個同音詞，詞庫順序為 高興 > 高性
/// - `_ju4hao4` 是標點，用來確認重排器會跳過它
private let testLMData = """
shi4 是 -5.0
shi4 事 -5.5
shi4 式 -6.0
gao1 高 -5.0
gao1 篙 -7.0
xing4 姓 -5.2
xing4 性 -6.0
gao1-xing4 高興 -4.0
gao1-xing4 高性 -8.0
ni3 你 -5.0
ni3 妳 -5.8
_ju4hao4 。 -9.0
"""

/// 固定偏好某個字面的假重排器：讓測試不必依賴真實模型，也就沒有浮點抖動。
private struct PreferringReranker: CandidateReranker {
  let preferred: String
  var bonus: Double = 100

  func rescore(_ candidates: [RerankCandidate], leftContext _: String) -> [Double] {
    candidates.map { $0.value == preferred ? $0.priorScore + bonus : $0.priorScore }
  }
}

/// 記錄呼叫次數的假重排器，用來確認節點被跳過。
private final class CountingReranker: CandidateReranker, @unchecked Sendable {
  private(set) var invocations: [[String]] = []

  func rescore(_ candidates: [RerankCandidate], leftContext _: String) -> [Double] {
    invocations.append(candidates.map(\.value))
    return candidates.map(\.priorScore)
  }
}

/// 記錄收到的左文，用來確認上下文是「已定案的字面」。
private final class ContextRecordingReranker: CandidateReranker, @unchecked Sendable {
  private(set) var contexts: [String] = []

  func rescore(_ candidates: [RerankCandidate], leftContext: String) -> [Double] {
    contexts.append(leftContext)
    return candidates.map(\.priorScore)
  }
}

/// 把 POM 支持度直接當成加分，用來驗證融合公式的第三項確實接通。
private struct POMWeightingReranker: CandidateReranker {
  var lambdaPOM: Double = 6

  func rescore(_ candidates: [RerankCandidate], leftContext _: String) -> [Double] {
    candidates.map { $0.priorScore + lambdaPOM * $0.pomScore }
  }
}

/// 記錄每個節點收到的 POM 支持度。
private final class POMRecordingReranker: CandidateReranker, @unchecked Sendable {
  private(set) var seen: [[String: Double]] = []

  func rescore(_ candidates: [RerankCandidate], leftContext _: String) -> [Double] {
    seen.append(.init(
      candidates.map { ($0.value, $0.pomScore) },
      uniquingKeysWith: { lhs, _ in lhs }
    ))
    return candidates.map(\.priorScore)
  }
}

@MainActor
private func makeAssembler(_ readings: [String]) throws -> Homa.Assembler {
  let lm = TestLM(rawData: testLMData)
  let assembler = Homa.Assembler(gramQuerier: { lm.queryGrams($0) })
  for reading in readings {
    try assembler.insertKey(reading)
  }
  _ = assembler.assemble()
  return assembler
}

// MARK: - SentenceRerankerTests

@MainActor
@Suite("組句重排器")
struct SentenceRerankerTests {
  @Test("能把同音單字換掉")
  func replacesSingleCharacterHomophone() throws {
    let assembler = try makeAssembler(["shi4"])
    #expect(assembler.assembledSentence.values.joined() == "是")

    let changes = SentenceReranker(reranker: PreferringReranker(preferred: "式"))
      .apply(to: assembler)

    #expect(assembler.assembledSentence.values.joined() == "式")
    #expect(changes.count == 1)
    #expect(changes.first?.from == "是")
    #expect(changes.first?.to == "式")
  }

  @Test("重排不改變斷詞與讀音")
  func preservesSegmentation() throws {
    let assembler = try makeAssembler(["gao1", "xing4"])
    let before = assembler.assembledSentence
    #expect(before.values.joined() == "高興")

    SentenceReranker(reranker: PreferringReranker(preferred: "高性")).apply(to: assembler)

    let after = assembler.assembledSentence
    #expect(after.values.joined() == "高性")
    #expect(after.keyArrays == before.keyArrays) // 讀音與幅節切分完全不變
  }

  @Test("NoOpReranker 不產生任何變更")
  func noOpChangesNothing() throws {
    let assembler = try makeAssembler(["shi4", "ni3"])
    let before = assembler.assembledSentence.values.joined()
    let changes = SentenceReranker(reranker: NoOpReranker()).apply(to: assembler)
    #expect(changes.isEmpty)
    #expect(assembler.assembledSentence.values.joined() == before)
  }

  @Test("決定性：重複套用結果一致，且第二次不再變更")
  func isIdempotentAndDeterministic() throws {
    let assembler = try makeAssembler(["shi4", "ni3"])
    let reranker = SentenceReranker(reranker: PreferringReranker(preferred: "事"))

    let first = reranker.apply(to: assembler)
    let snapshot = assembler.assembledSentence.values.joined()
    #expect(first.count == 1)

    let second = reranker.apply(to: assembler)
    #expect(second.isEmpty) // 已經是最佳解，不該再動
    #expect(assembler.assembledSentence.values.joined() == snapshot)
  }
}

// MARK: - 契約與安全性

@MainActor
@Suite("重排器整合的安全邊界")
struct SentenceRerankerSafetyTests {
  /// 設計文件 §4.5 結尾標記的回饋迴圈：若 AI 的覆寫被 POM 記成「使用者選的」，
  /// 模型會訓練於自己的輸出，偏誤被放大。
  @Test("不得觸發 POM 觀測")
  func doesNotFeedPerceptor() throws {
    let assembler = try makeAssembler(["shi4"])
    final class Box: @unchecked Sendable { var count = 0 }
    let box = Box()
    assembler.perceptor = { _ in box.count += 1 }

    SentenceReranker(reranker: PreferringReranker(preferred: "式")).apply(to: assembler)

    #expect(box.count == 0)
    #expect(assembler.assembledSentence.values.joined() == "式")
    // perceptor 必須被原樣裝回去，不能被重排器吃掉。
    #expect(assembler.perceptor != nil)
  }

  @Test("覆寫不得標記為使用者明確選擇")
  func doesNotMarkAsExplicit() throws {
    let assembler = try makeAssembler(["shi4"])
    SentenceReranker(reranker: PreferringReranker(preferred: "式")).apply(to: assembler)
    #expect(assembler.assembledSentence.allSatisfy { !$0.isExplicit })
  }

  @Test("不碰使用者已明確選過的節點")
  func skipsExplicitlyOverriddenNodes() throws {
    let assembler = try makeAssembler(["shi4"])
    try assembler.overrideCandidate(
      Homa.CandidatePair(keyArray: ["shi4"], value: "事"),
      at: 0,
      type: .withSpecified,
      isExplicitlyOverridden: true
    )
    #expect(assembler.assembledSentence.values.joined() == "事")

    let counting = CountingReranker()
    let changes = SentenceReranker(reranker: counting).apply(to: assembler)

    #expect(counting.invocations.isEmpty) // 連問都不該問
    #expect(changes.isEmpty)
    #expect(assembler.assembledSentence.values.joined() == "事")
  }

  @Test("跳過標點節點")
  func skipsPunctuation() throws {
    let assembler = try makeAssembler(["ni3", "_ju4hao4"])
    let counting = CountingReranker()
    SentenceReranker(reranker: counting).apply(to: assembler)
    // 只有「你」那個節點會被詢問；標點不該進入重排。
    #expect(counting.invocations.allSatisfy { !$0.contains("。") })
  }

  @Test("左文是已定案的字面，且逐節點累積")
  func feedsDecidedLeftContext() throws {
    let assembler = try makeAssembler(["ni3", "shi4"])
    let recorder = ContextRecordingReranker()
    SentenceReranker(reranker: recorder).apply(to: assembler)
    #expect(recorder.contexts.count == 2)
    #expect(recorder.contexts[0] == "")   // 第一個節點左側沒有東西
    #expect(recorder.contexts[1] == "你") // 第二個節點看得到前一個節點的定案值
  }

  @Test("剪枝之後仍保留當前選擇，否則會被無條件替換")
  func keepsCurrentChoiceAfterPruning() throws {
    let assembler = try makeAssembler(["shi4"])
    // 只准留 1 個候選：詞庫首選「是」會被留下，其餘剪掉，因此不該發生變更。
    let configuration = SentenceReranker.Configuration(maxCandidatesPerNode: 1)
    let changes = SentenceReranker(reranker: NoOpReranker(), configuration: configuration)
      .apply(to: assembler)
    #expect(changes.isEmpty)
    #expect(assembler.assembledSentence.values.joined() == "是")
  }

  @Test("minimumMargin 擋掉優勢不足的替換")
  func respectsMinimumMargin() throws {
    let assembler = try makeAssembler(["shi4"])
    // 「式」比「是」的詞庫分數低 1.0，給 +1.5 的加成後淨勝 0.5。
    let reranker = PreferringReranker(preferred: "式", bonus: 1.5)

    let blocked = SentenceReranker(
      reranker: reranker,
      configuration: .init(minimumMargin: 1.0)
    ).apply(to: assembler)
    #expect(blocked.isEmpty)
    #expect(assembler.assembledSentence.values.joined() == "是")

    let allowed = SentenceReranker(
      reranker: reranker,
      configuration: .init(minimumMargin: 0.25)
    ).apply(to: assembler)
    #expect(allowed.count == 1)
    #expect(assembler.assembledSentence.values.joined() == "式")
  }

  @Test("POM 支持度足以推翻詞庫先驗")
  func pomCanOverridePrior() throws {
    let assembler = try makeAssembler(["shi4"])
    #expect(assembler.assembledSentence.values.joined() == "是")

    // 「式」比「是」的詞庫分數低 1.0，但 POM 記得它，λ_POM = 6 足以扳回。
    let changes = SentenceReranker(reranker: POMWeightingReranker()).apply(to: assembler) { _, _ in
      ["式": 1.0]
    }

    #expect(changes.count == 1)
    #expect(assembler.assembledSentence.values.joined() == "式")
  }

  @Test("未提供 POM 查詢器時，支持度一律為 0")
  func pomDefaultsToZero() throws {
    let assembler = try makeAssembler(["shi4"])
    let recorder = POMRecordingReranker()
    SentenceReranker(reranker: recorder).apply(to: assembler)
    #expect(!recorder.seen.isEmpty)
    #expect(recorder.seen.allSatisfy { $0.values.allSatisfy { $0 == 0 } })
  }

  @Test("POM 查詢器收到的是該節點的起點位置")
  func pomProviderReceivesNodeLocation() throws {
    let assembler = try makeAssembler(["ni3", "gao1", "xing4"])
    // 斷詞為 [你][高興]，故起點應為 0 與 1。
    final class Box: @unchecked Sendable { var locations: [Int] = [] }
    let box = Box()
    SentenceReranker(reranker: NoOpReranker()).apply(to: assembler) { _, location in
      box.locations.append(location)
      return [:]
    }
    #expect(box.locations == [0, 1])
  }

  @Test("POM 記得的候選即使落在剪枝範圍外也會被保留")
  func pomCandidateSurvivesPruning() throws {
    let assembler = try makeAssembler(["shi4"])
    // 只准留 1 個（詞庫首選「是」），但 POM 記得「式」——它必須被補回候選集。
    let configuration = SentenceReranker.Configuration(maxCandidatesPerNode: 1)
    let recorder = POMRecordingReranker()
    SentenceReranker(reranker: recorder, configuration: configuration)
      .apply(to: assembler) { _, _ in ["式": 1.0] }

    #expect(recorder.seen.first?.keys.sorted() == ["式", "是"])
    #expect(recorder.seen.first?["式"] == 1.0)
  }

  @Test("空組字器不崩潰")
  func handlesEmptyAssembler() {
    let lm = TestLM(rawData: testLMData)
    let assembler = Homa.Assembler(gramQuerier: { lm.queryGrams($0) })
    #expect(SentenceReranker(reranker: NoOpReranker()).apply(to: assembler).isEmpty)
  }

  /// 契約被違反（回傳長度不符）時必須靜默跳過，不得崩潰。
  @Test("重排器回傳長度不符時退化為不動作")
  func toleratesContractViolation() throws {
    struct BadReranker: CandidateReranker {
      func rescore(_: [RerankCandidate], leftContext _: String) -> [Double] { [] }
    }
    let assembler = try makeAssembler(["shi4"])
    let changes = SentenceReranker(reranker: BadReranker()).apply(to: assembler)
    #expect(changes.isEmpty)
    #expect(assembler.assembledSentence.values.joined() == "是")
  }
}
