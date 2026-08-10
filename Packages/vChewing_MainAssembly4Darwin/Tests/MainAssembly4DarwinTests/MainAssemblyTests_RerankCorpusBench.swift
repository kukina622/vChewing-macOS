// (c) 2026 and onwards The vChewing Project (MIT-NTL License).
// ====================
// This code is released under the MIT license (SPDX-License-Identifier: MIT)
// ... with NTL restriction stating that:
// No trademark license is granted to use the trade names, trademarks, service
// marks, or product names of Contributor, except as required to fulfill notice
// requirements defined in MIT License.

import CharLM
import Foundation
import Homa
import HomaReranker
import LMAssemblyMaterials4Tests
import Testing

@testable import MainAssembly4Darwin

// MARK: - 大樣本語料基準

/// 以保留語料量測上下文重排的組句準確率（設計文件待辦第 2 項所需的規模）。
///
/// ## 為什麼要有這個
///
/// `test602` 那 5 條手寫案例只能當煙霧測試——手寫案例的問題不只是量少，更在於
/// **你只寫得出你想像中會錯的東西**，而真正的錯誤往往落在你沒想到的地方。
/// 這條測試改用真實語料自動生成數千條案例，數字才有統計意義。
///
/// ## 怎麼跑
///
/// 需要一份**原生繁體**保留語料（不可與模型訓練集重疊）：
///
/// ```
/// VCHEWING_RERANK_CORPUS=./test.txt \
///   swift test --package-path ./Packages/vChewing_MainAssembly4Darwin --filter test604
/// ```
///
/// 未設定環境變數時整條測試靜默跳過，因此不影響日常的 `swift test`。
/// 可另以 `VCHEWING_RERANK_LIMIT` 調整案例數（預設 500，約需 2–3 分鐘；
/// 成本與案例數成線性，3000 條要跑十幾分鐘）。
///
/// **本測試只量準確率，不量延遲**——延遲由 `test602` 以完整 FSM 量測，
/// 那才是使用者真正經歷的路徑。
///
/// ## 案例是怎麼生出來的
///
/// 拿原廠詞庫自己對語料做最長匹配切詞，每個詞取其讀音；正解就是原文。
///
/// **只採用「讀音唯一」的詞。** 詞庫裡單字的多個讀音機率常常完全相同
/// （例：樂 的 ㄩㄝˋ／ㄧㄠˋ／ㄌㄠˋ／ㄌㄜˋ 全都是 -9.465），
/// 若用「取最高機率」來挑讀音，等於擲骰子、會生出大量讀音錯誤的假案例。
/// 改成有歧義就讓整條案例出局——語料夠多，寧可少也不可錯。
///
/// ## 這個數字要怎麼打折
///
/// 1. **偏樂觀。** 語料是新聞／論壇，與模型訓練集同 domain（只是不同 split）；
///    你日常打字的內容分佈不一樣，體感會比這個數字差。
/// 2. **繞過 FSM。** 這裡直接把讀音餵進組字器，不經 Tekkon 與輸入 FSM。
///    那一層由 `test602` / `test603` 覆蓋。
/// 3. **最長匹配的切詞未必等於 Homa DP 的切詞。** 這不是問題——正解是原文，
///    任何偏離都算錯，這正是使用者的判準。
extension MainAssemblyTests {
  @Test("[基準] 保留語料上的上下文重排準確率")
  func test604_ContextualReranking_CorpusBenchmark() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let corpusPath = environment["VCHEWING_RERANK_CORPUS"] else {
      print("跳過大樣本基準：未設定 VCHEWING_RERANK_CORPUS。見本測試的文件註解。")
      return
    }
    // 預設 500：每條案例要跑完整的組字流程（實測約 0.15 秒／案／輪，兩輪），
    // 500 條約需 2–3 分鐘。要更小的信賴區間就自行調高，但時間是線性成長的。
    let limit = environment["VCHEWING_RERANK_LIMIT"].flatMap(Int.init) ?? 500

    try #require(CharLMRerankerMgr.reranker(for: .imeModeCHT) != nil)
    let factoryPath = try #require(LMMgr.getCoreDictionaryDBPath(factory: true))

