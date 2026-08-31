// (c) 2026 and onwards The vChewing Project (MIT-NTL License).
// ====================
// This code is released under the MIT license (SPDX-License-Identifier: MIT)
// ... with NTL restriction stating that:
// No trademark license is granted to use the trade names, trademarks, service
// marks, or product names of Contributor, except as required to fulfill notice
// requirements defined in MIT License.

import Foundation
import Testing

@testable import CharLM

// MARK: - 合成模型：不依賴外部檔案，永遠會執行

/// 手工組出一個微型 VCLM 檔案，用來驗證解析與算術本身。
///
/// 維度刻意取小（vocab 5、window 2、emb 2、hidden 3），讓期望值能手算出來。
private enum SyntheticModel {
  static let vocabSize = 5
  static let window = 2
  static let embDim = 2
  static let hidden = 3

  /// emb[token] = [token, 1 - token]
  static let embedding: [Float] = [
    0, 1, // <pad>
    1, 0, // <bos>
    2, -1, // <unk>
    3, -2, // "甲"
    4, -3, // "乙"
  ]
  static let hidden1Weight: [Float] = [
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
  ]
  static let hidden1Bias: [Float] = [0, 0, 0]
  static let hidden2Weight: [Float] = [
    1, 0, 0,
    0, 1, 0,
    0, 0, 1,
  ]
  static let hidden2Bias: [Float] = [0, 0, 0]
  static let projectionWeight: [Float] = [
    1, 0, 0,
    0, 1, 0,
  ]
  static let projectionBias: [Float] = [0, 0]
  static let outputBias: [Float] = [0, 0, 0, 0, 0]
  static let itos = ["<pad>", "<bos>", "<unk>", "甲", "乙"]

  static func makeData(dtype: UInt32 = 0) -> Data {
    var data = Data("VCLM".utf8)
    func appendUInt32(_ value: UInt32) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    func appendTensor(_ name: String, _ shape: [Int], _ values: [Float]) {
      let rawName = Array(name.utf8)
      appendUInt32(UInt32(rawName.count))
      data.append(contentsOf: rawName)
      appendUInt32(UInt32(shape.count))
      shape.forEach { appendUInt32(UInt32($0)) }
      values.forEach { value in
        if dtype == 0 {
          withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        } else {
          withUnsafeBytes(of: halfBits(of: value).littleEndian) { data.append(contentsOf: $0) }
        }
      }
    }

    [1, dtype, UInt32(vocabSize), UInt32(window), UInt32(embDim), UInt32(hidden), 8]
      .forEach { appendUInt32($0) }
    appendTensor("emb.weight", [vocabSize, embDim], embedding)
    appendTensor("net.0.weight", [hidden, window * embDim], hidden1Weight)
    appendTensor("net.0.bias", [hidden], hidden1Bias)
    appendTensor("net.3.weight", [hidden, hidden], hidden2Weight)
    appendTensor("net.3.bias", [hidden], hidden2Bias)
    appendTensor("net.6.weight", [embDim, hidden], projectionWeight)
    appendTensor("net.6.bias", [embDim], projectionBias)
    appendTensor("out_bias", [vocabSize], outputBias)

    let vocabBlob = Array(itos.joined(separator: "\n").utf8)
    appendUInt32(UInt32(vocabBlob.count))
    data.append(contentsOf: vocabBlob)
    return data
  }

  /// 只需支援本測試用到的小整數，故採最直白的寫法。
  private static func halfBits(of value: Float) -> UInt16 {
    let bits = value.bitPattern
    let sign = UInt16((bits >> 16) & 0x8000)
    guard value != 0 else { return sign }
    let exponent = Int((bits >> 23) & 0xFF) - 127 + 15
    let mantissa = UInt16((bits >> 13) & 0x03FF)
    return sign | (UInt16(exponent) << 10) | mantissa
  }
}

// MARK: - CharLMWeightsTests

@Suite("CharLM 權重解析")
struct CharLMWeightsTests {
  @Test("解析合成的 float32 權重檔")
  func parseFloat32() throws {
    let weights = try CharLM.Weights(data: SyntheticModel.makeData(dtype: 0))
    #expect(weights.vocabSize == 5)
    #expect(weights.window == 2)
    #expect(weights.embDim == 2)
    #expect(weights.hidden == 3)
    #expect(weights.itos == SyntheticModel.itos)
    #expect(weights.embedding == SyntheticModel.embedding)
    // 特殊符號長度大於 1，不應出現在字元查詢表內。
    #expect(weights.stoi["甲"] == 3)
    #expect(weights.stoi["乙"] == 4)
    #expect(weights.stoi["<"] == nil)
  }

