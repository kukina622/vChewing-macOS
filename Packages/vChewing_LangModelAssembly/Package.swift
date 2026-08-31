// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "LangModelAssembly",
  platforms: [
    .macOS(.v12),
  ],
  products: [
    .library(
      name: "LangModelAssembly",
      targets: ["LangModelAssembly"]
    ),
    .library(
      name: "LMAssemblyMaterials4Tests",
      targets: ["LMAssemblyMaterials4Tests"]
    ),
  ],
  dependencies: [
    .package(path: "../RMJay_LineReader"),
    .package(path: "../vChewing_CharLM"),
    .package(path: "../vChewing_Homa"),
    .package(path: "../vChewing_Shared"),
    .package(path: "../vChewing_SwiftExtension"),
    .package(path: "../vChewing_Tekkon"),
  ],
  targets: [
    .target(
      name: "TrieKit",
      dependencies: [
        .product(name: "SwiftExtension", package: "vChewing_SwiftExtension"),
      ]
    ),
    .target(
      name: "LMAssemblyMaterials4Tests",
      resources: [
        .process("Resources"),
      ]
    ),
    .target(
      name: "LangModelAssembly",
      dependencies: [
        "TrieKit",
        .product(name: "Homa", package: "vChewing_Homa"),
        // ⚠️ 只能引用 HomaReranker（純 Swift）。同套件的 CharLM 目標相依 Accelerate，
        // 一旦被拉進來就會讓 Typewriter 一線無法在 Linux 編譯。
        .product(name: "HomaReranker", package: "vChewing_CharLM"),
        .product(name: "Shared", package: "vChewing_Shared"),
        .product(name: "SwiftExtension", package: "vChewing_SwiftExtension"),
      ],
      swiftSettings: [
        .defaultIsolation(MainActor.self), // set Default Actor Isolation
      ]
    ),
    .testTarget(
      name: "TrieKitTests",
      dependencies: [
        "TrieKit",
        "LMAssemblyMaterials4Tests",
        .product(name: "Homa", package: "vChewing_Homa"),
        .product(name: "Tekkon", package: "vChewing_Tekkon"),
      ],
      swiftSettings: [
        .defaultIsolation(MainActor.self), // set Default Actor Isolation
      ]
    ),
    .testTarget(
      name: "LangModelAssemblyTests",
      dependencies: [
        "LangModelAssembly",
        "LMAssemblyMaterials4Tests",
        .product(name: "Homa", package: "vChewing_Homa"),
        .product(name: "HomaSharedTestComponents", package: "vChewing_Homa"),
        .product(name: "Tekkon", package: "vChewing_Tekkon"),
      ],
      swiftSettings: [
        .defaultIsolation(MainActor.self), // set Default Actor Isolation
      ]
    ),
  ]
)
