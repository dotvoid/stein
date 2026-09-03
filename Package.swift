// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "Stein",
  platforms: [.macOS(.v14)],
  targets: [
    .target(
      name: "SteinCore",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
      name: "Stein",
      dependencies: ["SteinCore"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "SteinCoreTests",
      dependencies: ["SteinCore"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    )
  ]
)
