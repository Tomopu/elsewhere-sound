// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ElsewhereSound",
  // Core Audio の Process Tap は macOS 14.2 から、Synchronization（Atomic）は macOS 15 から
  platforms: [.macOS(.v15)],
  targets: [
    // 音の加工だけ。Core Audio にも画面にも依存しないので、ファイルを入れてテストできる
    .target(name: "ElsewhereSoundDSP"),
    .executableTarget(
      name: "ElsewhereSound",
      dependencies: ["ElsewhereSoundDSP"],
      // Core Audio のコールバックは C の世界なので、Swift 6 の厳密な並行性チェックとは相性が悪い
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(name: "ElsewhereSoundDSPTests", dependencies: ["ElsewhereSoundDSP"]),
    // アプリ側のうち、画面や Core Audio を動かさずに確かめられる部分（アップデートの確認の版の比べ方など）
    .testTarget(name: "ElsewhereSoundTests", dependencies: ["ElsewhereSound"]),
  ]
)