    let previousPref = PrefMgr.shared.applyContextualCandidateReranking
    let previousReranker = testLM.contextualReranker
    defer {
      PrefMgr.shared.applyContextualCandidateReranking = previousPref
      testLM.contextualReranker = previousReranker
      _ = LMAssembly.LMInstantiator.connectToTestFactoryDictionary(
        textMapData: LMATestsData.textMapTestCoreLMData
      )
    }
    LMAssembly.LMInstantiator.connectFactoryDictionary(textMapPath: factoryPath)
    testHandler.currentLM.syncPrefs()

    let lexicon = try LexiconReadings(txtMapPath: factoryPath)
    let cases = try lexicon.makeCases(corpusPath: corpusPath, limit: limit)

    print("""

    ┌─ 語料基準：案例生成 ─────────────────────────────────
    │ 語料          \(corpusPath)
    │ 工作目錄      \(FileManager.default.currentDirectoryPath)
    │ 詞庫詞數      \(lexicon.totalWords)（讀音唯一者 \(lexicon.uniqueReadingWords)）
    │ 最長詞        \(lexicon.maxWordLength) 字
    │ 抽樣查表      音樂=\(lexicon.wordToReading["音樂"] ?? "無")　\
    粉絲=\(lexicon.wordToReading["粉絲"] ?? "無")　的=\(lexicon.wordToReading["的"] ?? "無")
    │ 生成案例      \(cases.count)
    └──────────────────────────────────────────────────────
    """)
    try #require(!cases.isEmpty, "語料沒有生出任何案例，請確認 \(corpusPath) 是原生繁體文本。")

    let baseline = runCorpus(cases, rerankerEnabled: false)
    let treatment = runCorpus(cases, rerankerEnabled: true)

    let sampleError = (1.96 * (treatment.accuracy * (1 - treatment.accuracy) / Double(cases.count))
      .squareRoot()) * 100
    print("""

    ┌─ 語料基準：A/B 結果 ─────────────────────────────────
    │                關閉重排      開啟重排
    │ 整句全對率     \(pct(baseline.accuracy))      \(pct(treatment.accuracy))\
       （\(treatment.accuracy >= baseline.accuracy ? "+" : "")\
    \(pct(treatment.accuracy - baseline.accuracy))）
    │ 逐字正確率     \(pct(baseline.charAccuracy))      \(pct(treatment.charAccuracy))\
       （\(treatment.charAccuracy >= baseline.charAccuracy ? "+" : "")\
    \(pct(treatment.charAccuracy - baseline.charAccuracy))）
    │
    │ 整句全對率的 95% 信賴區間約 ±\(String(format: "%.2f", sampleError))pt
    └──────────────────────────────────────────────────────
    """)

    printSampleDiffs(baseline: baseline, treatment: treatment)

