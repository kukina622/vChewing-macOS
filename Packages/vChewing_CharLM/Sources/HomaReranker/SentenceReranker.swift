// (c) 2026 and onwards The vChewing Project (MIT-NTL License).
// ====================
// This code is released under the MIT license (SPDX-License-Identifier: MIT)
// ... with NTL restriction stating that:
// No trademark license is granted to use the trade names, trademarks, service
// marks, or product names of Contributor, except as required to fulfill notice
// requirements defined in MIT License.

import Foundation
import Homa
import RerankerCore

// MARK: - SentenceReranker

/// 在 Homa 的 DP 結果之上重排同音詞，並以弱覆寫寫回組字器。
///
/// 對應設計文件 `DevLab/AICandidateSelection_Design.md` §4.2 的位置 ③：
///
/// ```
/// ① Homa DP 決定斷詞（既有能力，不改）
///         ↓  assembledSentence: [GramInPath]
/// ② 沿路徑展開各節點的同音詞
///         ↓
/// ③ CandidateReranker 打分（Homa 先驗 + λ_LM × LM + λ_POM × POM）
///         ↓
/// ④ 以 overrideCandidate() 弱覆寫寫回
/// ```
///
/// ## 為什麼是「沿路徑變動元圖」而非「列舉多條路徑」
///
/// 設計文件 §1.5 講得很明白：用 k-shortest-paths 列舉路徑得到的是一堆**斷詞**變體
/// （手機號碼／手機號 碼／手 機 號碼），但每個節點仍然只出 `grams[0]`，
/// 同音詞從頭到尾沒變過，對本問題毫無幫助。
///
/// 因此這裡只在 DP 選定的斷詞框架**內**替換同音詞：**斷詞歸 DP，同音詞歸 reranker。**
///
/// ## Beam search：後文可以回頭改前文
///
/// 逐節點由左至右維護 `beamWidth` 條假設，最後取**聯合分數**最高的路徑。
/// 這是「往後打字能修正前面的字」的來源——即使語言模型是因果的（只看左文），
/// 聯合最佳化仍能讓後文的證據倒推回去：
///
/// ```
/// 貪婪：  先挑 node₁ 最佳（城市），再挑 node₂ 給定 node₁  →  城市設計
/// Beam：  比較 (城市+設計) 與 (程式+設計) 的總分          →  程式設計
/// ```
///
/// 因為「設計」接在「程式」後的機率遠高於接在「城市」後，這個差距會透過
/// 轉移項影響第一個節點的選擇。`beamWidth = 1` 即退化為貪婪，可作對照組。
///
/// ## ⚠️ 兩個不變式
///
/// 1. **使用者選過的節點永遠釘死。** 它們仍然貢獻上下文，但不參與搜尋、
///    不可能被改掉（`skipsExplicitlyOverridden`）。
/// 2. **分數必須跨節點可比。** Beam 會把不同節點的分數加總，因此
///    `CandidateReranker` 的實作必須回傳**在候選集內正規化過**的分數。
///    `CharLMReranker` 已照此實作；回傳未正規化的 logit 會讓比較失去意義，
///    因為不同假設的隱含分母不同。
@MainActor
public struct SentenceReranker: Sendable {
  // MARK: Lifecycle

  public init(
    reranker: CandidateReranker,
    configuration: Configuration = .init()
  ) {
    self.reranker = reranker
    self.configuration = configuration
  }

  // MARK: Public

  /// 查詢某個節點各候選的 POM 支持度。
  ///
  /// - Parameters:
  ///   - assembledSentence: 當前組句結果（供 POM 取用前文脈絡）。
  ///   - location: 該節點起點在讀音陣列裡的索引。
  /// - Returns: 候選字面 → 支持度。**沒有記憶的候選不必出現在字典裡**（視同 0）。
  ///
  /// 之所以做成注入的閉包而非型別相依：POM（`LXPerceptor`）住在
  /// `vChewing_LangModelAssembly`，而本套件反過來是它的相依項，不能倒著引用。
  public typealias POMScoreProvider = @MainActor (
    _ assembledSentence: [Homa.GramInPath],
    _ location: Int
  ) -> [String: Double]

