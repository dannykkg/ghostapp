// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "GhostApp",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "ghostapp", targets: ["GhostApp"]),
    .library(name: "GhostAppCore", targets: ["GhostAppCore"]),
  ],
  targets: [
    .target(
      name: "GhostAppCore",
      resources: [.process("Resources")]
    ),
    .executableTarget(
      name: "GhostApp",
      dependencies: ["GhostAppCore"]
    ),
    .testTarget(
      name: "GhostAppCoreTests",
      dependencies: ["GhostAppCore"]
    ),
  ]
)