  @Test("float16 與 float32 解析出相同數值")
  func halfPrecisionMatchesSingle() throws {
    let single = try CharLM.Weights(data: SyntheticModel.makeData(dtype: 0))
    let half = try CharLM.Weights(data: SyntheticModel.makeData(dtype: 1))
    #expect(single.embedding == half.embedding)
    #expect(single.hidden1Weight == half.hidden1Weight)
  }

  @Test("magic 不符時拋出 badMagic")
  func rejectsBadMagic() {
    var data = SyntheticModel.makeData()
    data.replaceSubrange(0 ..< 4, with: Data("XXXX".utf8))
    #expect(throws: CharLM.Error.self) { try CharLM.Weights(data: data) }
  }

  @Test("檔案被截斷時拋出而非崩潰")
  func rejectsTruncatedFile() {
    let data = SyntheticModel.makeData()
    for cut in [8, 40, data.count - 4] {
      #expect(throws: CharLM.Error.self) {
        try CharLM.Weights(data: data.prefix(cut))
      }
    }
  }

  @Test("尾端有多餘位元組時拋出")
  func rejectsTrailingGarbage() {
    var data = SyntheticModel.makeData()
    data.append(contentsOf: [0, 0, 0, 0])
    #expect(throws: CharLM.Error.self) { try CharLM.Weights(data: data) }
  }
}

// MARK: - CharLMInferenceTests

@Suite("CharLM 推論")
struct CharLMInferenceTests {
  /// 上下文 ["甲", "乙"] = [3, 4]：
  ///   e = concat(emb[3], emb[4]) = [3, -2, 4, -3]
  ///   layer1 = 前三維（單位矩陣切片）= [3, -2, 4] → ReLU → [3, 0, 4]
  ///   layer2 = 同上（單位矩陣）→ [3, 0, 4]
  ///   hidden = 前兩維 = [3, 0]
  ///   logit[t] = dot(emb[t], [3, 0]) = 3 × emb[t][0]
  @Test("前向傳播與手算值相符")
  func forwardMatchesHandComputation() throws {
    let model = CharLM(weights: try .init(data: SyntheticModel.makeData()))
    let hidden = model.hiddenState(context: [3, 4])
    #expect(hidden == [3, 0])
    let logits = (0 ..< 5).map { model.logit(hidden: hidden, token: $0) }
    #expect(logits == [0, 3, 6, 9, 12])
  }

  @Test("左文不足時以 <bos> 補齊")
  func padsWithBOS() throws {
    let model = CharLM(weights: try .init(data: SyntheticModel.makeData()))
    #expect(model.context(from: "") == [1, 1])
    #expect(model.context(from: "甲") == [1, 3])
    #expect(model.context(from: "甲乙") == [3, 4])
    // 超出窗口時只取最靠近的幾個字。
    #expect(model.context(from: "乙甲乙") == [3, 4])
  }

  @Test("詞彙表外的字元映至 <unk>")
  func mapsUnknownToUNK() throws {
    let model = CharLM(weights: try .init(data: SyntheticModel.makeData()))
    #expect(model.tokenID(for: "丙") == 2)
    #expect(model.context(from: "丙") == [1, 2])
  }

  @Test("logProbabilities 是正規化過的")
  func logProbabilitiesAreNormalised() throws {
    let model = CharLM(weights: try .init(data: SyntheticModel.makeData()))
    let all = model.logProbabilities(context: [3, 4], candidates: Array(0 ..< 5))
    let total = all.map { Foundation.exp(Double($0)) }.reduce(0, +)
    #expect(abs(total - 1.0) < 1e-5)
  }

  @Test("未正規化 logit 與正規化 logProb 的排序一致")
  func fastPathPreservesOrdering() throws {
    let model = CharLM(weights: try .init(data: SyntheticModel.makeData()))
    let candidates = [4, 2, 0, 3]
    let fast = model.logits(context: [3, 4], candidates: candidates)
    let exact = model.logProbabilities(context: [3, 4], candidates: candidates)
    let fastOrder = candidates.indices.sorted { fast[$0] > fast[$1] }
    let exactOrder = candidates.indices.sorted { exact[$0] > exact[$1] }
    #expect(fastOrder == exactOrder)
  }