  public let reranker: CandidateReranker
  public let configuration: Configuration

  /// 對組字器的當前組句結果做同音詞重排，並把勝出者寫回。
  ///
  /// - Parameters:
  ///   - assembler: 目標組字器。呼叫端必須確保它已經 `assemble()` 過。
  ///   - pomScores: 選用的 POM 支持度查詢器，見 `POMScoreProvider`。
  /// - Returns: 實際發生的替換紀錄，依處理順序排列。沒有任何替換時為空陣列。
  @discardableResult
  public func apply(
    to assembler: Homa.Assembler,
    pomScores: POMScoreProvider? = nil
  )
    -> [Change] {
    guard !assembler.keys.isEmpty else { return [] }

    // ⚠️ 必須避免的回饋迴圈（設計文件 §4.5 結尾）：
    // `overrideCandidateAgainst` 會在 defer 裡呼叫 `(perceptionHandler ?? perceptor)?(intel)`。
    // 若不擋掉，reranker 自己的覆寫會被 POM 記成「使用者的選擇」，
    // 模型將訓練於自己的輸出，偏誤被放大。
    //
    // 這裡把 perceptor 暫時取下而非傳入 no-op handler：後者會讓
    // `shouldObserve` 為真，白白多跑一次 `assemble()`。
    let savedPerceptor = assembler.perceptor
    assembler.perceptor = nil
    defer { assembler.perceptor = savedPerceptor }

    let sentence = assembler.assembledSentence
    guard !sentence.isEmpty else { return [] }

    let slots = makeSlots(from: sentence, in: assembler, pomScores: pomScores)
    guard slots.contains(where: { !$0.isPinned }) else { return [] }
    guard let plan = search(slots) else { return [] }
    return writeBack(plan, slots: slots, to: assembler)
  }

  // MARK: Private

  /// 一個節點在計畫中的位置。候選少於 2 個即代表**釘死**、不參與搜尋。
  private struct Slot {
    let location: Int
    let segLength: Int
    let original: String
    let candidates: [RerankCandidate]

    var isPinned: Bool { candidates.count < 2 }
  }

  /// Beam 中的一條假設。
  private struct Hypothesis {
    var score: Double
    var choices: [String]
    /// 已定案字面的尾端（長度受 `maxContextCharacters` 限制）。
    var context: String
    /// 是否為「完全不動」的那條路徑。它永遠不會被剪掉，
    /// 好讓最後能拿它跟勝出者比 `minimumMargin`。
    var isOriginal: Bool
  }

  private func makeSlots(
    from sentence: [Homa.GramInPath],
    in assembler: Homa.Assembler,
    pomScores: POMScoreProvider?
  )
    -> [Slot] {
    var slots = [Slot]()
    var location = 0
    for node in sentence {
      let here = location
      location += node.segLength
      func pinned() -> Slot {
        .init(location: here, segLength: node.segLength, original: node.value, candidates: [])
      }
      guard shouldProcess(node) else { slots.append(pinned()); continue }
      let fetched = rawCandidates(for: node, at: here, in: assembler)
      guard fetched.count > 1 else { slots.append(pinned()); continue }
      let pom: [String: Double] = pomScores?(sentence, here) ?? [:]
      slots.append(.init(
        location: here, segLength: node.segLength, original: node.value,
        candidates: prune(fetched, current: node.value, pomScores: pom)
      ))
    }
    return slots
  }

