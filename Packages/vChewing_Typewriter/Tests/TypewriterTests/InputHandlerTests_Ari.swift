// (c) 2026 and onwards The vChewing Project (MIT-NTL License).
// ====================
// This code is released under the MIT license (SPDX-License-Identifier: MIT)
// ... with NTL restriction stating that:
// No trademark license is granted to use the trade names, trademarks, service
// marks, or product names of Contributor, except as required to fulfill notice
// requirements defined in MIT License.

import Foundation
import Shared
import Testing
@testable import Typewriter

extension InputHandlerTests {
  @Test
  func test_AriCoreMixedInputAndEnterOnlyCommit() throws {
    let (handler, session) = try prepareAriHandler()
    let cleanup = installAriTestGrams(handler)
    defer { cleanup(); handler.prefs.ariIMEEnabled = false; handler.clear() }

    typeSentence("su")
    #expect(handler.ariBuffer.displayedText == "su")
    #expect(session.recentCommissions.isEmpty)

    typeSentence("3helloji3")
    #expect(handler.ariBuffer.displayedText == "你hello我")
    #expect(session.state.displayedText == "你hello我")
    #expect(session.recentCommissions.isEmpty)

    #expect(handler.triageInput(event: KBEvent.KeyEventData.dataEnterReturn.asEvent))
    #expect(session.recentCommissions == ["你hello我"])
    #expect(handler.ariBuffer.isEmpty)
  }

  @Test
  func test_AriSpecificationExampleCorpus() throws {
    let (handler, _) = try prepareAriHandler()
    let cleanup = installAriTestGrams(handler)
    defer { cleanup(); handler.prefs.ariIMEEnabled = false; handler.clear() }

    let examples: [(input: String, expected: String)] = [
      ("abc123", "abc123"),
      ("su", "su"),
      ("su3", "你"),
      ("s3u", "你"),
      ("su3cl3", "你好"),
      ("su3helloji3", "你hello我"),
      ("(hk4g4", "(測試"),
      ("aceru/6aj4", "acer螢幕"),
      ("acer1u32u04", "acer筆電"),
      ("acerru04q06", "acer鍵盤"),
      ("APIji3", "API我"),
      ("example2. ", "example都"),
      ("a ", "a "),
      ("kai@example.com", "kai@example.com"),
      ("https://ari-ime.test/v1.0.0", "https://ari-ime.test/v1.0.0"),
      ("Ari-IME-1.0.0", "Ari-IME-1.0.0"),
      ("README.md", "README.md"),
    ]
    for example in examples {
      handler.clear()
      typeSentence(example.input)
      #expect(handler.ariBuffer.displayedText == example.expected)
    }

    handler.clear()
    handler.ariBuffer.insertLiteral("範例的")
    typeSentence("example2. ")
    handler.ariBuffer.insertLiteral("蒐集")
    #expect(handler.ariBuffer.displayedText == "範例的example都蒐集")
  }

  @Test
  func test_AriAcceptsShuffledToneAndUsesContext() throws {
    let (handler, _) = try prepareAriHandler()
    let cleanup = installAriTestGrams(handler)
    defer { cleanup(); handler.prefs.ariIMEEnabled = false; handler.clear() }

    typeSentence("s3u")
    #expect(handler.ariBuffer.displayedText == "你")
    handler.clear()

    typeSentence("su3cl3")
    #expect(handler.ariBuffer.displayedText == "你好")
    #expect(handler.ariBuffer.cells.map(\.reading) == ["ㄋㄧˇ", "ㄏㄠˇ"])
  }

  @Test
  func test_AriSpaceIsFirstToneOrLiteralWithoutCommitting() throws {
    let (handler, session) = try prepareAriHandler()
    let cleanup = installAriTestGrams(handler)
    defer { cleanup(); handler.prefs.ariIMEEnabled = false; handler.clear() }

    typeSentence("u ")
    #expect(handler.ariBuffer.displayedText == "一")
    #expect(session.recentCommissions.isEmpty)
    handler.clear()

    typeSentence("a ")
    #expect(handler.ariBuffer.displayedText == "a ")
    #expect(session.recentCommissions.isEmpty)
  }

