// (c) 2026 and onwards The vChewing Project (MIT-NTL License).
// ====================
// This code is released under the MIT license (SPDX-License-Identifier: MIT)
// ... with NTL restriction stating that:
// No trademark license is granted to use the trade names, trademarks, service
// marks, or product names of Contributor, except as required to fulfill notice
// requirements defined in MIT License.

import CharLM
import Foundation
import HomaReranker
import LMAssemblyMaterials4Tests
import Testing

@testable import MainAssembly4Darwin

// MARK: - RerankCase

/// 驗收案例：一組拼音鍵序，以及在「有上下文」的前提下應該得到的組字區內容。
struct RerankCase {
  let sequence: String
  let expected: String
  let note: String
}

// MARK: - RerankOutcome

struct RerankOutcome {
  let passed: Int
  let total: Int
  let failures: [(RerankCase, String)]
  let worstKeystrokeMS: Double
  let meanKeystrokeMS: Double

  var accuracy: Double { total == 0 ? 0 : Double(passed) / Double(total) }
}

// MARK: - 上下文重排的端到端驗收

/// 設計文件 `DevLab/AICandidateSelection_Design.md` 待辦第 8 項所要求的驗收關卡。
///
/// ## 為什麼不能沿用 `HomaTests_ContextAccuracy.swift` 的 `testBench01`
///
/// 那條測試住在 `vChewing_Homa` 裡，而依賴方向是 `CharLM → Homa`、不可逆——
/// Homa 套件在型別層面就看不到 reranker。`testBench01` 量的永遠是「沒有 reranker 的
/// Homa 基線」，它是防迴歸的護欄，不是本功能的驗收。
///
/// 真正的驗收只能在這裡做，因為只有 `MainAssembly4DarwinTests` 同時具備：
///
/// - **真實原廠詞庫**（`VanguardFactoryDict4Typing.txtMap`），詞庫先驗才會參與融合
/// - **真實模型權重**（`charlm-cht.bin`）
/// - **完整打字模擬**（NSEvent → FSM → Tekkon → Homa → LM → IMEState）
///
/// ## ⚠️ 三個踩過的坑
///
/// 1. **必須掛進 `MainAssemblyTests` 這個既有 suite，不能另開一個。** 另開的 suite 會
///    與它平行執行，而兩者共用 `UserDefaults.unitTests`、IMKServer 與全域原廠詞庫；
///    初版就是因此死鎖（0% CPU 掛住十分鐘）。
/// 2. **`testHandler` 用的是獨立建構的 `testLM`**，不走 `Shared.InputMode` 的語言模型
///    快取，因此 `LMMgr_Core.swift` 裡那段「依偏好注入 reranker」的程式碼**碰不到它**。
///    必須自己把 reranker 掛上去。
/// 3. **模型載入失敗是靜默的**（契約 4：退化安全）。若 `charlm-cht.bin` 沒被打包進
///    測試可見的 bundle，A/B 兩組會跑出一模一樣的數字而且不報錯，很容易被誤讀成
///    「模型沒有效果」。因此前置測試會先斷言模型確實載入。
extension MainAssemblyTests {
  // MARK: - 前置條件