  /// 回傳勝出路徑的各節點字面；沒有值得寫回的變更時回傳 `nil`。
  private func search(_ slots: [Slot]) -> [String]? {
    var beam = [Hypothesis(score: 0, choices: [], context: "", isOriginal: true)]

    for slot in slots {
      guard !slot.isPinned else {
        // 釘死的節點：所有假設一律沿用原值，但它仍然貢獻上下文。
        beam = beam.map { hypothesis in
          var next = hypothesis
          next.choices.append(slot.original)
          next.context = Self.trimmed(
            hypothesis.context + slot.original, to: configuration.maxContextCharacters
          )
          return next
        }
        continue
      }

      var expanded = [Hypothesis]()
      expanded.reserveCapacity(beam.count * slot.candidates.count)
      for hypothesis in beam {
        let scores = reranker.rescore(slot.candidates, leftContext: hypothesis.context)
        guard scores.count == slot.candidates.count else { return nil } // 契約被違反
        for (index, candidate) in slot.candidates.enumerated() {
          expanded.append(Hypothesis(
            score: hypothesis.score + scores[index],
            choices: hypothesis.choices + [candidate.value],
            context: Self.trimmed(
              hypothesis.context + candidate.value, to: configuration.maxContextCharacters
            ),
            isOriginal: hypothesis.isOriginal && candidate.value == slot.original
          ))
        }
      }

      // 排序必須是決定性的：分數相同時以字面排序打破平手（契約 1）。
      expanded.sort {
        $0.score == $1.score
          ? $0.choices.joined() < $1.choices.joined()
          : $0.score > $1.score
      }
      var survivors = Array(expanded.prefix(configuration.beamWidth))
      // 原始路徑永遠保留：最後要拿它當 minimumMargin 的比較基準。
      if !survivors.contains(where: { $0.isOriginal }),
         let original = expanded.first(where: { $0.isOriginal }) {
        survivors.append(original)
      }
      beam = survivors
    }

    guard let best = beam.first,
          let original = beam.first(where: { $0.isOriginal }),
          best.choices != original.choices
    else { return nil }
    // 邊際優勢不足時整條路徑都不動：把「模型只是稍微偏好另一種說法」的雜訊擋掉，
    // 避免使用者看到整條組字區無謂地重寫。
    guard best.score - original.score >= configuration.minimumMargin else { return nil }
    return best.choices
  }

  /// 把計畫寫回組字器。
  ///
  /// 每次覆寫前都重新確認節點仍在原位：弱覆寫理論上不改變斷詞，但
  /// `withTopGramScore` 提高了該候選的分數，DP 仍有可能挑出不同的路徑。
  /// 一旦對不上就收手，已完成的替換保留（契約 4：退化安全）。
  private func writeBack(
    _ plan: [String],
    slots: [Slot],
    to assembler: Homa.Assembler
  )
    -> [Change] {
    var changes = [Change]()
    for (index, slot) in slots.enumerated() where plan[index] != slot.original {
      guard let hit = assembler.assembledSentence.findGram(at: slot.location),
            hit.range.lowerBound == slot.location,
            hit.gram.value == slot.original,
            hit.gram.keyArray.count == slot.segLength
      else { break }
      do {
        try assembler.overrideCandidate(
          Homa.CandidatePair(keyArray: hit.gram.keyArray, value: plan[index]),
          at: slot.location,
          // 弱覆寫：只把該候選提到節點首位，不強制壓過 DP 的斷詞判斷。
          type: .withTopGramScore,
          // 絕對不能是 true：那會讓 POM 與後續邏輯把它當成使用者的明確選擇。
          isExplicitlyOverridden: false,
          enforceRetokenization: false
        )
      } catch {
        break
      }
      changes.append(Change(
        position: slot.location,
        keyArray: hit.gram.keyArray,
        from: slot.original,
        to: plan[index],
        margin: 0
      ))
    }
    return changes
  }


  /// 回傳 `nil` 代表 `position` 落在某個節點的中間——重新組句後邊界移動了，
  /// 此時沒有任何一個「左文」的定義是乾淨的。
  private static func locate(
    _ position: Int,
    in sentence: [Homa.GramInPath],
    maxContextCharacters: Int
  )
    -> (index: Int, leftText: String)? {
    var cursor = 0
    var text = ""
    for (index, gram) in sentence.enumerated() {
      if cursor == position { return (index, trimmed(text, to: maxContextCharacters)) }
      guard cursor < position else { return nil }
      text += gram.value
      cursor += gram.segLength
    }
    guard cursor == position else { return nil }
    return (sentence.count, trimmed(text, to: maxContextCharacters))
  }

  private static func trimmed(_ text: String, to limit: Int) -> String {
    text.count <= limit ? text : String(text.suffix(limit))
  }

