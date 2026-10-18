// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Montage",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Montage", targets: ["MontageBench"]),
        .library(name: "MontageEngine", targets: ["MontageEngine"]),
    ],
    targets: [
        // Engine: compositor, export, AI, audio. No UI dependency (headless-testable).
        .target(name: "MontageEngine"),
        // App/bench executable: AppKit + SwiftUI shell, Metal preview and timeline views.
        .executableTarget(name: "MontageBench", dependencies: ["MontageEngine"]),
        .testTarget(name: "MontageEngineTests", dependencies: ["MontageEngine"]),
    ],
    // Swift 6 toolchain, Swift 5 language mode: AVFoundation's callback-heavy APIs
    // (AVVideoCompositing, display links, Metal completion handlers) still fight strict concurrency.
    swiftLanguageModes: [.v5]
)