  /// **這條必須先過。**它擋掉整個驗收最危險的假陰性來源。
  @Test("[驗收][前置] 上下文重排的模型與詞庫都確實就緒")
  func test601_ContextualReranking_Prerequisites() throws {
    #expect(
      LMMgr.getCoreDictionaryDBPath(factory: true) != nil,
      "找不到 VanguardFactoryDict4Typing.txtMap，詞庫先驗不會參與融合。"
    )
    #expect(
      CharLMRerankerMgr.reranker(for: .imeModeCHT) != nil,
      "charlm-cht.bin 未被載入。A/B 會跑出相同數字且不報錯——這正是要擋掉的假陰性。"
    )
    // 簡體目前刻意沒有模型（設計文件 §4.6：先做繁體）。這條同時記錄該現況。
    #expect(
      CharLMRerankerMgr.reranker(for: .imeModeCHS) == nil,
      "簡體模型出現了？請一併更新設計文件 §4.6 與本測試。"
    )
  }

  // MARK: - A/B 驗收

  @Test("[驗收] 上下文重排的 A/B 準確率與延遲")
  func test602_ContextualReranking_ABComparison() throws {
    try #require(CharLMRerankerMgr.reranker(for: .imeModeCHT) != nil)
    let factoryPath = try #require(LMMgr.getCoreDictionaryDBPath(factory: true))

    // ⚠️ 原廠詞庫是**全域**狀態（static factoryTrie）。這裡換成真實詞庫之後，
    // 一定要在離開前換回測試詞庫，否則同 suite 的其他測試會拿到非預期的候選。
    defer {
      _ = LMAssembly.LMInstantiator.connectToTestFactoryDictionary(
        textMapData: LMATestsData.textMapTestCoreLMData
      )
    }
    LMAssembly.LMInstantiator.connectFactoryDictionary(textMapPath: factoryPath)

    let baseline = measureReranking(enabled: false)
    let treatment = measureReranking(enabled: true)

    reportReranking(baseline: baseline, treatment: treatment)

    // 延遲守門：設計文件 §3 約束 B 的預算是每次按鍵 10ms。
    #expect(
      treatment.worstKeystrokeMS < 10.0,
      "最差按鍵延遲 \(treatment.worstKeystrokeMS)ms 超出 10ms 預算。"
    )
    // 準確率守門：重排**不得讓結果變差**。這是本階段唯一該硬性要求的事——
    // 「變好多少」是拿來調 λ 的觀測值，不該寫成會擋 CI 的斷言。
    #expect(
      treatment.passed >= baseline.passed,
      "開啟重排後準確率下降（\(baseline.passed) → \(treatment.passed)），發生迴歸。"
    )
  }

  // MARK: - POM 與重排的優先順序

  /// 個人化必須壓過統計模型：使用者親手改過的字，重排器不得改回去。
  ///
  /// 這條是**迴歸測試**。初版的 `applyContextualReranking()` 註解宣稱
  /// 「POM 的覆寫會把節點標記為已覆寫，重排器據此自動跳過」，但那不成立——
  /// `retrievePOMSuggestions` 呼叫 `overrideCandidateLiteral` 時沒有傳
  /// `isExplicitlyOverridden`（預設 false），而 `fetchCandidates` 回傳的權重是
  /// 原始詞庫機率、不含覆寫加成。POM 的建議在重排時是零優勢的，會被 LM 直接推翻。
  ///
  /// 現在改由 `λ_POM` 顯式參與融合（設計文件 §4.4 的三分工）。
  ///
  /// > ⚠️ 不能用 `prepareBasicComposition(sequence:)`：它內部會 `clearTestPOM()`，
  /// > 一呼叫就把剛教會的記憶抹掉。必須照 `test104` 的模式手動重置與輸入。
  @Test("[驗收] POM 的個人化選擇不會被上下文重排推翻")
  func test603_ContextualReranking_RespectsPOM() throws {
    try #require(CharLMRerankerMgr.reranker(for: .imeModeCHT) != nil)
    let factoryPath = try #require(LMMgr.getCoreDictionaryDBPath(factory: true))

    let previousPref = PrefMgr.shared.applyContextualCandidateReranking
    let previousReranker = testLM.contextualReranker
    let previousParser = testHandler.prefs.keyboardParser
    let previousPOM = testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel
    let previousSCPC = testHandler.prefs.useSCPCTypingMode
    defer {
      PrefMgr.shared.applyContextualCandidateReranking = previousPref
      testLM.contextualReranker = previousReranker
      testHandler.prefs.keyboardParser = previousParser
      testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = previousPOM
      testHandler.prefs.useSCPCTypingMode = previousSCPC
      testHandler.ensureKeyboardParser()
      clearTestPOM()
      _ = LMAssembly.LMInstantiator.connectToTestFactoryDictionary(
        textMapData: LMATestsData.textMapTestCoreLMData
      )
    }
    LMAssembly.LMInstantiator.connectFactoryDictionary(textMapPath: factoryPath)

    testHandler.prefs.keyboardParser = KeyboardParser.ofHanyuPinyin.rawValue
    testHandler.ensureKeyboardParser()
    testHandler.prefs.useSCPCTypingMode = false
    testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = true
    PrefMgr.shared.applyContextualCandidateReranking = true
    testLM.contextualReranker = CharLMRerankerMgr.reranker(for: .imeModeCHT)
    testHandler.currentLM.syncPrefs()
    clearTestPOM()

    let sequence = "di2ren2fa1dong4gong1shi4"
    let modelChoice = "敵人發動攻勢" // 重排器偏好的
    let userChoice = "敵人發動公式" // 使用者硬要的

    // ① 基準：沒有 POM 記憶時，重排器把詞庫首選「公式」改成「攻勢」。
    testSession.switchState(.ofAbortion())
    typeSentenceOrCandidates(sequence)
    #expect(
      testSession.state.displayedText == modelChoice,
      "前提不成立：重排器沒有把它改成「\(modelChoice)」，這條測試就失去意義了。"
    )

    // ② 教 POM：使用者開選字窗、手動選回「公式」。
    testSession.switchState(testHandler.generateStateOfCandidates())
    let candidates = testSession.state.candidates.map(\.value)
    let targetIndex = try #require(
      candidates.firstIndex(of: "公式"),
      "選字窗裡找不到「公式」，候選為：\(candidates)"
    )
    testSession.candidatePairSelectionConfirmed(at: targetIndex)
    #expect(testSession.state.displayedText == userChoice)

    // ③ 重打同一句：POM 記住的選擇必須存活，不得被重排器改回去。
    testSession.switchState(.ofAbortion())
    typeSentenceOrCandidates(sequence)
    let finalText = testSession.state.displayedText
    #expect(
      finalText == userChoice,
      "重排器推翻了使用者教給 POM 的選擇（得到「\(finalText)」）。λ_POM = \(CharLMReranker.defaultLambdaPOM) 不足以壓過 LM，或融合路徑沒接通。"
    )
  }

  // MARK: - 內部

  /// 驗收案例集。
  ///
  /// 全部都是**真同音組**——同一組讀音對應多個候選詞。挑選原則：
  /// 正解不是詞庫詞頻首選，因此非得靠上下文才選得對。
  ///
  /// > 擴充時請優先加入你實際打字時遇到「跑出奇怪的字」的序列（設計文件待辦第 2 項）。
  /// > 目前只有 5 條，**遠不足以支撐統計結論**，只能當作煙霧測試與迴歸護欄。
  fileprivate static var rerankCases: [RerankCase] {
    [
      .init(
        sequence: "wo3xie3le5yi1zhi1dian4nao3cheng2shi4",
        expected: "我寫了一支電腦程式",
        note: "ㄔㄥˊ-ㄕˋ：程式／城市／呈示。電腦之後應為程式。"
      ),
      .init(
        sequence: "zhe4zuo4cheng2shi4",
        expected: "這座城市",
        note: "同一組讀音，換了前文就該換答案。"
      ),
      .init(
        sequence: "di2ren2fa1dong4gong1shi4",
        expected: "敵人發動攻勢",
        note: "ㄍㄨㄥ-ㄕˋ：公式／公事／公示／工事／攻勢。"
      ),
      .init(
        sequence: "zhe4jian4shi4de5yi4yi4",
        expected: "這件事的意義",
        note: "ㄧˋ-ㄧˋ：意義／異議／意譯。"
      ),
      .init(
        sequence: "ta1ti2chu1yi4yi4",
        expected: "他提出異議",
        note: "同上讀音的反向案例，避免過度擬合單一前文。"
      ),
    ]
  }

  fileprivate func measureReranking(enabled: Bool) -> RerankOutcome {
    let previousPref = PrefMgr.shared.applyContextualCandidateReranking
    let previousReranker = testLM.contextualReranker
    let previousParser = testHandler.prefs.keyboardParser
    let previousPOM = testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel
    defer {
      PrefMgr.shared.applyContextualCandidateReranking = previousPref
      testLM.contextualReranker = previousReranker
      testHandler.prefs.keyboardParser = previousParser
      testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = previousPOM
      testHandler.ensureKeyboardParser()
    }

    // 案例以漢語拼音書寫（可讀性遠高於大千鍵序）。預設佈局是大千，非切不可。
    testHandler.prefs.keyboardParser = KeyboardParser.ofHanyuPinyin.rawValue
    testHandler.ensureKeyboardParser()
    // POM 關閉：這一輪要量的是 LM 的貢獻，個人化記憶會混淆歸因。
    testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = false
    testHandler.currentLM.syncPrefs()

    PrefMgr.shared.applyContextualCandidateReranking = enabled
    // ⚠️ 見型別文件的坑 ②：非得手動掛上不可，`LMMgr` 那條注入路徑碰不到 `testLM`。
    testLM.contextualReranker = enabled ? CharLMRerankerMgr.reranker(for: .imeModeCHT) : nil

    let cases = Self.rerankCases

    // ⚠️ 暖機不可省略。詞庫的首次查詢要建 trie 快取、頁入十餘 MB 的 TextMap，
    // 成本遠大於重排本身。若不暖機，先跑的那一組會扛下全部冷啟動成本，
    // 量出來的會是「先跑的比較慢」而不是「重排比較慢」——初版正是這樣量錯的
    // （關閉重排 7.6ms vs 開啟重排 1.9ms，方向完全相反）。
    cases.forEach { _ = prepareBasicComposition(sequence: $0.sequence) }

    var passed = 0
    var failures: [(RerankCase, String)] = []
    var keystrokeDurations: [Double] = []

    for testCase in cases {
      let keystrokeCount = Swift.max(1, testCase.sequence.count)
      let started = DispatchTime.now().uptimeNanoseconds
      let actual = prepareBasicComposition(sequence: testCase.sequence)
      let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000.0
      keystrokeDurations.append(elapsedMS / Double(keystrokeCount))

      if actual == testCase.expected {
        passed += 1
      } else {
        failures.append((testCase, actual))
      }
    }

    return RerankOutcome(
      passed: passed,
      total: cases.count,
      failures: failures,
      worstKeystrokeMS: keystrokeDurations.max() ?? 0,
      meanKeystrokeMS: keystrokeDurations.isEmpty
        ? 0
        : keystrokeDurations.reduce(0, +) / Double(keystrokeDurations.count)
    )
  }

  fileprivate func reportReranking(baseline: RerankOutcome, treatment: RerankOutcome) {
    func fmt(_ value: Double) -> String { String(format: "%.3f", value) }
    let delta = treatment.accuracy - baseline.accuracy
    print("""

    ┌─ 上下文重排 A/B 驗收 ────────────────────────────────
    │                關閉重排      開啟重排
    │ 準確率         \(fmt(baseline.accuracy))       \(fmt(treatment.accuracy))\
       （\(delta >= 0 ? "+" : "")\(fmt(delta))）
    │ 通過           \(baseline.passed)/\(baseline.total)            \
    \(treatment.passed)/\(treatment.total)
    │ 每鍵平均       \(fmt(baseline.meanKeystrokeMS))ms     \(fmt(treatment.meanKeystrokeMS))ms
    │ 每鍵最差       \(fmt(baseline.worstKeystrokeMS))ms     \
    \(fmt(treatment.worstKeystrokeMS))ms     （預算 10ms）
    └──────────────────────────────────────────────────────
    """)

    for (label, outcome) in [("關閉重排", baseline), ("開啟重排", treatment)] {
      guard !outcome.failures.isEmpty else { continue }
      print("── \(label)：未通過案例 ──")
      outcome.failures.forEach { testCase, actual in
        print("  期望： \(testCase.expected)")
        print("  實得： \(actual)")
        print("  說明： \(testCase.note)")
        print("")
      }
    }
  }
}
