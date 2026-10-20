// swift-tools-version: 6.2
// Montage — native macOS video editor. See docs/ARCHITECTURE.md before changing module boundaries.
import PackageDescription

// Swift 6 language mode (strict concurrency) everywhere.
let strict: [SwiftSetting] = []
// UI-facing modules run on the main actor by default (SE-0466); engine/core stay nonisolated.
let mainActorByDefault: [SwiftSetting] = strict + [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "Montage",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Montage", targets: ["MontageApp"]),
        .library(name: "MontageCore", targets: ["MontageCore"]),
        .library(name: "MontageEngine", targets: ["MontageEngine"]),
    ],
    dependencies: [
        // Observation back-port for macOS 13 (native Observation is used on 14+). MIT, Point-Free.
        .package(url: "https://github.com/pointfreeco/swift-perception", from: "2.0.12"),
    ],
    targets: [
        // Pure Swift model: project/timeline/keyframes/speed/commands/persistence/localization. Foundation only.
        .target(name: "MontageCore", path: "app/Sources/MontageCore",
                resources: [.process("Resources")], swiftSettings: strict),
        // Registries + built-in effects/filters/transitions/animations (descriptors + MSL snippets). No AVFoundation.
        .target(name: "MontageEffects", dependencies: ["MontageCore"], path: "app/Sources/MontageEffects",
                resources: [.process("Resources")], swiftSettings: strict),
        // Media engine: decode, Metal compositor, playback, proxies, caches, export, jobs.
        .target(name: "MontageEngine", dependencies: ["MontageCore", "MontageEffects"], path: "app/Sources/MontageEngine",
                resources: [.process("Resources")], swiftSettings: strict),
        // On-device AI: tool protocols, registry, Vision/Speech adapters.
        .target(name: "MontageAI", dependencies: ["MontageCore", "MontageEngine",
                                               .product(name: "Perception", package: "swift-perception")], path: "app/Sources/MontageAI",
                resources: [.process("Resources")], swiftSettings: strict),
        // SwiftUI + AppKit editor shell (player, timeline canvas, panels, inspector).
        .target(name: "MontageUI", dependencies: ["MontageCore", "MontageEffects", "MontageEngine", "MontageAI",
                                               .product(name: "Perception", package: "swift-perception")],
                path: "app/Sources/MontageUI", resources: [.process("Resources")], swiftSettings: mainActorByDefault),
        .executableTarget(name: "MontageApp", dependencies: ["MontageUI"], path: "app/Sources/MontageApp",
                          swiftSettings: mainActorByDefault),
        // Shared test helpers: synthetic media, renderFrame/export harness, pixel asserts, ffprobe.
        .target(name: "MontageTestSupport", dependencies: ["MontageCore", "MontageEffects", "MontageEngine"],
                path: "app/Sources/MontageTestSupport", swiftSettings: strict),

        .testTarget(name: "MontageCoreTests", dependencies: ["MontageCore"], path: "app/Tests/MontageCoreTests"),
        .testTarget(name: "MontageEffectsTests", dependencies: ["MontageEffects", "MontageTestSupport"],
                    path: "app/Tests/MontageEffectsTests"),
        .testTarget(name: "MontageEngineTests", dependencies: ["MontageEngine", "MontageTestSupport"],
                    path: "app/Tests/MontageEngineTests"),
        .testTarget(name: "MontageUITests", dependencies: ["MontageUI", "MontageTestSupport",
                                                           .product(name: "Perception", package: "swift-perception")],
                    path: "app/Tests/MontageUITests"),
        .testTarget(name: "MontageAITests", dependencies: ["MontageAI", "MontageTestSupport"], path: "app/Tests/MontageAITests"),
        .testTarget(name: "MontagePerfTests", dependencies: ["MontageEngine", "MontageTestSupport"],
                    path: "app/Tests/MontagePerfTests"),
    ]
)