    #expect(
      treatment.charAccuracy >= baseline.charAccuracy,
      "開啟重排後逐字正確率下降，發生迴歸。"
    )
  }

  /// 診斷：正解到底在不在 Homa 的候選格裡？
  ///
  /// 這個數字決定「換掉 Homa」有沒有意義：
  ///
  /// - oracle 遠低於 100% → 候選格裡根本沒有正解，再強的打分模型也救不回來，
  ///   瓶頸在詞庫／斷詞層，換掉 Homa 才有意義。
  /// - oracle 接近 100% → 正解一直都在，只是分數排不上去，
  ///   換掉 Homa 毫無幫助，該換的是打分的模型。
  @Test("[診斷] 候選格的 oracle 可達率")
  func test605_LatticeOracleReachability() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let corpusPath = environment["VCHEWING_RERANK_CORPUS"] else { return }
    let limit = environment["VCHEWING_RERANK_LIMIT"].flatMap(Int.init) ?? 500
    let factoryPath = try #require(LMMgr.getCoreDictionaryDBPath(factory: true))
    defer {
      _ = LMAssembly.LMInstantiator.connectToTestFactoryDictionary(
        textMapData: LMATestsData.textMapTestCoreLMData
      )
    }
    LMAssembly.LMInstantiator.connectFactoryDictionary(textMapPath: factoryPath)
    testHandler.currentLM.syncPrefs()

    let lexicon = try LexiconReadings(txtMapPath: factoryPath)
    let cases = try lexicon.makeCases(corpusPath: corpusPath, limit: limit)
    let assembler = testHandler.assembler

    var reachable = 0
    var evaluated = 0
    var unreachableSamples = [String]()

    for item in cases {
      assembler.clear()
      var ok = true
      for reading in item.readings {
        guard (try? assembler.insertKey(reading)) != nil else { ok = false; break }
      }
      guard ok else { continue }
      _ = assembler.assemble()
      evaluated += 1

      // 可達性 DP：從讀音位置 0 出發，看能否用候選拼出完整的正解。
      let expected = Array(item.expected)
      let count = item.readings.count
      var canReach = [Bool](repeating: false, count: count + 1)
      canReach[0] = true
      // 讀音位置 == 字元位置（同音組內每個候選的字數等於音節數）。
      for position in 0 ..< count where canReach[position] {
        for candidate in assembler.fetchCandidates(at: position, filter: .beginAt) {
          let length = candidate.pair.keyArray.count
          guard position + length <= count else { continue }
          guard candidate.pair.value.count == length else { continue }
          let slice = String(expected[position ..< position + length])
          if candidate.pair.value == slice { canReach[position + length] = true }
        }
      }
      if canReach[count] {
        reachable += 1
      } else if unreachableSamples.count < 10 {
        unreachableSamples.append(item.expected)
      }
    }

    let rate = evaluated == 0 ? 0 : Double(reachable) / Double(evaluated) * 100
    print("""

    ┌─ 候選格 oracle 可達率 ───────────────────────────────
    │ 評估案例      \(evaluated)
    │ 正解可達      \(reachable)（\(String(format: "%.2f%%", rate))）
    │ 正解不可達    \(evaluated - reachable)
    └──────────────────────────────────────────────────────
    """)
    if !unreachableSamples.isEmpty {
      print("── 候選格裡湊不出正解的樣本 ──")
      unreachableSamples.forEach { print("  \($0)") }
    }
  }

  /// 一次性組態掃描：beam 寬度 × 句首是否讓 LM 表態。
  @Test("[掃描] beam 與 minimumLeftContext 的交互作用")
  func test607_ConfigSweep() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let corpusPath = environment["VCHEWING_RERANK_CORPUS"] else { return }
    let limit = environment["VCHEWING_RERANK_LIMIT"].flatMap(Int.init) ?? 500
    let factoryPath = try #require(LMMgr.getCoreDictionaryDBPath(factory: true))
    defer {
      _ = LMAssembly.LMInstantiator.connectToTestFactoryDictionary(
        textMapData: LMATestsData.textMapTestCoreLMData
      )
      testLM.contextualReranker = nil
    }
    LMAssembly.LMInstantiator.connectFactoryDictionary(textMapPath: factoryPath)
    testHandler.currentLM.syncPrefs()

    let url = try #require(Bundle.currentSPM.url(forResource: "charlm-cht", withExtension: "bin"))
    let model = try CharLM(contentsOf: url)
    let lexicon = try LexiconReadings(txtMapPath: factoryPath)
    let cases = try lexicon.makeCases(corpusPath: corpusPath, limit: limit)

    func run(_ label: String, _ reranker: SentenceReranker?) {
      PrefMgr.shared.applyContextualCandidateReranking = reranker != nil
      testLM.contextualReranker = reranker
      let assembler = testHandler.assembler
      var exact = 0, correct = 0, total = 0
      let started = DispatchTime.now().uptimeNanoseconds
      for item in cases {
        assembler.clear()
        var ok = true
        for r in item.readings where ok {
          if (try? assembler.insertKey(r)) == nil { ok = false }
        }
        guard ok else { continue }
        _ = assembler.assemble()
        reranker?.apply(to: assembler)
        let got = assembler.assembledSentence.values.joined()
        if got == item.expected { exact += 1 }
        total += item.expected.count
        correct += zip(got, item.expected).reduce(0) { $0 + ($1.0 == $1.1 ? 1 : 0) }
      }
      let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000.0
      print(String(
        format: "│ %@  整句 %.2f%%   逐字 %.2f%%   %.0f ms",
        label.padding(toLength: 30, withPad: " ", startingAt: 0),
        Double(exact) / Double(cases.count) * 100,
        Double(correct) / Double(total) * 100, ms
      ))
    }

    print("\n┌─ 組態掃描（\(cases.count) 條案例）───────────────────────────────")
    run("關閉重排", nil)
    for (width, minCtx) in [(1, 1), (4, 1), (4, 0), (8, 0)] {
      run("beam=\(width) minLeftCtx=\(minCtx)", SentenceReranker(
        reranker: CharLMReranker(model: model, minimumLeftContext: minCtx),
        configuration: .init(beamWidth: width)
      ))
    }
    print("└──────────────────────────────────────────────────────────────")
  }

  /// 量測：重排器實際拿得到多長的左文？窗口拉到超過這個分佈就是浪費。
  @Test("[量測] 左文長度分佈")
  func test608_LeftContextLengthDistribution() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let corpusPath = environment["VCHEWING_RERANK_CORPUS"] else { return }
    let limit = environment["VCHEWING_RERANK_LIMIT"].flatMap(Int.init) ?? 500
    let factoryPath = try #require(LMMgr.getCoreDictionaryDBPath(factory: true))
    defer {
      _ = LMAssembly.LMInstantiator.connectToTestFactoryDictionary(
        textMapData: LMATestsData.textMapTestCoreLMData
      )
      testLM.contextualReranker = nil
    }
    LMAssembly.LMInstantiator.connectFactoryDictionary(textMapPath: factoryPath)
    testHandler.currentLM.syncPrefs()

    /// 只記錄左文長度，分數原樣回傳（等同 NoOp，不改變任何結果）。
    final class LengthRecorder: CandidateReranker, @unchecked Sendable {
      var lengths = [Int]()
      func rescore(_ candidates: [RerankCandidate], leftContext: String) -> [Double] {
        lengths.append(leftContext.count)
        return candidates.map(\.priorScore)
      }
    }

    let lexicon = try LexiconReadings(txtMapPath: factoryPath)
    let cases = try lexicon.makeCases(corpusPath: corpusPath, limit: limit)
    let recorder = LengthRecorder()
    // maxContextCharacters 開到 20（組字區上限），才量得到真實可用長度。
    testLM.contextualReranker = SentenceReranker(
      reranker: recorder,
      configuration: .init(beamWidth: 1, maxContextCharacters: 20)
    )

    let assembler = testHandler.assembler
    for item in cases {
      assembler.clear()
      var ok = true
      for r in item.readings where ok {
        if (try? assembler.insertKey(r)) == nil { ok = false }
      }
      guard ok else { continue }
      _ = assembler.assemble()
      testLM.contextualReranker?.apply(to: assembler)
    }

    let lengths = recorder.lengths.sorted()
    guard !lengths.isEmpty else { return }
    func share(atLeast n: Int) -> Double {
      Double(lengths.filter { $0 >= n }.count) / Double(lengths.count) * 100
    }
    print("\n┌─ 左文長度分佈（\(lengths.count) 次評分呼叫）──────────────")
    for n in [1, 2, 4, 6, 8, 12, 16, 20] {
      let pct = share(atLeast: n)
      let bar = String(repeating: "█", count: Int(pct / 2.5))
      print(String(format: "│ ≥%2d 字   %5.1f%%  %@", n, pct, bar))
    }
    print("│")
    print("│ 中位數 \(lengths[lengths.count / 2]) 字、最長 \(lengths.last!) 字")
    print("└──────────────────────────────────────────────")
  }

  // MARK: - 內部

  fileprivate func runCorpus(
    _ cases: [(readings: [String], expected: String)],
    rerankerEnabled: Bool
  )
    -> CorpusOutcome {
    PrefMgr.shared.applyContextualCandidateReranking = rerankerEnabled
    let reranker = rerankerEnabled ? CharLMRerankerMgr.reranker(for: .imeModeCHT) : nil
    testLM.contextualReranker = reranker

    let assembler = testHandler.assembler
    var exact = 0
    var correctChars = 0
    var totalChars = 0
    var skipped = 0
    var results = [String]()
    results.reserveCapacity(cases.count)

    for item in cases {
      assembler.clear()
      var insertable = true
      for reading in item.readings {
        guard (try? assembler.insertKey(reading)) != nil else {
          insertable = false
          break
        }
      }
      guard insertable else {
        skipped += 1
        results.append("")
        continue
      }
      _ = assembler.assemble()
      // 直接呼叫而非走 `applyContextualReranking()`：後者是 Typewriter 模組的
      // internal 成員，跨模組取用不到。整合路徑由 test602 / test603 覆蓋。
      reranker?.apply(to: assembler)

      let got = assembler.assembledSentence.values.joined()
      results.append(got)
      if got == item.expected { exact += 1 }
      totalChars += item.expected.count
      correctChars += zip(got, item.expected).reduce(0) { $0 + ($1.0 == $1.1 ? 1 : 0) }
    }
    if skipped > 0 {
      print("　（\(skipped) 條案例含組字器無法插入的讀音，已跳過）")
    }
    return CorpusOutcome(
      exact: exact,
      total: cases.count,
      correctChars: correctChars,
      totalChars: totalChars,
      results: results,
      cases: cases
    )
  }

  fileprivate func printSampleDiffs(baseline: CorpusOutcome, treatment: CorpusOutcome) {
    var fixed = [(String, String, String)]()
    var broken = [(String, String, String)]()
    for index in baseline.cases.indices {
      let expected = baseline.cases[index].expected
      let before = baseline.results[index]
      let after = treatment.results[index]
      guard before != after else { continue }
      if after == expected {
        if fixed.count < 8 { fixed.append((expected, before, after)) }
      } else if before == expected {
        if broken.count < 8 { broken.append((expected, before, after)) }
      }
    }
    if !fixed.isEmpty {
      print("── 重排修好的（樣本）──")
      fixed.forEach { print("  \($0.1)  →  \($0.2)") }
    }
    if !broken.isEmpty {
      print("── 重排弄壞的（樣本，這些最值得看）──")
      broken.forEach { print("  \($0.1)  →  \($0.2)   （正解 \($0.0)）") }
    }
  }

  fileprivate func pct(_ value: Double) -> String {
    String(format: "%.2f%%", value * 100)
  }
}

