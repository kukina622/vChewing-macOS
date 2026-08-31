// (c) 2026 and onwards The vChewing Project (MIT-NTL License).
// ====================
// This code is released under the MIT license (SPDX-License-Identifier: MIT)
// ... with NTL restriction stating that:
// No trademark license is granted to use the trade names, trademarks, service
// marks, or product names of Contributor, except as required to fulfill notice
// requirements defined in MIT License.

import Foundation

extension InputHandlerProtocol {
  // MARK: - Public bridge

  /// Ari 模式的事件入口。啟用時由 `triageInput` 最前端呼叫，避免普通 FSM 先行提交內容。
  public func handleAriInput(event input: InputSignalProtocol) -> Bool {
    guard let session else { return false }
    guard currentTypingMethod == .vChewingFactory, !prefs.cassetteEnabled,
          !composer.isPinyinMode else { return false }

    let punctuationShortcut = ariChinesePunctuationShortcutValue(for: input)
    if punctuationShortcut != nil, case let .candidates(focus) = ariBuffer.interactionMode {
      // 中文標點屬於文字輸入；選字窗開啟時先回到目前 cell 後方再重走一般輸入，
      // 不可把 Control 事件放給宿主，否則 marked text 會消失且符號會落在組字區前方。
      ariBuffer.candidates.removeAll(keepingCapacity: true)
      ariBuffer.interactionMode = .cursor
      ariBuffer.cursor = min(focus + 1, ariBuffer.cells.count)
    }

    if case .candidates = ariBuffer.interactionMode {
      return handleAriCandidateInput(input, session: session)
    }

    // Ctrl+Space：強制英文模式。既有 pre-edit 保留，不做 commit。
    if input.isControlHeld, !input.isOptionHeld, !input.isCommandHeld, input.isSpace {
      ariBuffer.flushPendingAsLiteral()
      ariBuffer.forcedEnglish.toggle()
      ariBuffer.isInEnglishTail = ariBuffer.forcedEnglish
      var state = generateAriInputtingState()
      state.tooltip = ariBuffer.forcedEnglish ? "英 English" : "中 中文"
      state.tooltipDuration = 1.2
      session.switchState(state)
      return true
    }

    // Ari 的 Ctrl+Z 僅復原候選選取；沒有 Ari snapshot 時必須交還應用程式。
    if input.isControlHeld, !input.isOptionHeld, !input.isCommandHeld,
       input.text.lowercased() == "z" {
      guard ariBuffer.restoreCandidateSelection() else { return false }
      var state = generateAriInputtingState()
      state.tooltip = "i18n:AriIME.CandidateSelectionRestored".i18n
      state.tooltipDuration = 1.2
      session.switchState(state)
      return true
    }

    // 剪貼簿內容以完成的 literal cells 插入，不再交給注音解析器。
    let isStandardPaste = (input.isControlHeld != input.isCommandHeld)
      && !input.isOptionHeld && input.text.lowercased() == "v"
    let isInsertPaste = input.isShiftHeld && !input.isControlHeld
      && !input.isOptionHeld && !input.isCommandHeld
      && KeyCode(rawValue: input.keyCode) == .kHelp
    if isStandardPaste || isInsertPaste,
       let pasted = ariPasteboardProvider?(), !pasted.isEmpty {
      let sanitized = sanitizeAriPaste(pasted)
      guard !sanitized.isEmpty else { return false }
      ariBuffer.flushPendingAsLiteral()
      ariBuffer.invalidateUndo()
      ariBuffer.insertLiteral(sanitized)
      ariBuffer.isInEnglishTail = false
      session.switchState(generateAriInputtingState())
      return true
    }

    // 未定義的 Ctrl / Option / Command 快捷鍵交還 client；Alt+[ / Alt+] 除外。
    if input.isOptionHeld, !input.isControlHeld, !input.isCommandHeld,
       !input.isShiftHeld, let base = input.inputTextIgnoringModifiers,
       ["[", "]"].contains(base) {
      ariBuffer.flushPendingAsLiteral()
      ariBuffer.invalidateUndo()
      ariBuffer.insertLiteral(base == "[" ? "「" : "」", punctuationKey: base)
      ariBuffer.isInEnglishTail = false
      session.switchState(generateAriInputtingState())
      return true
    }

    // 中文標點手勢必須在一般 modifier pass-through 之前處理。按住 Control 時，
    // macOS 的 characters 可能是控制字元，故由 charactersIgnoringModifiers 回復實體標點。
    if let visible = punctuationShortcut {
      let baseKey = ariPhysicalPunctuationKey(
        visible: visible, ignoringModifiers: input.inputTextIgnoringModifiers
      )
      ariBuffer.flushPendingAsLiteral()
      ariBuffer.invalidateUndo()
      ariBuffer.insertLiteral(
        ariChinesePunctuation(for: visible, isShortcut: true), punctuationKey: baseKey
      )
      ariBuffer.isInEnglishTail = false
      session.switchState(generateAriInputtingState())
      return true
    }
    if input.isHoldingAny([.control, .option, .command]) { return false }

    if input.isEnter {
      guard !ariBuffer.isEmpty else { return false }
      ariBuffer.flushPendingAsLiteral()
      memorizeAriCompositionIfNeeded()
      session.switchState(State.ofCommitting(textToCommit: ariBuffer.displayedText))
      return true
    }
    if input.isEsc {
      guard !ariBuffer.isEmpty else { return false }
      session.switchState(State.ofAbortion())
      return true
    }
    if input.isBackSpace {
      guard !ariBuffer.isEmpty else { return false }
      ariBuffer.invalidateUndo()
      _ = ariBuffer.deleteBackward()
      switchAriStateAfterEditing(session)
      return true
    }
    if input.isDelete {
      guard !ariBuffer.isEmpty else { return false }
      ariBuffer.flushPendingAsLiteral()
      ariBuffer.invalidateUndo()
      _ = ariBuffer.deleteForward() // 尾端仍吸收 Delete，不刪 client 文字。
      switchAriStateAfterEditing(session)
      return true
    }
    if input.isHome || input.isEnd || input.isLeft || input.isRight {
      guard !ariBuffer.isEmpty else { return false }
      ariBuffer.flushPendingAsLiteral()
      ariBuffer.interactionMode = .cursor
      switch (input.isHome, input.isEnd, input.isLeft, input.isRight) {
      case (true, _, _, _): ariBuffer.cursor = 0
      case (_, true, _, _): ariBuffer.cursor = ariBuffer.cells.count
      case (_, _, true, _): ariBuffer.cursor = max(0, ariBuffer.cursor - 1)
      case (_, _, _, true): ariBuffer.cursor = min(ariBuffer.cells.count, ariBuffer.cursor + 1)
      default: break
      }
      ariBuffer.isInEnglishTail = ariBuffer.contiguousLiteralTailBeforeCursor
      session.switchState(generateAriInputtingState())
      return true
    }
    if input.isUp || input.isDown {
      guard !ariBuffer.isEmpty else { return false }
      ariBuffer.flushPendingAsLiteral()
      if ariBuffer.forcedEnglish {
        ariBuffer.interactionMode = .cursor
        session.switchState(generateAriInputtingState())
        return true
      }
      let focus = min(max(ariBuffer.cursor == ariBuffer.cells.count ? ariBuffer.cursor - 1 : ariBuffer.cursor, 0),
                      max(ariBuffer.cells.count - 1, 0))
      guard openAriCandidates(at: focus) else {
        ariBuffer.interactionMode = .cursor
        session.switchState(generateAriInputtingState())
        return true
      }
      session.switchState(generateAriCandidateState())
      return true
    }

    if input.isSpace {
      return handleAriSpace(session: session)
    }

    // 數字鍵盤在 Ari 中永遠是 literal；其餘只接可列印 ASCII。
    let visible = input.text.applyingTransformFW2HW(reverse: false)
    guard visible.count == 1,
          visible.unicodeScalars.allSatisfy({ $0.isASCII && (0x21 ... 0x7E).contains($0.value) })
    else { return false }

    ariBuffer.invalidateUndo()
    if input.isNumericPadKey || ariBuffer.forcedEnglish {
      ariBuffer.flushPendingAsLiteral()
      ariBuffer.insertLiteral(visible)
      ariBuffer.isInEnglishTail = true
      session.switchState(generateAriInputtingState())
      return true
    }

    let phoneticKey = (input.inputTextIgnoringModifiers ?? visible).lowercased()
      .applyingTransformFW2HW(reverse: false)
    let isPhoneticKey = composer.inputValidityCheck(charStr: phoneticKey)
    let isPunctuation = visible.unicodeScalars.allSatisfy {
      CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0)
    }

