// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BarkCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "BarkCore", type: .static, targets: ["BarkCore"])],
    targets: [
        .target(name: "BarkCore", path: "packages/core/src"),
        .testTarget(name: "BarkCoreTests", dependencies: ["BarkCore"], path: "packages/core/tests")
    ]
)