// MARK: - CorpusOutcome

struct CorpusOutcome {
  let exact: Int
  let total: Int
  let correctChars: Int
  let totalChars: Int
  let results: [String]
  let cases: [(readings: [String], expected: String)]

  var accuracy: Double { total == 0 ? 0 : Double(exact) / Double(total) }
  var charAccuracy: Double { totalChars == 0 ? 0 : Double(correctChars) / Double(totalChars) }
}

// MARK: - LexiconReadings

/// 從原廠詞庫的 `.txtMap` 建立「繁體詞 → 讀音」反查表，並據以生成測試案例。
///
/// `.txtMap` 的格式（實測確認，非官方文件）：
///
/// ```
/// #PRAGMA:VANGUARD_HOMA_LEXICON_HEADER
/// DEFAULT_PROB_7 \t -11              ← `>7` 之類的簡寫會引用這裡
/// #PRAGMA:VANGUARD_HOMA_LEXICON_VALUES
/// @-3.338 \t 音乐 \t 音樂             ← ⚠️ 簡體在前、繁體在後
/// >7      \t 哀|哎|唉                ← 同機率的候選以 `|` 分隔
/// #PRAGMA:VANGUARD_HOMA_LEXICON_KEY_LINE_MAP
/// ㄧㄣ-ㄩㄝˋ \t 120011 \t 3           ← 讀音 → VALUES 的起始索引與筆數
/// ```
struct LexiconReadings {
  // MARK: Lifecycle