  @Test
  func test_AriSpaceKeepsCompletedEnglishWordIntact() throws {
    let (handler, session) = try prepareAriHandler()
    let cleanup = installAriTestGrams(handler)
    defer { cleanup(); handler.prefs.ariIMEEnabled = false; handler.clear() }

    for word in ["secret", "menu", "project", "about"] {
      handler.clear()
      typeSentence(word + " ")
      #expect(handler.ariBuffer.displayedText == word + " ")
      #expect(handler.ariBuffer.cells.allSatisfy { !$0.isChinese })
    }
    #expect(session.recentCommissions.isEmpty)

    handler.clear()
    typeSentence("hello secret ")
    #expect(handler.ariBuffer.displayedText == "hello secret ")

    // The same key remains a valid first-tone syllable when it starts pending
    // composition rather than ending an already established English word.
    handler.clear()
    typeSentence("t ")
    #expect(handler.ariBuffer.displayedText == "吃")

    handler.clear()
    typeSentence("secret t ")
    #expect(handler.ariBuffer.displayedText == "secret 吃")
  }

  @Test
  func test_AriCursorEditingRawCandidateAndUndo() throws {
    let (handler, session) = try prepareAriHandler()
    let cleanup = installAriTestGrams(handler)
    defer { cleanup(); handler.prefs.ariIMEEnabled = false; handler.clear() }

    typeSentence("su3cl3")
    #expect(handler.ariBuffer.displayedText == "你好")
    #expect(handler.triageInput(event: KBEvent.KeyEventData.dataArrowHome.asEvent))
    typeSentence("X")
    #expect(handler.ariBuffer.displayedText == "X你好")

    handler.clear()
    typeSentence("s3u")
    #expect(handler.triageInput(event: KBEvent.KeyEventData.dataArrowDown.asEvent))
    #expect(session.state.type == .ofCandidates)
    let rawIndex = try #require(handler.ariBuffer.candidates.firstIndex { $0.kind == .rawKeys })
    #expect(handler.confirmAriCandidate(at: rawIndex))
    #expect(handler.ariBuffer.displayedText == "s3u")

    let undo = KBEvent.KeyEventData(flags: .control, chars: "z").asEvent
    #expect(handler.triageInput(event: undo))
    #expect(handler.ariBuffer.displayedText == "你")
  }

  @Test
  func test_AriForcedEnglishPasteSanitizingAndGraphemeDeletion() throws {
    let (handler, _) = try prepareAriHandler()
    let cleanup = installAriTestGrams(handler)
    defer { cleanup(); handler.prefs.ariIMEEnabled = false; handler.clear() }

    let toggleEnglish = KBEvent.KeyEventData(
      flags: .control,
      chars: " ",
      keyCode: KeyCode.kSpace.rawValue
    ).asEvent
    #expect(handler.triageInput(event: toggleEnglish))
    typeSentence("su3")
    #expect(handler.ariBuffer.displayedText == "su3")

    handler.ariPasteboardProvider = { "A\t\nB\u{200B}👨‍👩‍👧‍👦" }
    let paste = KBEvent.KeyEventData(flags: .control, chars: "v").asEvent
    #expect(handler.triageInput(event: paste))
    #expect(handler.ariBuffer.displayedText == "su3A B👨‍👩‍👧‍👦")
    #expect(handler.triageInput(event: KBEvent.KeyEventData.backspace.asEvent))
    #expect(handler.ariBuffer.displayedText == "su3A B")
  }

  @Test
  func test_AriPeelsChineseFromEnglishTailAndProtectsTechnicalText() throws {
    let (handler, _) = try prepareAriHandler()
    let cleanup = installAriTestGrams(handler)
    defer { cleanup(); handler.prefs.ariIMEEnabled = false; handler.clear() }

    typeSentence("aceru/6aj4")
    #expect(handler.ariBuffer.displayedText == "acer螢幕")
    handler.clear()

    typeSentence("acer1u32u04")
    #expect(handler.ariBuffer.displayedText == "acer筆電")
    #expect(handler.ariBuffer.cells.compactMap(\.reading) == ["ㄅㄧˇ", "ㄉㄧㄢˋ"])
    handler.clear()

    let technical = "kai@example.com https://ari-ime.test/v1.0.0 README.md"
    typeSentence(technical)
    #expect(handler.ariBuffer.displayedText == technical)
  }