  /// - Returns: 實際發生替換時的紀錄；沒動它則為 `nil`。
  private func rerank(
    _ node: Homa.GramInPath,
    at location: Int,
    leftContext: String,
    in assembler: Homa.Assembler,
    sentence: [Homa.GramInPath],
    pomScores: POMScoreProvider?
  )
    -> Change? {
    guard shouldProcess(node) else { return nil }

    // 先確認這個節點真的有得選，再去問 POM：單一候選的節點沒有重排的餘地，
    // 而 POM 查詢會掃過整個組句結果去組三元圖的鍵，白問就是白付 O(節點數) 的成本。
    let fetched = rawCandidates(for: node, at: location, in: assembler)
    guard fetched.count > 1 else { return nil }

    // 刻意不寫成 `pomScores.map { … }`：Optional.map 的閉包是 nonisolated 的，
    // 會擋掉對主執行緒隔離的 POM 查詢器的呼叫。
    let pomScoreMap: [String: Double] = pomScores?(sentence, location) ?? [:]
    let alternatives = prune(fetched, current: node.value, pomScores: pomScoreMap)
    guard alternatives.count > 1 else { return nil }

    let scores = reranker.rescore(alternatives, leftContext: leftContext)
    guard scores.count == alternatives.count else { return nil } // 契約被違反時靜默跳過

    guard let winnerIndex = scores.indices.max(by: { scores[$0] < scores[$1] }),
          let currentIndex = alternatives.firstIndex(where: { $0.value == node.value })
    else { return nil }
    let winner = alternatives[winnerIndex]
    guard winner.value != node.value else { return nil }

    // 邊際優勢不足時不動它：把「模型只是稍微偏好另一個」的雜訊擋掉，
    // 避免使用者看到組字區無謂地跳動。
    let margin = scores[winnerIndex] - scores[currentIndex]
    guard margin >= configuration.minimumMargin else { return nil }

    do {
      try assembler.overrideCandidate(
        Homa.CandidatePair(keyArray: node.keyArray, value: winner.value),
        at: location,
        // 弱覆寫：只把該候選提到節點首位，不強制壓過 DP 的斷詞判斷。
        // 這與 POM 在非 forceHighScoreOverride 時的作法一致（§4.5）。
        type: .withTopGramScore,
        // 絕對不能是 true：那會讓 POM 與後續邏輯把它當成使用者的明確選擇。
        isExplicitlyOverridden: false,
        enforceRetokenization: false
      )
    } catch {
      // 覆寫失敗不是致命錯誤——沿用 Homa 原本的選擇即可（契約 4：退化安全）。
      return nil
    }
    return Change(
      position: location,
      keyArray: node.keyArray,
      from: node.value,
      to: winner.value,
      margin: margin
    )
  }

  /// 這個節點該不該碰。
  private func shouldProcess(_ node: Homa.GramInPath) -> Bool {
    // 使用者已經明確選過的節點，永遠不要跟他搶。
    //
    // ⚠️ 這道閘**擋不住 POM**：`retrievePOMSuggestions` 覆寫時沒有傳
    // `isExplicitlyOverridden`（預設 false），所以 POM 選中的節點在這裡看起來
    // 與未覆寫的節點無異。POM 的意見改由 `pomScore` 參與融合，見 §4.4 的三分工。
    if configuration.skipsExplicitlyOverridden, node.isExplicit { return false }
    // 標點的讀音以底線開頭，沒有同音詞可言。
    if node.keyArray.first?.first == "_" { return false }
    // 讀音與字面對不上的節點（例如以西文直接輸入者）不在重排範圍內。
    if node.isReadingMismatched { return false }
    return true
  }

  /// 取出與該節點**讀音完全相同**的候選，依詞庫分數由高到低排序。
  ///
  /// 只收 `keyArray` 完全相符者：斷詞已由 DP 決定，reranker 不改變幅節長度，
  /// 也不跨讀音替換（那會變成改讀音而非選同音字）。
  private func rawCandidates(
    for node: Homa.GramInPath,
    at location: Int,
    in assembler: Homa.Assembler
  )
    -> [(value: String, weight: Double)] {
    let fetched = assembler.fetchCandidates(at: location, filter: .beginAt)
    var seen = Set<String>()
    var result = [(value: String, weight: Double)]()
    for candidate in fetched where candidate.pair.keyArray == node.keyArray {
      guard seen.insert(candidate.pair.value).inserted else { continue }
      result.append((candidate.pair.value, candidate.weight))
    }
    // fetchCandidates 是依 (幅節長度, 讀音, 權重) 排序的，這裡要的是純粹的詞庫分數序。
    result.sort { $0.weight > $1.weight }
    return result
  }

