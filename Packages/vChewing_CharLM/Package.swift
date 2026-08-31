// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "CharLM",
  platforms: [
    .macOS(.v12),
  ],
  products: [
    // 融合層的資料型別與協定。純 Swift、零外部相依，因此**可在 Linux 編譯**。
    .library(
      name: "RerankerCore",
      targets: ["RerankerCore"]
    ),
    // 神經網路推論核心。相依 Accelerate，僅限 Darwin。
    .library(
      name: "CharLM",
      targets: ["CharLM"]
    ),
    // 與 Homa 組字器的橋接層。相依 Homa 與 RerankerCore，**可在 Linux 編譯**。
    .library(
      name: "HomaReranker",
      targets: ["HomaReranker"]
    ),
  ],
  dependencies: [
    .package(path: "../vChewing_Homa"),
  ],
  targets: [
    // ⚠️ 這個切分不是為了整潔，是硬性約束：`vChewing_LangModelAssembly` 位於
    // `vChewing_Typewriter` 的相依鏈上，而 Typewriter 一線必須能在 Linux 編譯
    // （見 `Makefile` 的 `spmLinuxTest-Typewriter`）。因此凡是 LMAssembly 會碰到的
    // 型別，都不得落在會 `import Accelerate` 的目標裡。
    .target(
      name: "RerankerCore"
    ),
    .target(
      name: "CharLM",
      dependencies: ["RerankerCore"]
    ),
    .target(
      name: "HomaReranker",
      dependencies: [
        "RerankerCore",
        .product(name: "Homa", package: "vChewing_Homa"),
      ]
    ),
    .testTarget(
      name: "CharLMTests",
      dependencies: ["CharLM"]
    ),
    .testTarget(
      name: "HomaRerankerTests",
      dependencies: [
        "HomaReranker",
        "RerankerCore",
        .product(name: "Homa", package: "vChewing_Homa"),
        .product(name: "HomaSharedTestComponents", package: "vChewing_Homa"),
      ]
    ),
  ]
)