  @Test
  func test_AriRetokenizesProtectedIdentifierBoundaries() throws {
    let (handler, _) = try prepareAriHandler()
    let cleanup = installAriTestGrams(handler)
    defer { cleanup(); handler.prefs.ariIMEEnabled = false; handler.clear() }

    let cases: [(input: String, literal: String, syllables: [String])] = [
      // Ari 切分特例 3：點號造成的重疊音節。
      ("acerg.3u,4", "acer", ["g.3", "u,4"]),
      // Ari 切分特例 1：精確架構 token。
      ("x86tj3xu3fu4", "x86", ["tj3", "xu3", "fu4"]),
      // Ari 切分特例 2：英數識別字的三位數字尾碼。
      ("user1235;4cl4", "user123", ["5;4", "cl4"]),
    ]
    for item in cases {
      handler.clear()
      typeSentence(item.input)
      #expect(handler.ariBuffer.cells.filter { !$0.isChinese }.map(\.text).joined() == item.literal)
      #expect(handler.ariBuffer.cells.filter(\.isChinese).map(\.typedKeys) == item.syllables)
    }

    let technicalLiterals = [
      "README.3-3", "Ari-IME-2.6.2", "v1.0.0.3-3",
      "127.0.0.1:3000", "https://ari-ime.test/.3-3",
    ]
    for item in technicalLiterals {
      handler.clear()
      typeSentence(item)
      #expect(handler.ariBuffer.displayedText == item)
      #expect(handler.ariBuffer.cells.allSatisfy { !$0.isChinese })
    }
  }

  @Test
  func test_AriPunctuationShortcutAndShiftedPhysicalKeyFamily() throws {
    let (handler, session) = try prepareAriHandler()
    let cleanup = installAriTestGrams(handler)
    defer { cleanup(); handler.prefs.ariIMEEnabled = false; handler.clear() }

    let chineseComma = KBEvent.KeyEventData(
      flags: [.control, .shift], chars: "<", charsSansModifiers: ",", keyCode: 43
    ).asEvent
    #expect(handler.triageInput(event: chineseComma))
    #expect(handler.ariBuffer.displayedText == "，")

    handler.clear()
    let shiftedBracket = KBEvent.KeyEventData(
      flags: .shift, chars: "{", charsSansModifiers: "[", keyCode: 33
    ).asEvent
    #expect(handler.triageInput(event: shiftedBracket))
    #expect(handler.ariBuffer.displayedText == "{")
    #expect(handler.triageInput(event: KBEvent.KeyEventData.dataArrowDown.asEvent))
    #expect(session.state.candidates.map(\.value).contains("["))
    #expect(session.state.candidates.map(\.value).contains("「"))
    #expect(session.state.candidates.map(\.value).contains("『"))
  }

  @Test
  func test_AriCandidateHighlightKeepsCompositionVisible() throws {
    let (handler, session) = try prepareAriHandler()
    let cleanup = installAriTestGrams(handler)
    defer { cleanup(); handler.prefs.ariIMEEnabled = false; handler.clear() }

    typeSentence("su3cl3")
    #expect(handler.ariBuffer.displayedText == "你好")
    #expect(handler.triageInput(event: KBEvent.KeyEventData.dataArrowDown.asEvent))
    session.candidatePairHighlightChanged(at: 0)

    #expect(session.state.type == .ofCandidates)
    #expect(session.state.displayedText == "你好")
    #expect(handler.ariBuffer.displayedText == "你好")
  }

  @Test
  func test_AriRightArrowExpandsCandidatesAndRawKeysFollowPhrases() throws {
    let (handler, session) = try prepareAriHandler()
    let cleanup = installAriTestGrams(handler)
    let controller = MockCandidateController(visible: true)
    session.mockCandidateController = controller
    defer {
      session.mockCandidateController = nil
      cleanup()
      handler.prefs.ariIMEEnabled = false
      handler.clear()
    }

    typeSentence("su3cl3")
    #expect(handler.triageInput(event: KBEvent.KeyEventData.dataArrowDown.asEvent))
    let rawIndex = try #require(handler.ariBuffer.candidates.firstIndex { $0.kind == .rawKeys })
    let lastPhraseIndex = try #require(
      handler.ariBuffer.candidates.lastIndex { $0.kind == .chinese && $0.targetRange.count > 1 }
    )
    #expect(rawIndex == lastPhraseIndex + 1)
    #expect(handler.ariBuffer.candidates[(rawIndex + 1)...].contains { $0.targetRange.count == 1 })

    #expect(!controller.expanded)
    #expect(handler.triageInput(event: KBEvent.KeyEventData.dataArrowRight.asEvent))
    #expect(controller.expanded)
    #expect(controller.lineNavigationCount == 1)
    #expect(handler.ariBuffer.interactionMode == .candidates(focus: 1))

