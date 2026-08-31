// (c) 2021 and onwards The vChewing Project (MIT-NTL License).
// ====================
// This code is released under the MIT license (SPDX-License-Identifier: MIT)
// ... with NTL restriction stating that:
// No trademark license is granted to use the trade names, trademarks, service
// marks, or product names of Contributor, except as required to fulfill notice
// requirements defined in MIT License.

import Foundation

// MARK: - CtlCandidateDelegate

public protocol CtlCandidateDelegate: AnyObject {
  func candidateController() -> CtlCandidateProtocol?
  func candidatePairs(conv: Bool) -> [CandidateInState]
  func callError(_: String)
  func getCandidate(at: Int) -> CandidateInState?
  func candidatePairSelectionConfirmed(at index: Int)
  func candidatePairSelectionConfirmed(at index: Int, expectedCandidate: CandidateInState?)
  func candidatePairHighlightChanged(at index: Int?)
  func candidatePairContextMenuActionTriggered(
    at index: Int, action: CandidateContextMenuAction
  )
  func candidatePairManipulated(at index: Int, action: CandidateContextMenuAction)
  func candidateToolTip(shortened: Bool) -> String
  func resetCandidateWindowOrigin()
  func candidateWindowOriginInfo() -> (topLeft: CGPoint, heightDelta: Double)
  func checkIsMacroTokenResult(_ index: Int) -> Bool
  @discardableResult
  func reverseLookup(for value: String) -> [String]
  var selectionKeys: String { get }
  var isVerticalTyping: Bool { get }
  var isCandidateState: Bool { get }
  var isVerticalCandidateWindow: Bool { get }
  var localeForFontFallbacks: String { get }
  var isCandidateWindowSingleLine: Bool { get }
  var showCodePointForCurrentCandidate: Bool { get }
  var shouldAutoExpandCandidates: Bool { get }
  var isCandidateContextMenuEnabled: Bool { get }
  var showReverseLookupResult: Bool { get }
  var clientAccentColor: HSBA? { get }
}

extension CtlCandidateDelegate {
  /// 鼠標 callback 可能晚於候選頁面更新才送達。只有 index 與按下當時的
  /// 候選仍與當前內容一致時才允許確認，避免同一槽位已換頁後選錯字。
  public func candidatePairSelectionConfirmed(
    at index: Int, expectedCandidate: CandidateInState?
  ) {
    guard let expectedCandidate, let currentCandidate = getCandidate(at: index) else { return }
    guard expectedCandidate.keyArray == currentCandidate.keyArray,
          expectedCandidate.value == currentCandidate.value else { return }
    candidatePairSelectionConfirmed(at: index)
  }
}

// MARK: - CtlCandidateProtocol

public protocol CtlCandidateProtocol: AnyObject {
  var delegate: CtlCandidateDelegate? { get set }
  var highlightedIndex: Int { get set }
  var visible: Bool { get set }
  var expanded: Bool { get }
  var currentLayout: UILayoutOrientation { get set }

  func showNextPage() -> Bool
  func showPreviousPage() -> Bool
  func showNextLine() -> Bool
  func showPreviousLine() -> Bool
  func highlightNextCandidate() -> Bool
  func highlightPreviousCandidate() -> Bool
  func candidateIndexAtKeyLabelIndex(_: Int) -> Int?
  /// reposition the candidate/tooltip window; animation may be requested
  func set(
    windowTopLeftPoint: CGPoint,
    bottomOutOfScreenAdjustmentHeight height: Double,
    useGCD: Bool,
    animated: Bool
  )
}

// MARK: - CandidateContextMenuAction

public enum CandidateContextMenuAction {
  case toBoost
  case toNerf
  case toFilter
}
