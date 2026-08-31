// (c) 2026 and onwards The vChewing Project (MIT-NTL License).
// ====================
// This code is released under the MIT license (SPDX-License-Identifier: MIT)
// ... with NTL restriction stating that:
// No trademark license is granted to use the trade names, trademarks, service
// marks, or product names of Contributor, except as required to fulfill notice
// requirements defined in MIT License.

import Foundation

// MARK: - CharLM.Weights

extension CharLM {
  /// 訓練管線匯出的 VCLM 權重檔。
  ///
  /// 檔案佈局（全部 little-endian）：
  /// ```
  /// magic        4 bytes   "VCLM"
  /// version      uint32
  /// dtype        uint32    0 = float32, 1 = float16
  /// vocabSize    uint32
  /// window       uint32
  /// embDim       uint32
  /// hidden       uint32
  /// tensorCount  uint32
  /// ── tensorCount 個張量 ──
  ///   nameLength uint32 / name / ndim uint32 / shape / data
  /// ── 詞彙表 ──
  ///   byteCount  uint32 / UTF-8 文字，以 \n 分隔，順序即 token id
  /// ```
  ///
  /// 權重一律在載入時展開為 `Float`：fp16 檔案約 3.3MB，展開後約 6.5MB，
  /// 仍遠低於設計文件 §3 約束 D 所列的 20MB 重新評估門檻，換來的是
  /// 推論時可直接餵給 BLAS、不必逐元素轉換。
  public struct Weights: Sendable {
    // MARK: Lifecycle

    public init(contentsOf url: URL) throws {
      try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public init(data: Data) throws {
      var reader = ByteReader(data: data)

      guard try reader.readBytes(4).elementsEqual(Self.magic) else {
        throw CharLM.Error.badMagic
      }
      let version = try reader.readUInt32()
      guard version == Self.supportedVersion else {
        throw CharLM.Error.unsupportedVersion(Int(version))
      }
      let dtypeID = try reader.readUInt32()
      guard let dtype = DType(rawValue: dtypeID) else {
        throw CharLM.Error.unsupportedDType(Int(dtypeID))
      }
      self.vocabSize = Int(try reader.readUInt32())
      self.window = Int(try reader.readUInt32())
      self.embDim = Int(try reader.readUInt32())
      self.hidden = Int(try reader.readUInt32())
      let tensorCount = Int(try reader.readUInt32())

      guard vocabSize > 0, window > 0, embDim > 0, hidden > 0 else {
        throw CharLM.Error.malformed("張量維度必須為正數")
      }

      var tensors = [String: (shape: [Int], values: [Float])]()
      for _ in 0 ..< tensorCount {
        let nameLength = Int(try reader.readUInt32())
        let name = try reader.readString(nameLength)
        let ndim = Int(try reader.readUInt32())
        var shape = [Int]()
        for _ in 0 ..< ndim { shape.append(Int(try reader.readUInt32())) }
        let count = shape.reduce(1, *)
        tensors[name] = (shape, try reader.readFloats(count, as: dtype))
      }

      let vocabByteCount = Int(try reader.readUInt32())
      let vocabBlob = try reader.readString(vocabByteCount)
      // 詞彙表以 \n 分隔；某些 token 本身就是換行以外的空白字元，故不可 trim。
      let itos = vocabBlob.components(separatedBy: "\n")
      guard itos.count == vocabSize else {
        throw CharLM.Error.malformed("詞彙表 \(itos.count) 筆與宣告的 \(vocabSize) 不符")
      }
      guard reader.isAtEnd else {
        throw CharLM.Error.malformed("檔案尾端有 \(reader.remainingCount) bytes 未被消耗")
      }

      func take(_ name: String, _ expected: [Int]) throws -> [Float] {
        guard let tensor = tensors[name] else {
          throw CharLM.Error.missingTensor(name)
        }
        guard tensor.shape == expected else {
          throw CharLM.Error.shapeMismatch(name: name, expected: expected, actual: tensor.shape)
        }
        return tensor.values
      }

      // 名稱沿用 PyTorch 的 state_dict 鍵；net.0 / net.3 / net.6 之間的空號
      // 是 nn.Sequential 裡的 ReLU 與 Dropout，本身沒有權重。
      self.embedding = try take("emb.weight", [vocabSize, embDim])
      self.hidden1Weight = try take("net.0.weight", [hidden, window * embDim])
      self.hidden1Bias = try take("net.0.bias", [hidden])
      self.hidden2Weight = try take("net.3.weight", [hidden, hidden])
      self.hidden2Bias = try take("net.3.bias", [hidden])
      self.projectionWeight = try take("net.6.weight", [embDim, hidden])
      self.projectionBias = try take("net.6.bias", [embDim])
      self.outputBias = try take("out_bias", [vocabSize])
      self.itos = itos

      var stoi = [Character: Int](minimumCapacity: vocabSize)
      for (index, token) in itos.enumerated() where token.count == 1 {
        // 特殊符號（<pad>/<bos>/<unk>）長度大於 1，自然被排除在字元查詢之外。
        // 若同一字元重複出現，保留 id 最小者（其詞頻較高）。
        if let character = token.first, stoi[character] == nil { stoi[character] = index }
      }
      self.stoi = stoi
    }

    // MARK: Public

    public let vocabSize: Int
    public let window: Int
    public let embDim: Int
    public let hidden: Int

    /// token id → 字面。特殊符號為多字元字串。
    public let itos: [String]

    // MARK: Internal

    /// [vocabSize, embDim]，同時作為輸出層（weight tying）。
    internal let embedding: [Float]
    /// [hidden, window * embDim]
    internal let hidden1Weight: [Float]
    internal let hidden1Bias: [Float]
    /// [hidden, hidden]
    internal let hidden2Weight: [Float]
    internal let hidden2Bias: [Float]
    /// [embDim, hidden]
    internal let projectionWeight: [Float]
    internal let projectionBias: [Float]
    /// [vocabSize]
    internal let outputBias: [Float]

    /// 單一字元 → token id。特殊符號不在此表內。
    internal let stoi: [Character: Int]

    // MARK: Private

    private static let magic: [UInt8] = Array("VCLM".utf8)
    private static let supportedVersion: UInt32 = 1
  }
}

// MARK: - CharLM.Weights.DType

extension CharLM.Weights {
  fileprivate enum DType: UInt32 {
    case float32 = 0
    case float16 = 1

    var byteWidth: Int {
      switch self {
      case .float32: 4
      case .float16: 2
      }
    }
  }
}

// MARK: - ByteReader

/// 循序讀取 little-endian 資料的極簡讀取器。
///
/// 一律使用 `loadUnaligned`：VCLM 的張量資料前面是變動長度的名稱字串，
/// 因此浮點陣列的起點不保證對齊。
private struct ByteReader {
  // MARK: Lifecycle