    #expect(handler.triageInput(event: KBEvent.KeyEventData.dataArrowRight.asEvent))
    #expect(controller.highlightNavigationCount == 0)
    #expect(controller.lineNavigationCount == 2)
    #expect(handler.ariBuffer.interactionMode == .candidates(focus: 1))
  }

  @Test
  func test_AriTabRevolvesCandidateWithoutOpeningWindow() throws {
    let (handler, session) = try prepareAriHandler()
    let cleanup = installAriTestGrams(handler)
    defer { cleanup(); handler.prefs.ariIMEEnabled = false; handler.clear() }

    typeSentence("su3cl3")
    #expect(handler.ariBuffer.displayedText == "你好")
    var revolvedValues = [handler.ariBuffer.displayedText]
    #expect(handler.triageInput(event: KBEvent.KeyEventData.dataTab.asEvent))
    #expect(handler.ariBuffer.displayedText == "妳好")
    revolvedValues.append(handler.ariBuffer.displayedText)
    #expect(session.state.type == .ofInputting)
    #expect(handler.ariBuffer.interactionMode == .cursor)
    #expect(session.recentCommissions.isEmpty)

    #expect(handler.triageInput(event: KBEvent.KeyEventData.dataTab.asEvent))
    #expect(handler.ariBuffer.displayedText == "妮好")
    revolvedValues.append(handler.ariBuffer.displayedText)
    #expect(handler.triageInput(event: KBEvent.KeyEventData.dataTab.asEvent))
    #expect(handler.ariBuffer.displayedText == "擬好")
    revolvedValues.append(handler.ariBuffer.displayedText)
    #expect(Set(revolvedValues).count == 4)

    let shiftTab = KBEvent.KeyEventData(
      flags: .shift, chars: "\t", keyCode: KeyCode.kTab.rawValue
    ).asEvent
    #expect(handler.triageInput(event: shiftTab))
    #expect(handler.ariBuffer.displayedText == revolvedValues[2])
    #expect(session.state.type == .ofInputting)
  }

  @Test
  func test_AriTabPlacesRawKeysAfterPhraseCandidates() throws {
    let (handler, session) = try prepareAriHandler()
    let cleanup = installAriTestGrams(handler)
    defer { cleanup(); handler.prefs.ariIMEEnabled = false; handler.clear() }

    typeSentence("1u3ru41p3")
    #expect(handler.ariBuffer.displayedText == "筆記本")

    #expect(handler.triageInput(event: KBEvent.KeyEventData.dataTab.asEvent))
    #expect(handler.ariBuffer.displayedText == "筆記1p3")
    #expect(session.state.type == .ofInputting)
    #expect(handler.ariBuffer.interactionMode == .cursor)
  }

  @Test
  func test_AriTabCanSelectRawKeysAndUndo() throws {
    let (handler, _) = try prepareAriHandler()
    let cleanup = installAriTestGrams(handler)
    defer { cleanup(); handler.prefs.ariIMEEnabled = false; handler.clear() }

    typeSentence("su3")
    #expect(handler.ariBuffer.displayedText == "你")
    #expect(handler.triageInput(event: KBEvent.KeyEventData.dataTab.asEvent))
    #expect(handler.ariBuffer.displayedText == "su3")
    #expect(handler.ariBuffer.cells.allSatisfy { !$0.isChinese })

    // 原始鍵只是候選輪替的一站；下一次 Tab 必須繼續到後面的單字候選。
    #expect(handler.triageInput(event: KBEvent.KeyEventData.dataTab.asEvent))
    #expect(handler.ariBuffer.displayedText == "妳")
    #expect(handler.ariBuffer.cells.allSatisfy { $0.isChinese })

    let shiftTab = KBEvent.KeyEventData(
      flags: .shift, chars: "\t", keyCode: KeyCode.kTab.rawValue
    ).asEvent
    #expect(handler.triageInput(event: shiftTab))
    #expect(handler.ariBuffer.displayedText == "su3")

    let undo = KBEvent.KeyEventData(flags: .control, chars: "z").asEvent
    #expect(handler.triageInput(event: undo))
    #expect(handler.ariBuffer.cells.map(\.isChinese).contains(true))
  }

  @Test
  func test_AriControlPunctuationStaysAfterComposition() throws {
    let (handler, session) = try prepareAriHandler()
    let cleanup = installAriTestGrams(handler)
    defer { cleanup(); handler.prefs.ariIMEEnabled = false; handler.clear() }

    typeSentence("su3cl3")
    #expect(handler.triageInput(event: KBEvent.KeyEventData.dataArrowDown.asEvent))
    #expect(session.state.type == .ofCandidates)
    let controlComma = KBEvent.KeyEventData(
      flags: .control, chars: "\u{1C}", charsSansModifiers: ",", keyCode: 43
    ).asEvent
    #expect(handler.triageInput(event: controlComma))
    #expect(session.state.displayedText == "你好，")
    #expect(handler.ariBuffer.displayedText == "你好，")

    #expect(handler.triageInput(event: KBEvent.KeyEventData.dataEnterReturn.asEvent))
    #expect(session.recentCommissions == ["你好，"])
  }

  @Test
  func test_AriPasteRoutingAndForcedEnglishSuppressesCandidates() throws {
    let (handler, session) = try prepareAriHandler()
    let cleanup = installAriTestGrams(handler)
    defer { cleanup(); handler.prefs.ariIMEEnabled = false; handler.clear() }

    handler.ariPasteboardProvider = { "貼上" }
    typeSentence("su3")
    #expect(handler.ariBuffer.displayedText == "你")
    let commandPaste = KBEvent.KeyEventData(flags: .command, chars: "v").asEvent
    #expect(!handler.triageInput(event: commandPaste))
    #expect(handler.ariBuffer.displayedText == "你")

    let controlPaste = KBEvent.KeyEventData(flags: .control, chars: "v").asEvent
    #expect(handler.triageInput(event: controlPaste))
    #expect(handler.ariBuffer.displayedText == "你貼上")

    handler.clear()
    typeSentence("su3")
    let toggleEnglish = KBEvent.KeyEventData(
      flags: .control, chars: " ", keyCode: KeyCode.kSpace.rawValue
    ).asEvent
    #expect(handler.triageInput(event: toggleEnglish))
    #expect(handler.triageInput(event: KBEvent.KeyEventData.dataArrowDown.asEvent))
    #expect(session.state.type == .ofInputting)
    #expect(handler.ariBuffer.interactionMode == .cursor)
  }

  @Test
  func test_AriLockedSelectionBlocksCrossingCandidate() throws {
    let (handler, _) = try prepareAriHandler()
    let cleanup = installAriTestGrams(handler)
    defer { cleanup(); handler.prefs.ariIMEEnabled = false; handler.clear() }

    typeSentence("su3cl3ji3")
    #expect(handler.triageInput(event: KBEvent.KeyEventData.dataArrowHome.asEvent))
    #expect(handler.triageInput(event: KBEvent.KeyEventData.dataArrowDown.asEvent))
    let selectedIndex = try #require(handler.ariBuffer.candidates.firstIndex { $0.value == "妳好" })
    #expect(handler.confirmAriCandidate(at: selectedIndex))
    #expect(handler.ariBuffer.cells.prefix(2).allSatisfy { $0.locked })

    #expect(handler.triageInput(event: KBEvent.KeyEventData.dataArrowRight.asEvent))
    #expect(handler.triageInput(event: KBEvent.KeyEventData.dataArrowDown.asEvent))
    #expect(!handler.ariBuffer.candidates.contains { $0.value == "好窩" })
  }

  @Test
  func test_AriLearningWaitsForEnterAndSkipsSensitiveInput() throws {
    let (handler, session) = try prepareAriHandler()
    let cleanup = installAriTestGrams(handler)
    defer {
      cleanup()
      handler.currentLM.clearPOMData()
      handler.pomSaveCallback = nil
      handler.prefs.ariIMEEnabled = false
      handler.clear()
    }
    handler.currentLM.clearPOMData()
    var saveCount = 0
    handler.pomSaveCallback = { saveCount += 1 }

    typeSentence("su3")
    #expect(handler.triageInput(event: KBEvent.KeyEventData.dataArrowDown.asEvent))
    let selectedIndex = try #require(handler.ariBuffer.candidates.firstIndex { $0.value == "妳" })
    #expect(handler.confirmAriCandidate(at: selectedIndex))
    #expect(saveCount == 0)
    #expect(handler.triageInput(event: KBEvent.KeyEventData.dataEnterReturn.asEvent))
    #expect(saveCount > 0)
    #expect(session.recentCommissions.last == "妳")

    handler.currentLM.clearPOMData()
    saveCount = 0
    handler.ariSensitiveInputChecker = { true }
    typeSentence("su3")
    #expect(handler.triageInput(event: KBEvent.KeyEventData.dataArrowDown.asEvent))
    let sensitiveIndex = try #require(handler.ariBuffer.candidates.firstIndex { $0.value == "妳" })
    #expect(handler.confirmAriCandidate(at: sensitiveIndex))
    #expect(handler.triageInput(event: KBEvent.KeyEventData.dataEnterReturn.asEvent))
    #expect(saveCount == 0)
  }

  @Test
  func test_AriRejectsStaleMouseCandidateCallback() throws {
    let (handler, session) = try prepareAriHandler()
    let cleanup = installAriTestGrams(handler)
    defer { cleanup(); handler.prefs.ariIMEEnabled = false; handler.clear() }

    typeSentence("su3")
    #expect(handler.triageInput(event: KBEvent.KeyEventData.dataArrowDown.asEvent))
    let expected = try #require(session.state.candidates.first)
    session.state.data.candidates[0] = (keyArray: ["stale"], value: "過期")
    session.candidatePairSelectionConfirmed(at: 0, expectedCandidate: expected)
    #expect(handler.ariBuffer.displayedText == "你")
    #expect(handler.ariBuffer.interactionMode == .candidates(focus: 0))
  }

  private func prepareAriHandler() throws -> (MockInputHandler, MockSession) {
    let handler = try #require(testHandler)
    let session = try #require(testSession)
    handler.clear()
    session.switchState(.ofAbortion())
    session.recentCommissions.removeAll()
    handler.prefs.ariIMEEnabled = true
    handler.prefs.mixedAlphanumericalEnabled = false
    handler.prefs.cassetteEnabled = false
    handler.prefs.keyboardParser = KeyboardParser.ofStandard.rawValue
    handler.composer.ensureParser(arrange: .ofDachen)
    handler.ariSensitiveInputChecker = { false }
    return (handler, session)
  }

  private func installAriTestGrams(_ handler: MockInputHandler) -> () -> () {
    let data = """
    ㄋㄧˇ-ㄏㄠˇ 你好 -0.5
    ㄋㄧˇ-ㄏㄠˇ 妳好 -0.7
    ㄋㄧˇ-ㄏㄠˇ 妮好 -0.8
    ㄋㄧˇ-ㄏㄠˇ 擬好 -0.9
    ㄋㄧˇ 你 -1
    ㄋㄧˇ 妳 -2
    ㄋㄧˇ 妮 -3
    ㄏㄠˇ 好 -1
    ㄨㄛˇ 我 -1
    ㄏㄠˇ-ㄨㄛˇ 好窩 -0.7
    ㄘㄜˋ-ㄕˋ 測試 -0.5
    ㄘㄜˋ 測 -1
    ㄕˋ 試 -1
    ㄧ 一 -1
    ㄧˇ 以 -1
    ㄡ 歐 -1
    ㄥˊ 嗯 -1
    ㄉㄡ 都 -1
    ㄔ 吃 -1
    ㄅㄧˇ-ㄉㄧㄢˋ 筆電 -0.5
    ㄅㄧˇ 筆 -1
    ㄉㄧㄢˋ 電 -1
    ㄅㄧˇ-ㄐㄧˋ-ㄅㄣˇ 筆記本 -0.4
    ㄐㄧˋ 記 -1
    ㄅㄣˇ 本 -1
    ㄅㄣˇ 苯 -2
    ㄅㄣˇ 畚 -3
    ㄧㄥˊ-ㄇㄨˋ 螢幕 -0.5
    ㄧㄥˊ 螢 -1
    ㄇㄨˋ 幕 -1
    ㄐㄧㄢˋ-ㄆㄢˊ 鍵盤 -0.5
    ㄐㄧㄢˋ 鍵 -1
    ㄆㄢˊ 盤 -1
    ㄕㄡˇ-ㄧㄝˋ 首頁 -0.5
    ㄕㄡˇ 首 -1
    ㄧㄝˋ 頁 -1
    ㄔㄨˇ-ㄌㄧˇ-ㄑㄧˋ 處理器 -0.5
    ㄔㄨˇ 處 -1
    ㄌㄧˇ 理 -1
    ㄑㄧˋ 器 -1
    ㄓㄤˋ-ㄏㄠˋ 帳號 -0.5
    ㄓㄤˋ 帳 -1
    ㄏㄠˋ 號 -1
    """
    let grams = extractGrams(from: data)
    grams.forEach { handler.currentLM.insertTemporaryData(unigram: $0, isFiltering: false) }
    return { handler.currentLM.clearTemporaryData(isFiltering: false) }
  }
}
