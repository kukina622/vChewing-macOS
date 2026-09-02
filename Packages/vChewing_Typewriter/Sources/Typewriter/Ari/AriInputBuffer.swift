// (c) 2026 and onwards The vChewing Project (MIT-NTL License).
// ====================
// This code is released under the MIT license (SPDX-License-Identifier: MIT)
// ... with NTL restriction stating that:
// No trademark license is granted to use the trade names, trademarks, service
// marks, or product names of Contributor, except as required to fulfill notice
// requirements defined in MIT License.

import Foundation

/// Ari 模式專用的整段組字資料。
///
/// 這份資料刻意不以顯示字串作為唯一事實來源：中文 cell 同時保存正規讀音與實際
/// 敲入鍵序，才能支援中段編輯、重新選字及「原始鍵」還原。
public final class AriInputBuffer {
  // MARK: Lifecycle

  public init() {}

  // MARK: Public

  public struct Cell: Equatable {
    public init(
      text: String,
      reading: String? = nil,
      typedKeys: String = "",
      locked: Bool = false,
      selectionGroup: UUID? = nil,
      punctuationKey: String? = nil
    ) {
      self.text = text
      self.reading = reading
      self.typedKeys = typedKeys
      self.locked = locked
      self.selectionGroup = selectionGroup
      self.punctuationKey = punctuationKey
    }

    public var text: String
    public var reading: String?
    public var typedKeys: String
    public var locked: Bool
    public var selectionGroup: UUID?
    public var punctuationKey: String?

    public var isChinese: Bool { reading != nil }
  }

  public enum InteractionMode: Equatable {
    case normal
    case cursor
    case candidates(focus: Int)
  }

  public enum CandidateKind: Equatable {
    case chinese
    case rawKeys
    case punctuation
  }

  public struct Candidate: Equatable {
    public var keyArray: [String]
    public var value: String
    public var targetRange: Range<Int>
    public var kind: CandidateKind
  }

  public struct Snapshot: Equatable {
    public var cells: [Cell]
    public var cursor: Int
  }

  struct CandidateRevolverContext: Equatable {
    var base: Snapshot
    var rendered: Snapshot
    var candidates: [Candidate]
    var selectedIndex: Int
    var focus: Int
  }

  public var cells = [Cell]()
  /// Cell 邊界游標；0 是最左側，`cells.count` 是最右側。
  public var cursor = 0
  /// 尚未完成的實體注音鍵。其顯示位置永遠位於 `cursor`。
  public var pendingKeys = ""
  /// 目前位於英文字尾；聲調出現時可從尾端剝出合法注音音節。
  public var isInEnglishTail = false
  /// Ctrl+Space 切換，跨 composition reset 保留。
  public var forcedEnglish = false
  public var interactionMode: InteractionMode = .normal
  public var candidates = [Candidate]()
  public var undoStack = [Snapshot]()
  var candidateRevolverContext: CandidateRevolverContext?

  public var isEmpty: Bool { cells.isEmpty && pendingKeys.isEmpty }

  public var displaySegments: [String] {
    var result = cells.map(\.text)
    guard !pendingKeys.isEmpty else { return result }
    result.insert(pendingKeys, at: min(max(cursor, 0), result.count))
    return result
  }

  public var displayedText: String { displaySegments.joined() }

  public var displayCursor: Int {
    let left = cells.prefix(min(max(cursor, 0), cells.count)).map(\.text).joined().count
    return left + pendingKeys.count
  }

  public func clear(preservingForcedEnglish: Bool = true) {
    let preservedForcedEnglish = forcedEnglish
    cells.removeAll(keepingCapacity: true)
    cursor = 0
    pendingKeys.removeAll(keepingCapacity: true)
    isInEnglishTail = false
    interactionMode = .normal
    candidates.removeAll(keepingCapacity: true)
    undoStack.removeAll(keepingCapacity: true)
    candidateRevolverContext = nil
    forcedEnglish = preservingForcedEnglish ? preservedForcedEnglish : false
  }

  public func insertLiteral(_ text: String, punctuationKey: String? = nil) {
    guard !text.isEmpty else { return }
    clearCandidateContext()
    let inserted = text.map {
      Cell(text: String($0), typedKeys: String($0), punctuationKey: punctuationKey)
    }
    cells.insert(contentsOf: inserted, at: min(max(cursor, 0), cells.count))
    cursor += inserted.count
  }

  public func flushPendingAsLiteral() {
    guard !pendingKeys.isEmpty else { return }
    let pending = pendingKeys
    pendingKeys.removeAll(keepingCapacity: true)
    insertLiteral(pending)
  }

  public func deleteBackward() -> Bool {
    clearCandidateContext()
    if !pendingKeys.isEmpty {
      pendingKeys.removeLast()
      return true
    }
    guard cursor > 0, !cells.isEmpty else { return false }
    cells.remove(at: cursor - 1)
    cursor -= 1
    isInEnglishTail = contiguousLiteralTailBeforeCursor
    return true
  }

  public func deleteForward() -> Bool {
    clearCandidateContext()
    guard pendingKeys.isEmpty, cursor < cells.count else { return false }
    cells.remove(at: cursor)
    isInEnglishTail = contiguousLiteralTailBeforeCursor
    return true
  }

  public func pushUndoSnapshot() {
    undoStack.append(.init(cells: cells, cursor: cursor))
    if undoStack.count > 8 { undoStack.removeFirst(undoStack.count - 8) }
  }

  public func restoreCandidateSelection() -> Bool {
    guard let snapshot = undoStack.popLast() else { return false }
    cells = snapshot.cells
    cursor = min(max(snapshot.cursor, 0), cells.count)
    pendingKeys.removeAll(keepingCapacity: true)
    interactionMode = .cursor
    candidates.removeAll(keepingCapacity: true)
    candidateRevolverContext = nil
    isInEnglishTail = contiguousLiteralTailBeforeCursor
    return true
  }

  public func invalidateUndo() {
    undoStack.removeAll(keepingCapacity: true)
    candidateRevolverContext = nil
  }

  public func clearCandidateContext() {
    candidates.removeAll(keepingCapacity: true)
    candidateRevolverContext = nil
    if case .candidates = interactionMode { interactionMode = .cursor }
  }

  public var contiguousLiteralTailBeforeCursor: Bool {
    guard cursor > 0, cells.indices.contains(cursor - 1) else { return false }
    let cell = cells[cursor - 1]
    guard !cell.isChinese, cell.punctuationKey == nil else { return false }
    return cell.text.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
  }
}