    if isPunctuation, !isPhoneticKey {
      ariBuffer.flushPendingAsLiteral()
      let baseKey = ariPhysicalPunctuationKey(
        visible: visible, ignoringModifiers: input.inputTextIgnoringModifiers
      )
      let punctuation = prefs.ariFullWidthPunctuationEnabled
        ? ariChinesePunctuation(for: visible) : visible
      ariBuffer.insertLiteral(punctuation, punctuationKey: baseKey)
      ariBuffer.isInEnglishTail = false
      session.switchState(generateAriInputtingState())
      return true
    }

    if ariBuffer.isInEnglishTail {
      ariBuffer.insertLiteral(visible)
      if isPhoneticKey { _ = convertAriLiteralTailIfPossible() }
      session.switchState(generateAriInputtingState())
      return true
    }

    if isPhoneticKey {
      if appendAriPendingKey(visible: visible, parserKey: phoneticKey) {
        session.switchState(generateAriInputtingState())
        return true
      }
      // slot 衝突：整段（包含新鍵）回退為英文，不吞鍵。
      let fallback = ariBuffer.pendingKeys + visible
      ariBuffer.pendingKeys.removeAll(keepingCapacity: true)
      ariBuffer.insertLiteral(fallback)
      ariBuffer.isInEnglishTail = true
      session.switchState(generateAriInputtingState())
      return true
    }