  @Test("多字候選逐字前推累加")
  func multiCharacterScoreAccumulates() throws {
    let model = CharLM(weights: try .init(data: SyntheticModel.makeData()))
    let joint = model.logProbability(of: "甲乙", following: "")
    let first = model.logProbabilities(context: model.context(from: ""), candidates: [3])[0]
    let second = model.logProbabilities(context: model.context(from: "甲"), candidates: [4])[0]
    #expect(abs(joint - (first + second)) < 1e-5)
  }

  /// 批次版以「左文 + 前綴」記憶化來省下重複的全詞彙表掃描，
  /// 結果必須與沒有任何快取的逐一計算完全一致。
  @Test("前綴記憶化不改變數值")
  func prefixMemoisationIsExact() throws {
    let model = CharLM(weights: try .init(data: SyntheticModel.makeData()))
    // 刻意混入共用前綴（甲乙／甲甲）與獨立前綴（乙甲），涵蓋命中與未命中兩路。
    let candidates = ["甲乙", "甲甲", "乙甲", "乙乙"]
    for left in ["", "甲", "乙甲"] {
      let batched = model.logProbabilities(of: candidates, following: left)
      let individually = candidates.map { model.logProbability(of: $0, following: left) }
      #expect(batched == individually)
    }
  }

  @Test("全域正規化等於未正規化 logit 的加總")
  func acrossCandidatesSumsRawLogits() throws {
    let model = CharLM(weights: try .init(data: SyntheticModel.makeData()))
    let scores = model.logProbabilities(
      of: ["甲乙"], following: "", normalization: .acrossCandidates
    )
    let manual = model.logit(hidden: model.hiddenState(context: model.context(from: "")), token: 3)
      + model.logit(hidden: model.hiddenState(context: model.context(from: "甲")), token: 4)
    #expect(abs(scores[0] - manual) < 1e-5)
  }

  /// 單字候選的分母是共同常數，比大小時會消掉，因此兩種正規化必須給出相同排序。
  @Test("單字候選下兩種正規化排序一致")
  func normalisationsAgreeOnSingleCharacters() throws {
    let model = CharLM(weights: try .init(data: SyntheticModel.makeData()))
    let candidates = ["甲", "乙", "丙"]
    for left in ["", "甲", "乙甲"] {
      let perPosition = model.logProbabilities(of: candidates, following: left)
      let across = model.logProbabilities(
        of: candidates, following: left, normalization: .acrossCandidates
      )
      let orderA = candidates.indices.sorted { perPosition[$0] > perPosition[$1] }
      let orderB = candidates.indices.sorted { across[$0] > across[$1] }
      #expect(orderA == orderB)
    }
  }

  @Test("批次版保持輸入順序與長度")
  func batchedScoresKeepOrder() throws {
    let model = CharLM(weights: try .init(data: SyntheticModel.makeData()))
    #expect(model.logProbabilities(of: [String](), following: "甲").isEmpty)
    let candidates = ["乙", "甲乙", "甲"]
    let scores = model.logProbabilities(of: candidates, following: "")
    #expect(scores.count == candidates.count)
    #expect(scores[0] == model.logProbability(of: "乙", following: ""))
    #expect(scores[2] == model.logProbability(of: "甲", following: ""))
  }
}

// MARK: - CandidateRerankerTests

@Suite("重排器契約")
struct CandidateRerankerTests {
  private func makeModel() throws -> CharLM {
    CharLM(weights: try .init(data: SyntheticModel.makeData()))
  }

  @Test("NoOpReranker 原樣回傳先驗分數")
  func noOpPassesThrough() {
    let candidates = [
      RerankCandidate(value: "甲", priorScore: -3.0),
      RerankCandidate(value: "乙", priorScore: -5.0),
    ]
    #expect(NoOpReranker().rescore(candidates, leftContext: "") == [-3.0, -5.0])
    #expect(NoOpReranker().rankedIndices(candidates, leftContext: "") == [0, 1])
  }

  @Test("契約 2：回傳長度與順序對應輸入")
  func lengthMatchesInput() throws {
    let reranker = CharLMReranker(model: try makeModel())
    for count in 0 ... 4 {
      let candidates = (0 ..< count).map {
        RerankCandidate(value: $0.isMultiple(of: 2) ? "甲" : "乙", priorScore: Double(-$0))
      }
      #expect(reranker.rescore(candidates, leftContext: "甲").count == count)
    }
  }

  @Test("契約 1：同樣輸入得到同樣輸出")
  func isDeterministic() throws {
    let reranker = CharLMReranker(model: try makeModel())
    let candidates = [
      RerankCandidate(value: "甲", priorScore: -3.0),
      RerankCandidate(value: "乙", priorScore: -5.0),
    ]
    let first = reranker.rescore(candidates, leftContext: "甲乙")
    for _ in 0 ..< 8 {
      #expect(reranker.rescore(candidates, leftContext: "甲乙") == first)
    }
  }