  /// 剪枝：保留詞庫分數最高的前 N 個，但當前選中者與 POM 記得的候選一定要留著。
  ///
  /// 前者若被剪掉，它就不在比較之列，會導致無條件被替換；
  /// 後者若被剪掉，使用者辛苦教會的個人化訊號就白學了。
  private func prune(
    _ candidates: [(value: String, weight: Double)],
    current: String,
    pomScores: [String: Double]
  )
    -> [RerankCandidate] {
    var pruned = Array(candidates.prefix(configuration.maxCandidatesPerNode))
    var kept = Set(pruned.map(\.value))
    for mustKeep in candidates where !kept.contains(mustKeep.value) {
      guard mustKeep.value == current || pomScores[mustKeep.value] != nil else { continue }
      pruned.append(mustKeep)
      kept.insert(mustKeep.value)
    }
    return pruned.map {
      RerankCandidate(
        value: $0.value,
        priorScore: $0.weight,
        pomScore: pomScores[$0.value] ?? 0
      )
    }
  }
}

// MARK: - SentenceReranker.Configuration

extension SentenceReranker {
  public struct Configuration: Sendable {
    // MARK: Lifecycle

    public init(
      beamWidth: Int = 4,
      maxCandidatesPerNode: Int = 12,
      maxContextCharacters: Int = 8,
      minimumMargin: Double = 0,
      skipsExplicitlyOverridden: Bool = true
    ) {
      self.beamWidth = Swift.max(1, beamWidth)
      self.maxCandidatesPerNode = Swift.max(1, maxCandidatesPerNode)
      self.maxContextCharacters = Swift.max(1, maxContextCharacters)
      self.minimumMargin = minimumMargin
      self.skipsExplicitlyOverridden = skipsExplicitlyOverridden
    }

    // MARK: Public

    /// 同時維護幾條假設。**這是「後文能改前文」的旋鈕。**
    ///
    /// `1` 即退化為貪婪：逐節點取當下最佳，後文永遠影響不了前文。
    /// 調大則以聯合分數決定整條路徑，成本大致線性成長
    /// （每個節點要為每條假設各算一次隱藏層）。
    ///
    /// 預設 4。實測單字節點約 13µs／次前向，10 個節點的組字區約 520µs，
    /// 距離 §3 約束 B 的 10ms 預算仍寬裕。
    public var beamWidth: Int

    /// 每個節點最多送幾個候選進模型。
    ///
    /// 這是延遲的主要旋鈕。單字節點走快路徑、候選數幾乎不影響耗時；
    /// 多字節點則是「相異前綴數 × 一次前向」，候選愈多愈貴。
    public var maxCandidatesPerNode: Int

    /// 餵給模型的左文長度上限。模型窗口只有 4 個字，多給的部分會被丟掉，
    /// 但保留餘裕以便日後換成窗口更長的模型（§4.7 第 2 步）而不必改這裡。
    public var maxContextCharacters: Int

    /// 勝出者必須比當前選擇高出多少分才寫回。
    ///
    /// 預設 0（只要更高就換）。調高可以換取穩定度——組字區在打字過程中
    /// 反覆跳動比偶爾選錯更惱人。
    public var minimumMargin: Double

    /// 是否跳過使用者已明確選過的節點。預設為真，且**不建議關閉**。
    public var skipsExplicitlyOverridden: Bool
  }
}

// MARK: - SentenceReranker.Change

extension SentenceReranker {
  /// 一次實際發生的替換。供測試斷言與除錯輸出使用。
  public struct Change: Hashable, Sendable {
    public let position: Int
    public let keyArray: [String]
    public let from: String
    public let to: String
    public let margin: Double

    public var description: String {
      "\(keyArray.joined(separator: "-")) @\(position)： \(from) → \(to)"
        + String(format: "（+%.3f）", margin)
    }
  }
}
