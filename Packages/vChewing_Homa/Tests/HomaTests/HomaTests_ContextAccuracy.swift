// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import HomaSharedTestComponents
import Testing

@testable import Homa

// MARK: - HomaContextAccuracyTests

/// 組句「上下文準確率」的診斷與基準測試。
///
/// 本測試套件的存在目的有三：
///
/// 1. **診斷**：以可執行的方式證明目前組句品質的兩項結構性限制（見 `Diag_*` 測試）。
/// 2. **基準**：提供一個可重複量測的準確率數字，讓任何「改善選字」的嘗試有客觀依據
///    （見 `Bench_*` 測試）。**在動手改演算法之前，先跑這個拿到基線。**
/// 3. **防迴歸**：任何對 PathFinder / Node 評分邏輯的改動都必須先通過這裡。
///
/// - Remark: 本套件刻意不依賴原廠詞庫，改用內嵌的小型測試語料。
///   這樣才能在毫秒級完成、且結果不隨詞庫版本漂移。
@Suite(.serialized)
public struct HomaContextAccuracyTests: HomaTestSuite {
  // MARK: Internal

  // MARK: - 診斷測試

  /// 診斷 ①：DP 只會採用每個節點內權重最高的那個元圖，不會在節點內探索次佳候選。
  ///
  /// `Homa.PathFinder.run()` 的主迴圈是
  /// `for (length, nextNode) in config.segments[i]` → `nextNode.currentGram`，
  /// 而 `currentGram` 恆為 `grams[currentGramIndex]`（預設 0）。
  /// 元圖陣列則由 `Assembler.sortGram` 依「幅長優先、其次機率」排序。
  ///
  /// 換言之：**DP 探索的是「怎麼斷詞」，而不是「同一段讀音該選哪個同音詞」。**
  /// 後者完全由靜態詞頻決定，上下文無從介入。
  @Test("[Homa][Diag] DP 不在節點內探索次佳同音詞")
  func testDiag01_DPDoesNotExploreAlternativeGramsWithinNode() throws {
    // 「ㄓˋ ㄋㄥˊ」有兩個同音詞：只能（詞頻較高）、智能（詞頻較低）。
    let rawData = """
    zhi4 只 -5.4
    zhi4 智 -5.5
    neng2 能 -5.1
    zhi4-neng2 只能 -4.0
    zhi4-neng2 智能 -4.5
    """
    let lm = TestLM(rawData: rawData)
    let assembler = try Self.makeAssembler(lm: lm, readings: ["zhi4", "neng2"])
    let result = assembler.assemble().values.joined()

    // 現況：永遠是詞頻較高的「只能」，與上下文無關。
    #expect(
      result == "只能",
      "若此處不再是「只能」，代表 DP 的節點內探索行為已被修改，請同步更新本測試的敘述。"
    )
  }

  /// 診斷 ②：雙元圖**確實**能提升排序較低的同音詞——但機制出人意料。
  ///
  /// 直覺上會以為 `getScore(previous:)` 的查詢條件
  /// `filter { $0.previous == previous && $0.current == currentValue }`
  /// 因為限定了 `current == currentValue`，所以只能替既有首選加分、無法改選。
  ///
  /// **但實際上不是這樣。** 真正的原因是 `Assembler.sortGram` 依機率排序時
  /// **不區分單元圖與雙元圖**，所以一條高機率雙元圖會直接排到 `grams[0]`、
  /// 成為該節點的 `currentGram`。於是 `currentValue` 本身就已經是雙元圖的值了，
  /// 後續查詢自然對得上。
  ///
  /// 換言之：雙元圖是靠「搶佔 `grams[0]`」生效的，而不是靠 `getScore()` 的比較邏輯。
  /// 這個機制能work，但副作用嚴重——見 `testDiag04`。
  @Test("[Homa][Diag] 雙元圖靠搶佔 grams[0] 來提升同音詞")
  func testDiag02_BigramPromotesViaSortOrder() throws {
    // 語料設計：
    //   ・「只能」單元圖 (-4.0) 高於「智能」(-4.5)。
    //   ・但 P(智能|人工) = -1.5 機率遠高於任何單元圖 → 排序後佔據 grams[0]。
    let rawData = """
    \(Self.singleSyllableFloor)
    ren2-gong1 人工 -3.5
    zhi4-neng2 只能 -4.0
    zhi4-neng2 智能 -4.5
    zhi4-neng2 智能 -1.5 人工
    """
    let lm = TestLM(rawData: rawData)
    let assembler = try Self.makeAssembler(
      lm: lm, readings: ["ren2", "gong1", "zhi4", "neng2"]
    )
    let result = assembler.assemble().values.joined()

    #expect(result == "人工智能")
  }

  /// 診斷 ④：**雙元圖的分數會洩漏到完全不相符的上下文。這是一個實際的缺陷。**
  ///
  /// 成因鏈：
  ///
  /// 1. `Assembler.sortGram` 依機率排序，不區分單元圖／雙元圖
  ///    → 高機率雙元圖佔據 `grams[0]`，成為 `currentGram`。
  /// 2. `Node.unigramScore` 的 `default` 分支（即無覆寫狀態時）回傳
  ///    `currentGram?.probability`（`Homa_Node.swift:192`）。
  /// 3. 當前文**對不上**該雙元圖時，`getScore()` 會退回 `unigramScore`，
  ///    但那個值已經是**雙元圖的高機率**了。
  ///
  /// 結果：一條 `P(智能|人工)` 的雙元圖，會讓「智能」在**任何**前文之下
  /// 都以 -1.5 的高分出現，即使前文是毫不相干的「我」。
  ///
  /// 正確行為應為：前文對不上時退回真正的單元圖分數（本例為「只能」-4.0），
  /// 亦即 `unigramScore` 的 `default` 分支應回傳 `firstUnigram.probability`。
  ///
  /// - Note: 此缺陷對原廠詞庫目前無影響（原廠詞庫不提供雙元圖），
  ///   但只要雙元圖資料一旦進入節點（例如補上詞庫雙元圖、或 POM 注入），
  ///   就會立刻顯現。**在補雙元圖資料之前必須先修這個。**
  @Test("[Homa][Diag] 雙元圖分數洩漏至不相符的上下文")
  func testDiag04_BigramScoreLeaksIntoMismatchedContext() throws {
    // 語料裡唯一的雙元圖前文是「人工」，但我們用「我」當前文。
    let rawData = """
    \(Self.singleSyllableFloor)
    zhi4-neng2 只能 -4.0
    zhi4-neng2 智能 -4.5
    zhi4-neng2 智能 -1.5 人工
    """
    let lm = TestLM(rawData: rawData)
    let assembler = try Self.makeAssembler(
      lm: lm, readings: ["wo3", "zhi4", "neng2"]
    )
    let result = assembler.assemble().values.joined()

    // 現況（缺陷）：得到「我智能」。
    // 前文「我」與雙元圖前文「人工」毫不相干，卻依然拿到了 -1.5 的分數。
    #expect(
      result == "我智能",
      """
      若此處已變成「我只能」，代表 unigramScore 的分數洩漏已被修復——
      這正是本測試希望看到的結果，請把本測試改為正向斷言。
      """
    )
  }

  /// 診斷 ③：雙元圖在「首選本來就正確」時確實會生效（證明機制本身沒壞）。
  ///
  /// 這條測試與診斷 ② 對照，用來證明問題出在「無法改選」而非「雙元圖完全沒接上」。
  @Test("[Homa][Diag] 雙元圖可加強既有首選")
  func testDiag03_BigramReinforcesTopRankedGram() throws {
    let rawData = """
    \(Self.singleSyllableFloor)
    ren2-gong1 人工 -3.5
    zhi4-neng2 智能 -4.0
    zhi4-neng2 只能 -4.5
    zhi4-neng2 智能 -1.5 人工
    """
    let lm = TestLM(rawData: rawData)
    let assembler = try Self.makeAssembler(
      lm: lm, readings: ["ren2", "gong1", "zhi4", "neng2"]
    )
    let result = assembler.assemble().values.joined()

    #expect(result == "人工智能")
  }

  // MARK: - 準確率基準

  /// 基準：在同音詞語料上量測組句準確率。
  ///
  /// **這是本套件最重要的產出。** 任何「讓選字變聰明」的改動，
  /// 都應該先跑這條測試拿到基線數字，改完再跑一次比較。
  ///
  /// 目前的門檻刻意設得很低（只要不低於基線即可），
  /// 目的是防迴歸而非防止改善。改善之後請一併把門檻往上調。
  @Test("[Homa][Bench] 同音詞消歧準確率基準")
  func testBench01_HomophoneDisambiguationAccuracy() throws {
    let lm = TestLM(rawData: Self.homophoneCorpusLM)
    var passed = 0
    var failures: [(BenchCase, String)] = []

    for benchCase in Self.homophoneCases {
      let assembler = try Self.makeAssembler(lm: lm, readings: benchCase.readings)
      let actual = assembler.assemble().values.joined()
      if actual == benchCase.expected {
        passed += 1
      } else {
        failures.append((benchCase, actual))
      }
    }

    let total = Self.homophoneCases.count
    let accuracy = Double(passed) / Double(total)

    print("""

    ┌─ 組句準確率基準 ─────────────────────────────
    │ 通過： \(passed) / \(total)
    │ 準確率： \(String(format: "%.1f%%", accuracy * 100))
    └──────────────────────────────────────────────
    """)

    if !failures.isEmpty {
      print("── 未通過案例 ──")
      failures.forEach { benchCase, actual in
        print("  讀音： \(benchCase.readings.joined(separator: "-"))")
        print("  期望： \(benchCase.expected)")
        print("  實得： \(actual)")
        print("  說明： \(benchCase.note)")
        print("")
      }
    }

    // 基線門檻。改善演算法之後請把這個數字往上調。
    #expect(
      accuracy >= Self.accuracyBaseline,
      "準確率 \(accuracy) 低於基線 \(Self.accuracyBaseline)，可能發生迴歸。"
    )
  }

  /// 延遲守門：組句必須在預算內完成。
  ///
  /// 輸入法每次按鍵都會觸發 `assemble()`。快速打字者的按鍵間隔可低至 60–80ms，
  /// 而這段時間還要分給 Tekkon 解析、UI 更新與 IMK 往返。
  /// 因此組句本身的預算抓 **10ms**。
  ///
  /// 任何 reranker（含未來的神經網路模型）如果要掛進**每次按鍵**的路徑上，
  /// 都必須先通過這條測試。這也是為什麼設計上建議把 reranker 放在
  /// 「選字窗開啟時」而非「每次按鍵」。
  @Test("[Homa][Bench] 組句延遲預算守門")
  func testBench02_AssemblyLatencyBudget() throws {
    let lm = TestLM(rawData: Self.homophoneCorpusLM)
    let readings = Self.homophoneCases.flatMap(\.readings)

    // 暖身，排除首次查詢快取未命中的干擾。
    let assembler = try Self.makeAssembler(lm: lm, readings: Array(readings.prefix(8)))
    _ = assembler.assemble()
    assembler.clear()

    let iterations = 200
    var worstCase: Double = 0
    var total: Double = 0

    for i in 0 ..< iterations {
      assembler.clear()
      let slice = Self.homophoneCases[i % Self.homophoneCases.count].readings
      let elapsed = try Self.measureTime {
        for reading in slice { try assembler.insertKey(reading) }
        _ = assembler.assemble()
      }
      worstCase = max(worstCase, elapsed)
      total += elapsed
    }

    let averageMS = (total / Double(iterations)) * 1_000
    let worstMS = worstCase * 1_000

    print("""

    ┌─ 組句延遲 ───────────────────────────────────
    │ 平均： \(String(format: "%.3f ms", averageMS))
    │ 最差： \(String(format: "%.3f ms", worstMS))
    │ 預算： \(String(format: "%.1f ms", Self.latencyBudgetMS))
    └──────────────────────────────────────────────
    """)

    #expect(
      averageMS < Self.latencyBudgetMS,
      "平均組句耗時 \(averageMS)ms 超出預算 \(Self.latencyBudgetMS)ms。"
    )
  }

  // MARK: Private

  /// 一則基準案例：一組讀音、其正確輸出、以及這則案例想考驗什麼。
  private struct BenchCase {
    let readings: [String]
    let expected: String
    let note: String
  }

  /// 建立組字器並插入整串讀音。
  ///
  /// - Important: 一律使用 `try` 而非 `try?`。`Homa.Assembler.insertKeys()` 會驗證
  ///   **每個單獨讀音**是否至少查得到一筆單音節結果，查不到就拋 `givenKeyHasNoResults`
  ///   （見 `Homa_Assembler.swift:190`）。若用 `try?` 吞掉，該讀音會被靜默略過，
  ///   導致組句結果殘缺卻看不出原因——本檔案初版就踩過這個坑。
  private static func makeAssembler(
    lm: TestLM,
    readings: [String]
  ) throws
    -> Homa.Assembler {
    let assembler = Homa.Assembler(gramQuerier: { lm.queryGrams($0) })
    for reading in readings {
      try assembler.insertKey(reading)
    }
    return assembler
  }

  /// 組句延遲預算（毫秒）。
  private static let latencyBudgetMS: Double = 10.0

  /// 準確率基線。**這是「目前現況」而非「目標」**。
  /// 改善演算法之後請往上調，讓它變成防迴歸的護欄。
  private static let accuracyBaseline: Double = 0.4

  /// 測試語料的語言模型資料。
  ///
  /// 格式（沿用 `TestLM`）：`讀音 詞彙 對數機率 [前文]`
  /// 第四欄存在時即為雙元圖，代表 P(詞彙 | 前文)。
  ///
  /// 語料刻意設計成「同一組讀音在不同上下文下有不同正解」，
  /// 這正是靜態詞頻無法處理、而上下文模型能處理的情境。
  private static let homophoneCorpusLM = """
  \(singleSyllableFloor)
  ren2-gong1 人工 -3.5
  zhi4-neng2 只能 -4.0
  zhi4-neng2 智能 -4.5
  zhi4-neng2 智能 -1.5 人工
  zhi4-neng2 只能 -1.6 我
  gong1-shi4 公事 -3.0
  gong1-shi4 公式 -4.8
  gong1-shi4 公示 -5.2
  gong1-shi4 公式 -1.4 數學
  shu4-xue2 數學 -3.8
  shang4-ban1 上班 -3.6
  ji4-suan4 計算 -3.9
  yi1-ge4 一個 -2.8
  bang1-mang2 幫忙 -3.7
  """

  /// 單音節保底條目。
  ///
  /// Homa 的 `insertKey()` 會逐一驗證每個讀音是否查得到**單音節**結果，
  /// 查不到就拋 `givenKeyHasNoResults`、該讀音根本插不進組字器。
  /// 因此測試語料裡出現過的每個音節都必須在此列出。
  ///
  /// 分數刻意壓低（多在 -5 附近），確保多音節詞在 DP 中仍能勝出。
  private static let singleSyllableFloor = """
  ren2 人 -5.0
  gong1 公 -5.2
  gong1 工 -5.3
  wo3 我 -2.0
  ta1 他 -2.2
  zhi4 只 -5.4
  zhi4 智 -5.5
  neng2 能 -5.1
  shu4 數 -5.6
  xue2 學 -5.2
  qu4 去 -2.5
  shang4 上 -5.0
  ban1 班 -5.4
  ji4 計 -5.5
  suan4 算 -5.6
  yi1 一 -4.0
  ge4 個 -4.2
  hen3 很 -2.4
  bang1 幫 -5.3
  mang2 忙 -5.4
  shi4 是 -4.5
  shi4 事 -5.0
  shi4 式 -5.6
  """

  /// 基準案例集。
  ///
  /// 每一則都是真實使用者會遇到的同音混淆情境。
  /// 若要擴充，請優先加入你實際打字時遇到「跑出奇怪的字」的那些序列。
  private static let homophoneCases: [BenchCase] = [
    .init(
      readings: ["ren2", "gong1", "zhi4", "neng2"],
      expected: "人工智能",
      note: "需要 P(智能|人工) 才能勝過詞頻較高的「只能」。"
    ),
    .init(
      readings: ["wo3", "zhi4", "neng2"],
      expected: "我只能",
      note: "同一組讀音，換了前文就該換答案。純詞頻做不到這件事。"
    ),
    .init(
      readings: ["shu4", "xue2", "gong1", "shi4"],
      expected: "數學公式",
      note: "「公事」詞頻最高，但在「數學」之後應為「公式」。"
    ),
    .init(
      readings: ["wo3", "qu4", "gong1", "shi4"],
      expected: "我去公事",
      note: "與上一則同讀音、但前文對不上雙元圖，應回落到詞頻首選「公事」。"
        + "目前實得「公式」，正是 §2 限制 ② 的分數洩漏缺陷："
        + "P(公式|數學) 這條雙元圖靠 sortGram 搶佔 grams[0]，在任何前文下都生效。"
    ),
    .init(
      readings: ["ta1", "hen3", "bang1", "mang2"],
      expected: "他很幫忙",
      note: "無同音競爭的基本案例，確保改動不會破壞既有正確結果。"
    ),
  ]
}