  @Test("契約 4：權重檔損毀時拋出而非崩潰，呼叫端得以退回 NoOpReranker")
  func degradesGracefully() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("charlm-broken-\(UUID().uuidString).bin")
    try Data("這不是權重檔".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(throws: (any Swift.Error).self) { try CharLM(contentsOf: url) }

    // 退化路徑本身：NoOpReranker 必須原樣沿用詞庫順序。
    let candidates = [RerankCandidate(value: "甲", priorScore: -1.0)]
    #expect(NoOpReranker().rescore(candidates, leftContext: "") == [-1.0])
  }

  @Test("契約 4：檔案不存在時同樣拋出而非崩潰")
  func degradesOnMissingFile() {
    let url = URL(fileURLWithPath: "/nonexistent/charlm-\(UUID().uuidString).bin")
    #expect(throws: (any Swift.Error).self) { try CharLM(contentsOf: url) }
  }

  @Test("λ_LM = 0 且無 POM 記憶時，結果與 NoOpReranker 相同")
  func zeroLambdaEqualsBaseline() throws {
    let reranker = CharLMReranker(model: try makeModel(), lambdaLM: 0)
    let candidates = [
      RerankCandidate(value: "甲", priorScore: -3.0),
      RerankCandidate(value: "乙", priorScore: -5.0),
    ]
    #expect(
      reranker.rescore(candidates, leftContext: "乙")
        == NoOpReranker().rescore(candidates, leftContext: "乙")
    )
  }

  @Test("λ_LM 夠大時上下文可以推翻詞庫先驗")
  func contextCanOverridePrior() throws {
    let model = try makeModel()
    // 合成模型中 logit 隨 token id 遞增，故「乙」(4) 的上下文分數高於「甲」(3)。
    let candidates = [
      RerankCandidate(value: "甲", priorScore: -3.0),
      RerankCandidate(value: "乙", priorScore: -5.0),
    ]
    #expect(CharLMReranker(model: model, lambdaLM: 0).rankedIndices(
      candidates, leftContext: "甲"
    ) == [0, 1])
    #expect(CharLMReranker(model: model, lambdaLM: 5).rankedIndices(
      candidates, leftContext: "甲"
    ) == [1, 0])
  }

  // MARK: 三分工的融合公式（設計文件 §4.4）

  @Test("POM 記憶足以壓過上下文，但壓不過 λ_POM = 0")
  func pomOverridesContext() throws {
    let model = try makeModel()
    // 上下文偏好「乙」；POM 只記得「甲」。
    let candidates = [
      RerankCandidate(value: "甲", priorScore: -3.0, pomScore: 1.0),
      RerankCandidate(value: "乙", priorScore: -5.0, pomScore: 0.0),
    ]
    let lambdaLM = 5.0
    #expect(CharLMReranker(model: model, lambdaLM: lambdaLM, lambdaPOM: 0)
      .rankedIndices(candidates, leftContext: "甲") == [1, 0])
    #expect(CharLMReranker(model: model, lambdaLM: lambdaLM, lambdaPOM: 6)
      .rankedIndices(candidates, leftContext: "甲") == [0, 1])
  }

  @Test("POM 分數以 λ_POM 線性計入最終分數")
  func pomContributesLinearly() throws {
    let model = try makeModel()
    let withoutPOM = [RerankCandidate(value: "甲", priorScore: -3.0)]
    let withPOM = [RerankCandidate(value: "甲", priorScore: -3.0, pomScore: 1.0)]
    let lambdaPOM = 6.0
    let base = CharLMReranker(model: model, lambdaPOM: lambdaPOM)
      .rescore(withoutPOM, leftContext: "甲")[0]
    let boosted = CharLMReranker(model: model, lambdaPOM: lambdaPOM)
      .rescore(withPOM, leftContext: "甲")[0]
    #expect(abs((boosted - base) - lambdaPOM) < 1e-9)
  }

  @Test("NoOpReranker 刻意忽略 POM：它要當的是「完全沒有本功能」的對照組")
  func noOpIgnoresPOM() {
    let candidates = [
      RerankCandidate(value: "甲", priorScore: -3.0, pomScore: 1.0),
      RerankCandidate(value: "乙", priorScore: -5.0, pomScore: 0.0),
    ]
    #expect(NoOpReranker().rescore(candidates, leftContext: "") == [-3.0, -5.0])
  }
}