    ariBuffer.flushPendingAsLiteral()
    ariBuffer.insertLiteral(visible)
    ariBuffer.isInEnglishTail = true
    session.switchState(generateAriInputtingState())
    return true
  }

  /// 滑鼠、觸控及鍵盤選字共用的 Ari 選取入口。
  public func confirmAriCandidate(at index: Int) -> Bool {
    guard let session, ariBuffer.candidates.indices.contains(index) else { return false }
    let candidate = ariBuffer.candidates[index]
    guard candidate.targetRange.lowerBound >= 0,
          candidate.targetRange.upperBound <= ariBuffer.cells.count else { return false }
    if candidate.kind == .chinese,
       case let .candidates(focus) = ariBuffer.interactionMode,
       !ariCandidateCanReplace(candidate.targetRange, focus: focus) {
      return false
    }
    ariBuffer.pushUndoSnapshot()
    let oldCells = Array(ariBuffer.cells[candidate.targetRange])
    switch candidate.kind {
    case .rawKeys:
      let raw = oldCells.map(\.typedKeys).joined()
      let cells = raw.map { AriInputBuffer.Cell(text: String($0), typedKeys: String($0)) }
      ariBuffer.cells.replaceSubrange(candidate.targetRange, with: cells)
      ariBuffer.cursor = candidate.targetRange.lowerBound + cells.count
    case .chinese:
      let values = candidate.value.map(String.init)
      guard values.count == candidate.keyArray.count else { return false }
      let group = UUID()
      let typedKeys = oldCells.map(\.typedKeys)
      let replacement = values.enumerated().map { offset, value in
        AriInputBuffer.Cell(
          text: value,
          reading: candidate.keyArray[offset],
          typedKeys: typedKeys.indices.contains(offset) ? typedKeys[offset] : "",
          locked: true,
          selectionGroup: group
        )
      }
      ariBuffer.cells.replaceSubrange(candidate.targetRange, with: replacement)
      ariBuffer.cursor = candidate.targetRange.lowerBound + replacement.count
    case .punctuation:
      let baseKey = oldCells.first?.punctuationKey
      let replacement = candidate.value.map {
        AriInputBuffer.Cell(text: String($0), typedKeys: String($0), locked: true, punctuationKey: baseKey)
      }
      ariBuffer.cells.replaceSubrange(candidate.targetRange, with: replacement)
      ariBuffer.cursor = candidate.targetRange.lowerBound + replacement.count
    }
    ariBuffer.candidates.removeAll(keepingCapacity: true)
    ariBuffer.interactionMode = .cursor
    ariBuffer.isInEnglishTail = ariBuffer.contiguousLiteralTailBeforeCursor
    session.switchState(generateAriInputtingState())
    return true
  }

  public func generateAriInputtingState() -> State {
    guard !ariBuffer.isEmpty else { return .ofAbortion() }
    var state = State.ofInputting(
      displayTextSegments: ariBuffer.displaySegments,
      cursor: ariBuffer.displayCursor
    )
    let status = ariBuffer.forcedEnglish ? "英" : "中"
    if prefs.ariShowStatusLineEnabled {
      let punctuation = prefs.ariFullWidthPunctuationEnabled ? "全形標點" : "半形標點"
      state.tooltip = "\(status) · \(currentKeyboardParserType.localizedMenuName) · \(punctuation)"
      state.tooltipDuration = 0
    } else if prefs.ariShowPendingZhuyinEnabled, !ariBuffer.pendingKeys.isEmpty {
      state.tooltip = ariPendingZhuyinDisplay
      state.tooltipDuration = 0
    }
    return state
  }

  // MARK: - Composition

  private func appendAriPendingKey(visible: String, parserKey _: String) -> Bool {
    let proposed = ariBuffer.pendingKeys + visible
    guard let trial = ariComposer(for: proposed) else { return false }
    let occupied = ariOccupiedSlotCount(trial)
    // 靜態一鍵一符配置可用此條件偵測 destructive overwrite；動態 26 鍵配置交由
    // composer 自己判定，避免多擊映射被錯誤回退。
    if ![.ofDachen26, .ofETen26, .ofHsu, .ofStarlight, .ofAlvinLiu].contains(trial.parser),
       occupied != proposed.count { return false }
    ariBuffer.pendingKeys = proposed
    if trial.hasIntonation(), trial.isPronounceable,
       let reading = trial.phonabetKeyForQuery(pronounceableOnly: true),
       !ariChineseGrams(for: reading).isEmpty {
      let typed = visible == " " ? String(proposed.dropLast()) : proposed
      ariBuffer.pendingKeys.removeAll(keepingCapacity: true)
      insertAriChinese(reading: reading, typedKeys: typed)
    }
    return true
  }

  private func handleAriSpace(session: Session) -> Bool {
    if !ariBuffer.pendingKeys.isEmpty {
      if appendAriPendingKey(visible: " ", parserKey: " ") {
        if !ariBuffer.pendingKeys.isEmpty {
          ariBuffer.flushPendingAsLiteral()
          ariBuffer.isInEnglishTail = false
        }
        session.switchState(generateAriInputtingState())
        return true
      }
      ariBuffer.flushPendingAsLiteral()
      ariBuffer.insertLiteral(" ")
      ariBuffer.isInEnglishTail = false
      session.switchState(generateAriInputtingState())
      return true
    }
    if prefs.ariSpaceCandidateModeEnabled, ariBuffer.cursor > 0,
       ariBuffer.cells[ariBuffer.cursor - 1].isChinese,
       openAriCandidates(at: ariBuffer.cursor - 1) {
      session.switchState(generateAriCandidateState())
      return true
    }
    ariBuffer.insertLiteral(" ")
    ariBuffer.isInEnglishTail = false
    session.switchState(generateAriInputtingState())
    return true
  }

  private func insertAriChinese(reading: String, typedKeys: String) {
    let grams = ariChineseGrams(for: reading)
    guard let value = grams.first?.current, let first = value.first else {
      ariBuffer.insertLiteral(typedKeys)
      ariBuffer.isInEnglishTail = true
      return
    }
    let cell = AriInputBuffer.Cell(text: String(first), reading: reading, typedKeys: typedKeys)
    ariBuffer.cells.insert(cell, at: min(max(ariBuffer.cursor, 0), ariBuffer.cells.count))
    ariBuffer.cursor += 1
    ariBuffer.isInEnglishTail = false
    reassembleAriChineseRun(containing: ariBuffer.cursor - 1)
  }

  private func convertAriLiteralTailIfPossible() -> Bool {
    let runStart = ariLiteralRunStart(before: ariBuffer.cursor)
    guard runStart < ariBuffer.cursor else { return false }
    let literalRun = ariBuffer.cells[runStart ..< ariBuffer.cursor].map(\.text).joined()
    // URL、email、檔名與路徑尾端偏向字面值。
    let literalBoundaryIsTechnical = runStart > 0
      && ["@", "/", "\\", "."].contains(ariBuffer.cells[runStart - 1].text)
    if literalBoundaryIsTechnical || literalRun.contains("://") || literalRun.contains("@")
      || literalRun.range(of: #"(?:^|[/\\])[^ ]+\.[A-Za-z0-9]+$"#, options: .regularExpression) != nil {
      return false
    }
    let maxLength = min(5, ariBuffer.cursor - runStart)
    guard maxLength >= 2 else { return false }
    for length in 2 ... maxLength {
      let lower = ariBuffer.cursor - length
      let suffix = ariBuffer.cells[lower ..< ariBuffer.cursor].map(\.text).joined()
      guard let trial = ariComposer(for: suffix), trial.hasIntonation(), trial.isPronounceable,
            let reading = trial.phonabetKeyForQuery(pronounceableOnly: true),
            !ariChineseGrams(for: reading).isEmpty else { continue }
      if ariIsAmbiguousSingleMedialSuffix(suffix, composer: trial) {
        let literalPrefix = ariBuffer.cells[runStart ..< lower].map(\.text).joined()
        guard ariAllowsSingleMedialSuffix(after: literalPrefix) else { continue }
      }
      let typed = suffix.last == " " ? String(suffix.dropLast()) : suffix
      ariBuffer.cells.removeSubrange(lower ..< ariBuffer.cursor)
      ariBuffer.cursor = lower
      insertAriChinese(reading: reading, typedKeys: typed)
      return true
    }
    return false
  }

  private func reassembleAriChineseRun(containing index: Int) {
    guard ariBuffer.cells.indices.contains(index), ariBuffer.cells[index].isChinese else { return }
    let range = ariChineseRun(containing: index)
    let readings = ariBuffer.cells[range].compactMap(\.reading)
    guard readings.count == range.count, let trial = ariAssembler(readings: readings) else { return }
    var offset = range.lowerBound
    for gram in trial.assembledSentence {
      let values = gram.value.map(String.init)
      guard values.count == gram.keyArray.count else {
        offset += gram.keyArray.count
        continue
      }
      for value in values where ariBuffer.cells.indices.contains(offset) {
        if !ariBuffer.cells[offset].locked { ariBuffer.cells[offset].text = value }
        offset += 1
      }
    }
  }

  // MARK: - Candidates

  private func openAriCandidates(at focus: Int) -> Bool {
    guard ariBuffer.cells.indices.contains(focus) else { return false }
    let cell = ariBuffer.cells[focus]
    var result = [AriInputBuffer.Candidate]()
    if cell.isChinese {
      let run = ariChineseRun(containing: focus)
      let readings = ariBuffer.cells[run].compactMap(\.reading)
      if let trial = ariAssembler(readings: readings) {
        let relativeFocus = focus - run.lowerBound
        let fetched = trial.fetchCandidates(at: relativeFocus).map(\.pair)
        var seen = Set<String>()
        for pair in fetched {
          guard let localRange = ariCandidateRange(
            for: pair.keyArray, focus: relativeFocus, readings: readings
          ) else { continue }
          let target = (run.lowerBound + localRange.lowerBound) ..< (run.lowerBound + localRange.upperBound)
          guard ariCandidateCanReplace(target, focus: focus) else { continue }
          guard seen.insert("\(target.lowerBound):\(target.upperBound):\(pair.value)").inserted else { continue }
          result.append(.init(keyArray: pair.keyArray, value: pair.value, targetRange: target, kind: .chinese))
        }
      }
      let current = AriInputBuffer.Candidate(
        keyArray: [cell.reading ?? ""], value: cell.text,
        targetRange: focus ..< focus + 1, kind: .chinese
      )
      if let existing = result.firstIndex(where: { $0.value == current.value && $0.targetRange == current.targetRange }) {
        let item = result.remove(at: existing)
        result.insert(item, at: 0)
      } else {
        result.insert(current, at: 0)
      }
      result.insert(.init(
        keyArray: [cell.reading ?? ""],
        value: "原始鍵 \(cell.typedKeys)",
        targetRange: focus ..< focus + 1,
        kind: .rawKeys
      ), at: ariRawKeyCandidateInsertionIndex(in: result))
    } else if let punctuationKey = cell.punctuationKey {
      let family = ariPunctuationFamily(for: punctuationKey)
      for value in ([cell.text] + family).deduplicated {
        result.append(.init(
          keyArray: ["_ari_punctuation_\(punctuationKey)"], value: value,
          targetRange: focus ..< focus + 1, kind: .punctuation
        ))
      }
    }
    guard !result.isEmpty else { return false }
    ariBuffer.candidates = result
    ariBuffer.interactionMode = .candidates(focus: focus)
    return true
  }

  private func handleAriCandidateInput(_ input: InputSignalProtocol, session: Session) -> Bool {
    guard case let .candidates(focus) = ariBuffer.interactionMode else { return false }
    guard let controller = session.candidateController() else { return false }
    if input.isEsc {
      ariBuffer.candidates.removeAll(keepingCapacity: true)
      ariBuffer.interactionMode = .cursor
      session.switchState(generateAriInputtingState())
      return true
    }
    if input.isEnter {
      return confirmAriCandidate(at: controller.highlightedIndex)
    }
    if input.isShiftHeld, input.isDelete,
       ariBuffer.candidates.indices.contains(controller.highlightedIndex) {
      let candidate = ariBuffer.candidates[controller.highlightedIndex]
      if candidate.kind == .chinese {
        currentLM.bleachSpecifiedPOMSuggestions(targets: [candidate.value], saveCallback: pomSaveCallback)
        var state = generateAriCandidateState()
        state.tooltip = "i18n:AriIME.CandidateForgotten".i18n
        state.tooltipDuration = 1.2
        session.switchState(state)
      }
      return true
    }
    if input.isBackSpace || input.isDelete {
      ariBuffer.candidates.removeAll(keepingCapacity: true)
      ariBuffer.interactionMode = .cursor
      ariBuffer.cursor = input.isBackSpace ? min(focus + 1, ariBuffer.cells.count) : focus
      if input.isBackSpace { _ = ariBuffer.deleteBackward() } else { _ = ariBuffer.deleteForward() }
      switchAriStateAfterEditing(session)
      return true
    }
    if input.isTab || input.isSpace || input.isDown {
      _ = input.isShiftHeld ? controller.highlightPreviousCandidate() : controller.highlightNextCandidate()
      return true
    }
    if input.isUp {
      _ = controller.highlightPreviousCandidate()
      return true
    }
    if input.isPageDown { _ = controller.showNextPage(); return true }
    if input.isPageUp { _ = controller.showPreviousPage(); return true }
    // 唯音既有操作：候選窗尚未展開時，右方向鍵先展開候選框。
    // 展開後再按右鍵，才依 Ari 規則移到相鄰 cell。
    if input.isRight, !controller.expanded {
      _ = controller.showNextLine()
      return true
    }
    if input.isHome || input.isEnd || input.isLeft || input.isRight {
      var newFocus = focus
      if input.isHome { newFocus = 0 }
      if input.isEnd { newFocus = max(ariBuffer.cells.count - 1, 0) }
      if input.isLeft { newFocus = max(focus - 1, 0) }
      if input.isRight {
        if focus >= ariBuffer.cells.count - 1 {
          ariBuffer.candidates.removeAll(keepingCapacity: true)
          ariBuffer.cursor = ariBuffer.cells.count
          ariBuffer.interactionMode = .cursor
          session.switchState(generateAriInputtingState())
          return true
        }
        newFocus = focus + 1
      }
      ariBuffer.cursor = newFocus
      if openAriCandidates(at: newFocus) {
        session.switchState(generateAriCandidateState())
      } else {
        ariBuffer.interactionMode = .cursor
        session.switchState(generateAriInputtingState())
      }
      return true
    }
    let matched = input.text.lowercased()
    if let keyIndex = session.selectionKeys.lowercased().firstIndex(of: matched.first ?? "\0") {
      let relative = session.selectionKeys.distance(from: session.selectionKeys.startIndex, to: keyIndex)
      if let absolute = controller.candidateIndexAtKeyLabelIndex(relative) {
        return confirmAriCandidate(at: absolute)
      }
    }
    if !input.isHoldingAny([.control, .option, .command]), input.text.count == 1,
       input.text.unicodeScalars.allSatisfy({ $0.isASCII && (0x20 ... 0x7E).contains($0.value) }) {
      ariBuffer.candidates.removeAll(keepingCapacity: true)
      ariBuffer.interactionMode = .cursor
      ariBuffer.cursor = focus
      return handleAriInput(event: input)
    }
    // 未支援控制鍵：關窗、保留游標，交還 client。
    ariBuffer.candidates.removeAll(keepingCapacity: true)
    ariBuffer.interactionMode = .cursor
    ariBuffer.cursor = focus
    session.switchState(generateAriInputtingState())
    return false
  }

  private func generateAriCandidateState() -> State {
    let pairs = ariBuffer.candidates.map { (keyArray: $0.keyArray, value: $0.value) }
    return State.ofCandidates(
      candidates: pairs,
      displayTextSegments: ariBuffer.displaySegments,
      cursor: ariBuffer.displayCursor
    )
  }

  // MARK: - Helpers

  private func ariComposer(for typedKeys: String) -> Tekkon.Composer? {
    guard !typedKeys.isEmpty else { return nil }
    let normalized = typedKeys.lowercased()
    guard normalized.allSatisfy({ composer.inputValidityCheck(charStr: String($0)) }) else { return nil }
    var trial = composer
    trial.clear()
    trial.phonabetCombinationCorrectionEnabled = false
    trial.receiveSequence(normalized, isRomaji: false)
    return trial
  }

  private func ariOccupiedSlotCount(_ composer: Tekkon.Composer) -> Int {
    [composer.consonant.value, composer.semivowel.value, composer.vowel.value, composer.intonation.value]
      .filter { !$0.isEmpty }.count
  }

  private func ariChineseGrams(for reading: String) -> [Homa.Gram] {
    currentLM.unigramsFor(keyArray: [reading]).filter { gram in
      gram.current.contains { character in
        character.unicodeScalars.contains { scalar in
          switch scalar.value {
          case 0x3400 ... 0x9FFF, 0xF900 ... 0xFAFF, 0x20000 ... 0x323AF: true
          default: false
          }
        }
      }
    }
  }

  private func ariAssembler(readings: [String]) -> Homa.Assembler? {
    guard !readings.isEmpty else { return nil }
    let lm = currentLM
    let result = Homa.Assembler(
      gramQuerier: { lm.lookupHub.grams(for: $0) },
      gramAvailabilityChecker: { lm.lookupHub.hasGrams(for: $0) }
    )
    result.maxSegLength = prefs.maxCandidateLength
    guard (try? result.insertKeys(readings.map { Homa.PossibleKey.singleKey($0) })) != nil else { return nil }
    return result
  }

  /// Ari 只在 Enter 接受整段時寫入學習資料。候選確認只留下 locked / selectionGroup，
  /// 因此之後若使用者刪除、復原或 Esc，中途的選字不會污染個人模型。
  private func memorizeAriCompositionIfNeeded() {
    guard prefs.ariAutoLearnEnabled, ariSensitiveInputChecker?() != true else { return }
    let timestamp = Date().timeIntervalSince1970
    var runStart = 0
    while runStart < ariBuffer.cells.count {
      guard ariBuffer.cells[runStart].isChinese else {
        runStart += 1
        continue
      }
      var runEnd = runStart + 1
      while runEnd < ariBuffer.cells.count, ariBuffer.cells[runEnd].isChinese {
        runEnd += 1
      }
      let run = runStart ..< runEnd
      let readings = ariBuffer.cells[run].compactMap(\.reading)
      guard readings.count == run.count, let trial = ariAssembler(readings: readings) else {
        runStart = runEnd
        continue
      }

      var explicitObservations = [Homa.PerceptionIntel]()
      var handledGroups = Set<UUID>()
      for cellIndex in run {
        guard let group = ariBuffer.cells[cellIndex].selectionGroup,
              handledGroups.insert(group).inserted else { continue }
        let groupIndices = run.filter { ariBuffer.cells[$0].selectionGroup == group }
        guard let first = groupIndices.first, let last = groupIndices.last,
              groupIndices.count == last - first + 1 else { continue }
        let keyArray = groupIndices.compactMap { ariBuffer.cells[$0].reading }
        let value = groupIndices.map { ariBuffer.cells[$0].text }.joined()
        guard keyArray.count == groupIndices.count, value.count == keyArray.count else { continue }
        let localCursor = first - run.lowerBound
        let prior = trial.assembledSentence
        var observation: Homa.PerceptionIntel?
        try? trial.overrideCandidate(
          .init(keyArray: keyArray, value: value),
          at: localCursor,
          type: .withSpecified,
          isExplicitlyOverridden: true,
          enforceRetokenization: true,
          perceptionHandler: { observation = $0 }
        )
        if let adjusted = Homa.makePerceptionIntel(
          previouslyAssembled: prior,
          currentAssembled: trial.assembledSentence,
          cursor: localCursor
        ) {
          observation = adjusted
        }
        if let observation, observation.scoreFromLM > -12 {
          explicitObservations.append(observation)
        }
      }

      // 每個已接受的中文 run 一次弱學習；明確選字再追加三次。
      if let accepted = trial.assembledSentence.generateKeyForPerception() {
        currentLM.memorizePerception(
          (accepted.ngramKey, accepted.candidate), timestamp: timestamp,
          saveCallback: pomSaveCallback
        )
      }
      for observation in explicitObservations {
        for _ in 0 ..< 3 {
          currentLM.memorizePerception(
            (observation.contextualizedGramKey, observation.candidate),
            timestamp: timestamp,
            saveCallback: pomSaveCallback
          )
        }
      }
      runStart = runEnd
    }
  }

  private func ariChineseRun(containing index: Int) -> Range<Int> {
    var lower = index
    var upper = index + 1
    while lower > 0, ariBuffer.cells[lower - 1].isChinese { lower -= 1 }
    while upper < ariBuffer.cells.count, ariBuffer.cells[upper].isChinese { upper += 1 }
    return lower ..< upper
  }

  /// 未鎖定位置不得選取會跨越既有 selection group 的候選；重新聚焦於該 group
  /// 本身時則允許改選，避免 locked 變成永遠無法修改。
  private func ariCandidateCanReplace(_ range: Range<Int>, focus: Int) -> Bool {
    let lockedCells = range.filter { ariBuffer.cells[$0].locked }
    guard !lockedCells.isEmpty else { return true }
    guard ariBuffer.cells.indices.contains(focus),
          let focusedGroup = ariBuffer.cells[focus].selectionGroup else { return false }
    return lockedCells.allSatisfy { ariBuffer.cells[$0].selectionGroup == focusedGroup }
  }

  /// 原始鍵緊接在最後一個詞候選之後；若沒有詞候選，則放在目前顯示候選之後。
  /// 這可保留目前顯示文字置頂，同時避免使用者必須翻到所有單字候選的末端。
  private func ariRawKeyCandidateInsertionIndex(
    in candidates: [AriInputBuffer.Candidate]
  ) -> Int {
    if let lastPhrase = candidates.lastIndex(where: { $0.targetRange.count > 1 }) {
      return lastPhrase + 1
    }
    return min(1, candidates.count)
  }

  private func ariIsAmbiguousSingleMedialSuffix(
    _ suffix: String,
    composer trial: Tekkon.Composer
  ) -> Bool {
    suffix.count == 2
      && trial.consonant.value.isEmpty
      && !trial.semivowel.value.isEmpty
      && trial.vowel.value.isEmpty
  }

  /// 單一介音鍵只有在英文切割邊界足夠明確時才採最短 suffix；否則繼續擴張，
  /// 讓 `acer1u3` 優先嘗試完整的 `1u3`，而不是留下疑似聲母的 `1`。
  private func ariAllowsSingleMedialSuffix(after literalPrefix: String) -> Bool {
    let boundary = literalPrefix.unicodeScalars.suffix(2)
    return boundary.count == 2 && boundary.allSatisfy { (0x61 ... 0x7A).contains($0.value) }
  }

  private func ariLiteralRunStart(before cursor: Int) -> Int {
    var lower = cursor
    while lower > 0 {
      let cell = ariBuffer.cells[lower - 1]
      guard !cell.isChinese, cell.punctuationKey == nil,
            cell.text.unicodeScalars.allSatisfy({ $0.isASCII }) else { break }
      lower -= 1
    }
    return lower
  }

  private func ariCandidateRange(
    for keys: [String], focus: Int, readings: [String]
  ) -> Range<Int>? {
    guard !keys.isEmpty, keys.count <= readings.count else { return nil }
    for lower in 0 ... readings.count - keys.count {
      let range = lower ..< lower + keys.count
      guard range.contains(focus) else { continue }
      if Array(readings[range]) == keys { return range }
    }
    return nil
  }

  private var ariPendingZhuyinDisplay: String {
    guard let trial = ariComposer(for: ariBuffer.pendingKeys) else { return "" }
    return trial.getComposition()
  }

  private func switchAriStateAfterEditing(_ session: Session) {
    if ariBuffer.isEmpty { session.switchState(.ofAbortion()) }
    else { session.switchState(generateAriInputtingState()) }
  }

  private func sanitizeAriPaste(_ input: String) -> String {
    var result = ""
    var pendingSeparator = false
    for character in input {
      let scalars = character.unicodeScalars
      if scalars.allSatisfy({ [0x200B, 0x2060, 0xFEFF].contains($0.value) }) { continue }
      let isSeparator = scalars.contains {
        $0.value < 0x20 || $0.value == 0x7F || (0x80 ... 0x9F).contains($0.value)
          || [0x00A0, 0x2028, 0x2029, 0x202F, 0x3000].contains($0.value)
      }
      if isSeparator { pendingSeparator = true; continue }
      if pendingSeparator, !result.isEmpty { result.append(" ") }
      pendingSeparator = false
      result.append(character)
    }
    return result
  }

  private func ariChinesePunctuation(for value: String, isShortcut: Bool = false) -> String {
    if isShortcut, ["'", "\""].contains(value) { return "、" }
    let map: [String: String] = [
      ",": "，", "<": "，", ".": "。", ">": "。", "/": "？", "?": "？",
      "'": "、", "\"": "＂", "(": "（", ")": "）", "[": "「", "]": "」",
      "{": "『", "}": "』", "!": "！", ":": "：", "\\": "、", "^": "……",
      "@": "＠", "#": "＃", "$": "＄", "%": "％", "&": "＆", "*": "＊",
      "+": "＋", "=": "＝", "|": "｜", "~": "～", "_": "＿", "`": "｀",
      ";": "；", "-": "－",
    ]
    return map[value] ?? value.applyingTransformFW2HW(reverse: true)
  }

  private func ariChinesePunctuationShortcutValue(
    for input: InputSignalProtocol
  ) -> String? {
    guard input.isControlHeld, !input.isOptionHeld, !input.isCommandHeld else { return nil }
    let values = [input.text, input.inputTextIgnoringModifiers ?? ""]
    return values.lazy
      .map { $0.applyingTransformFW2HW(reverse: false) }
      .first {
        $0.count == 1 && $0.unicodeScalars.allSatisfy {
          CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0)
        }
      }
  }

  /// 候選家族以未按 Shift 的實體鍵為索引；括號與驚嘆號等沒有標點 base 的按鍵
  /// 仍保留顯示符號，避免把數字混入標點候選。
  private func ariPhysicalPunctuationKey(
    visible: String, ignoringModifiers: String?
  ) -> String {
    let physicalPairs: [String: String] = [
      "{": "[", "}": "]", "<": ",", ">": ".", "?": "/", "\"": "'", ":": ";",
    ]
    if let mapped = physicalPairs[visible] { return mapped }
    guard let base = ignoringModifiers?.applyingTransformFW2HW(reverse: false),
          base.count == 1,
          base.unicodeScalars.allSatisfy({
            CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0)
          }) else { return visible }
    return base
  }

  private func ariPunctuationFamily(for key: String) -> [String] {
    let families: [String: [String]] = [
      "[": ["[", "{", "「", "『", "【", "〔", "《", "〈"],
      "]": ["]", "}", "」", "』", "】", "〕", "》", "〉"],
      ",": [",", "<", "，", "《", "〈"],
      ".": [".", ">", "。", "．"],
      "/": ["/", "?", "？", "／"],
      "'": ["'", "\"", "、", "＇", "＂"],
      "(": ["(", "（"], ")": [")", "）"],
      "!": ["!", "！"], ";": [";", ":", "；", "："],
    ]
    return families[key] ?? [key, ariChinesePunctuation(for: key)]
  }
}