  init(txtMapPath: String) throws {
    let content = try String(contentsOfFile: txtMapPath, encoding: .utf8)
    var defaults = [String: Double]()
    var values = [[String]]() // 每個 VALUES 列的繁體候選
    var readingsOf = [String: Set<String>]()
    var pendingKeys = [(reading: String, start: Int, count: Int)]()
    var section = ""

    for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix("#PRAGMA:") {
        section = String(line.dropFirst("#PRAGMA:".count))
        continue
      }
      let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      switch section {
      case "VANGUARD_HOMA_LEXICON_HEADER":
        guard parts.count == 2, parts[0].hasPrefix("DEFAULT_PROB_") else { continue }
        defaults[String(parts[0].dropFirst("DEFAULT_PROB_".count))] = Double(parts[1]) ?? 0
      case "VANGUARD_HOMA_LEXICON_VALUES":
        // 機率本身用不到（只判斷讀音是否唯一），但保留解析以記錄格式。
        _ = parts.first.map { head -> Double in
          if head.hasPrefix("@") { return Double(head.dropFirst()) ?? -99 }
          if head.hasPrefix(">") { return defaults[String(head.dropFirst())] ?? -99 }
          return -99
        }
        values.append(parts.count > 2 ? parts[2].split(separator: "|").map(String.init) : [])
      case "VANGUARD_HOMA_LEXICON_KEY_LINE_MAP":
        guard parts.count >= 3, let start = Int(parts[1]), let count = Int(parts[2])
        else { continue }
        pendingKeys.append((parts[0], start, count))
      default:
        continue
      }
    }