  init(data: Data) {
    self.data = data
    self.offset = 0
  }

  // MARK: Internal

  var isAtEnd: Bool { offset == data.count }
  var remainingCount: Int { data.count - offset }

  mutating func readBytes(_ count: Int) throws -> [UInt8] {
    try ensure(count)
    defer { offset += count }
    return [UInt8](data[data.startIndex + offset ..< data.startIndex + offset + count])
  }

  mutating func readUInt32() throws -> UInt32 {
    try ensure(4)
    defer { offset += 4 }
    return data.withUnsafeBytes { raw in
      UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
  }

  mutating func readString(_ byteCount: Int) throws -> String {
    let bytes = try readBytes(byteCount)
    guard let result = String(bytes: bytes, encoding: .utf8) else {
      throw CharLM.Error.malformed("字串不是合規的 UTF-8")
    }
    return result
  }

  mutating func readFloats(_ count: Int, as dtype: CharLM.Weights.DType) throws -> [Float] {
    let byteCount = count * dtype.byteWidth
    try ensure(byteCount)
    defer { offset += byteCount }
    let start = offset
    return data.withUnsafeBytes { raw in
      switch dtype {
      case .float32:
        return (0 ..< count).map { index in
          Float(bitPattern: UInt32(
            littleEndian: raw.loadUnaligned(
              fromByteOffset: start + index * 4, as: UInt32.self
            )
          ))
        }
      case .float16:
        return (0 ..< count).map { index in
          Self.float(fromHalfBits: UInt16(
            littleEndian: raw.loadUnaligned(
              fromByteOffset: start + index * 2, as: UInt16.self
            )
          ))
        }
      }
    }
  }

  // MARK: Private

  private let data: Data
  private var offset: Int

  /// IEEE 754 binary16 → binary32。
  ///
  /// ⚠️ 手寫而非使用 `Float16`：後者在 **x86_64 macOS 上不存在**，而 `make release`
  /// 仍會建置 x86_64 slice 再 lipo 成 universal binary（見 Makefile 的 universal-build）。
  /// 改用 `Float16` 會讓 arm64 建得過、x86_64 直接編譯失敗——而且錯誤訊息會表現成
  /// `withUnsafeBytes` 的泛型參數推導失敗，跟真正的原因差很遠。
  ///
  /// 要拿掉這段的前提是 Makefile 先停止產出 x86_64 slice，不是「產品不再支援 Intel 機種」。
  ///
  /// 轉換只在載入時執行一次，成本可忽略。
  private static func float(fromHalfBits bits: UInt16) -> Float {
    let sign = UInt32(bits & 0x8000) << 16
    let exponent = UInt32((bits >> 10) & 0x1F)
    let mantissa = UInt32(bits & 0x03FF)

    switch exponent {
    case 0:
      guard mantissa != 0 else { return Float(bitPattern: sign) } // ±0
      // 非正規數：左移至隱含位就位，並據此回推指數。
      var normalized = mantissa
      var shifts: UInt32 = 0
      while normalized & 0x0400 == 0 {
        normalized <<= 1
        shifts += 1
      }
      normalized &= 0x03FF
      let biased = UInt32(113) &- shifts // (1 - shifts) - 15 + 127
      return Float(bitPattern: sign | (biased << 23) | (normalized << 13))
    case 0x1F:
      return Float(bitPattern: sign | 0x7F80_0000 | (mantissa << 13)) // ±inf / NaN
    default:
      return Float(bitPattern: sign | ((exponent + 112) << 23) | (mantissa << 13))
    }
  }

  private func ensure(_ count: Int) throws {
    guard count >= 0, offset + count <= data.count else {
      throw CharLM.Error.truncated(offset: offset, needed: count, available: remainingCount)
    }
  }
}
