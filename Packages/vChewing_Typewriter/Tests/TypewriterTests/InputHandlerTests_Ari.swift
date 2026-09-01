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
  func test_AriCommandPasteAndForcedEnglishSuppressesCandidates() throws {
    let (handler, session) = try prepareAriHandler()
    let cleanup = installAriTestGrams(handler)
    defer { cleanup(); handler.prefs.ariIMEEnabled = false; handler.clear() }

    handler.ariPasteboardProvider = { "貼上" }
    let commandPaste = KBEvent.KeyEventData(flags: .command, chars: "v").asEvent
    #expect(handler.triageInput(event: commandPaste))
    #expect(handler.ariBuffer.displayedText == "貼上")

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
    ㄋㄧˇ 你 -1
    ㄋㄧˇ 妳 -2
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
    ㄅㄧˇ-ㄉㄧㄢˋ 筆電 -0.5
    ㄅㄧˇ 筆 -1
    ㄉㄧㄢˋ 電 -1
    ㄧㄥˊ-ㄇㄨˋ 螢幕 -0.5
    ㄧㄥˊ 螢 -1
    ㄇㄨˋ 幕 -1
    """
    let grams = extractGrams(from: data)
    grams.forEach { handler.currentLM.insertTemporaryData(unigram: $0, isFiltering: false) }
    return { handler.currentLM.clearTemporaryData(isFiltering: false) }
  }
}
