// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Launchcheck",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LaunchcheckCore", targets: ["LaunchcheckCore"]),
        .executable(name: "Launchcheck", targets: ["Launchcheck"]),
        .executable(name: "launchcheck-cli", targets: ["launchcheck-cli"]),
    ],
    targets: [
        // UI-free engine: fetching, HTML scanning, robots.txt and sitemaps, the checks, report formats.
        .target(name: "LaunchcheckCore", path: "Sources/LaunchcheckCore"),
        // The SwiftUI app.
        .executableTarget(name: "Launchcheck", dependencies: ["LaunchcheckCore"], path: "Sources/Launchcheck"),
        // Command-line front end to the same engine.
        .executableTarget(name: "launchcheck-cli", dependencies: ["LaunchcheckCore"], path: "Sources/launchcheck-cli"),
        .testTarget(name: "LaunchcheckCoreTests", dependencies: ["LaunchcheckCore"], path: "Tests/LaunchcheckCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
