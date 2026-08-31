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
import Shared

// MARK: - CharLMRerankerMgr

/// 上下文重排模型的載入與快取。
///
/// 模型是隨 App 打包的靜態資源（`Resources/charlm-<mode>.bin`），
/// 走既有的 `Bundle.currentSPM` 查詢器——與 `convdict.stringmap` 同一條路徑。
///
/// 設計與實測依據見 `DevLab/AICandidateSelection_Design.md` §4.8。
@MainActor
public enum CharLMRerankerMgr {
  // MARK: Public

  /// 取得指定模式的組句重排器。模型缺失或損毀時回傳 `nil`，呼叫端直接跳過重排即可。
  ///
  /// 首次呼叫會載入約 3.3MB 的權重並展開為 `Float`（約 6.5MB 常駐），實測耗時 8–11ms。
  /// 結果會被快取，**失敗也會被快取**——否則每次按鍵都會重試一次失敗的檔案讀取。
  public static func reranker(for mode: Shared.InputMode) -> SentenceReranker? {
    if let cached = cache[mode] { return cached.value }
    let built = load(mode)
    cache[mode] = Box(value: built)
    return built
  }

  /// 該模式是否備有可用的模型。
  ///
  /// 目前僅提供繁體模型（設計文件 §4.6：先做繁體，管線走通再補簡體），
  /// 因此簡體模式下這裡會是 `false`，功能自動保持沉默。
  public static func isAvailable(for mode: Shared.InputMode) -> Bool {
    reranker(for: mode) != nil
  }

  /// 供測試與偏好設定變更後重置之用。
  public static func invalidateCache() {
    cache.removeAll()
  }

  // MARK: Private

  private struct Box {
    let value: SentenceReranker?
  }

  private static var cache = [Shared.InputMode: Box]()

  private static func resourceName(for mode: Shared.InputMode) -> String? {
    switch mode {
    case .imeModeCHT: "charlm-cht"
    case .imeModeCHS: "charlm-chs"
    case .imeModeNULL: nil
    }
  }

  private static func load(_ mode: Shared.InputMode) -> SentenceReranker? {
    guard let name = resourceName(for: mode) else { return nil }
    guard let url = Bundle.currentSPM.url(forResource: name, withExtension: "bin") else {
      vCLog("CharLM: 找不到模型資源 \(name).bin，該模式的上下文重排停用。")
      return nil
    }
    do {
      let model = try CharLM(contentsOf: url)
      return SentenceReranker(
        reranker: CharLMReranker(model: model),
        configuration: .init()
      )
    } catch {
      // 契約 4（退化安全）：載入失敗一律靜默退回，不得影響輸入。
      vCLog("CharLM: 模型 \(name).bin 載入失敗（\(error)），該模式的上下文重排停用。")
      return nil
    }
  }
}