    for entry in pendingKeys {
      let upper = Swift.min(entry.start + entry.count, values.count)
      guard entry.start < upper else { continue }
      for index in entry.start ..< upper {
        for word in values[index] {
          readingsOf[word, default: []].insert(entry.reading)
        }
      }
    }

    self.totalWords = readingsOf.count
    var unique = [String: String]()
    var longest = 1
    for (word, readings) in readingsOf where readings.count == 1 {
      unique[word] = readings.first
      longest = Swift.max(longest, word.count)
    }
    self.wordToReading = unique
    self.maxWordLength = longest
    self.uniqueReadingWords = unique.count
  }

  // MARK: Internal

  let totalWords: Int
  let uniqueReadingWords: Int
  let maxWordLength: Int
  let wordToReading: [String: String]

  /// 片段長度上限。預設 12；`compositorWidthLimit` 是 20，量測左文分佈時應放寬到 20，
  /// 否則量到的會是生成器的截斷長度而不是真實可用長度。
  static var maximumRunLength: Int {
    ProcessInfo.processInfo.environment["VCHEWING_RERANK_MAXRUN"].flatMap(Int.init) ?? 12
  }

  /// 對語料做最長匹配切詞，生成 `(讀音序列, 正解)` 案例。
  ///
  /// 只取純漢字連續片段，長度介於 4 與 `maximumRunLength` 之間：
  /// 太短沒有上下文可言，太長會撞到組字區的寬度上限（`compositorWidthLimit` = 20）。
  func makeCases(corpusPath: String, limit: Int) throws -> [(readings: [String], expected: String)] {
    // 不用 `try?` 吞掉錯誤：相對路徑在測試行程裡多半解析不到（工作目錄不是倉庫根），
    // 靜默回傳空陣列只會讓人誤以為「語料不合格」。
    let content = try String(
      contentsOf: URL(fileURLWithPath: corpusPath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)),
      encoding: .utf8
    )
    var result = [(readings: [String], expected: String)]()
    result.reserveCapacity(limit)

    for line in content.split(separator: "\n") {
      var run = [Character]()
      for character in Array(line) + ["\n"] {
        if character.isHanCharacter {
          run.append(character)
          continue
        }
        defer { run.removeAll(keepingCapacity: true) }
        guard (4 ... Self.maximumRunLength).contains(run.count) else { continue }
        guard let segmented = segment(run), segmented.count >= 2 else { continue }
        result.append((segmented, String(run)))
        if result.count >= limit { return result }
      }
    }
    return result
  }

  // MARK: Private

  /// 最長匹配。只要有任何位置匹配不到「讀音唯一」的詞，整段作廢。
  private func segment(_ text: [Character]) -> [String]? {
    var readings = [String]()
    var index = 0
    while index < text.count {
      var matched = false
      let longest = Swift.min(maxWordLength, text.count - index)
      for length in stride(from: longest, through: 1, by: -1) {
        let word = String(text[index ..< index + length])
        guard let reading = wordToReading[word] else { continue }
        // ⚠️ 詞庫的讀音是以 `-` 連接的多音節字串（例：音樂 → `ㄧㄣ-ㄩㄝˋ`），
        // 而 `Homa.Assembler.insertKey` 一次只吃**一個**音節。不拆開的話
        // 整串會被當成查不到的單一讀音而遭拒。
        readings.append(contentsOf: reading.split(separator: "-").map(String.init))
        index += length
        matched = true
        break
      }
      guard matched else { return nil }
    }
    return readings
  }
}

extension Character {
  fileprivate var isHanCharacter: Bool {
    guard let scalar = unicodeScalars.first, unicodeScalars.count == 1 else { return false }
    return (0x4E00 ... 0x9FFF).contains(scalar.value)
  }
}
