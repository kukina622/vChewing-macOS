// (c) 2026 and onwards The vChewing Project (MIT-NTL License).
// ====================
// This code is released under the MIT license (SPDX-License-Identifier: MIT)
// ... with NTL restriction stating that:
// No trademark license is granted to use the trade names, trademarks, service
// marks, or product names of Contributor, except as required to fulfill notice
// requirements defined in MIT License.

// `CharLMReranker` 的公開簽章直接露出 `RerankCandidate` 與 `CandidateReranker`，
// 因此只 import CharLM 的呼叫端也必須看得到它們。
@_exported import RerankerCore
