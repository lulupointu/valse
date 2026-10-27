// swift-tools-version: 6.2
// Valse — native macOS video editor. See docs/ARCHITECTURE.md before changing module boundaries.
import PackageDescription

// Swift 6 language mode (strict concurrency) everywhere.
let strict: [SwiftSetting] = []
// UI-facing modules run on the main actor by default (SE-0466); engine/core stay nonisolated.
let mainActorByDefault: [SwiftSetting] = strict + [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "Valse",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Valse", targets: ["ValseApp"]),
        .library(name: "ValseCore", targets: ["ValseCore"]),
        .library(name: "ValseEngine", targets: ["ValseEngine"]),
    ],
    dependencies: [
        // Observation back-port for macOS 13 (native Observation is used on 14+). MIT, Point-Free.
        .package(url: "https://github.com/pointfreeco/swift-perception", from: "2.0.12"),
        // Automatic updates (SE-015), linked by the app target only. MIT, Sparkle Project.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4"),
    ],
    targets: [
        // Pure Swift model: project/timeline/keyframes/speed/commands/persistence/localization. Foundation only.
        .target(name: "ValseCore", path: "app/Sources/ValseCore",
                resources: [.process("Resources")], swiftSettings: strict),
        // Registries + built-in effects/filters/transitions/animations (descriptors + MSL snippets). No AVFoundation.
        .target(name: "ValseEffects", dependencies: ["ValseCore"], path: "app/Sources/ValseEffects",
                resources: [.process("Resources")], swiftSettings: strict),
        // Media engine: decode, Metal compositor, playback, proxies, caches, export, jobs.
        .target(name: "ValseEngine", dependencies: ["ValseCore", "ValseEffects"], path: "app/Sources/ValseEngine",
                resources: [.process("Resources")], swiftSettings: strict),
        // On-device AI: tool protocols, registry, Vision/Speech adapters.
        .target(name: "ValseAI", dependencies: ["ValseCore", "ValseEngine",
                                               .product(name: "Perception", package: "swift-perception")], path: "app/Sources/ValseAI",
                resources: [.process("Resources")], swiftSettings: strict),
        // SwiftUI + AppKit editor shell (player, timeline canvas, panels, inspector).
        .target(name: "ValseUI", dependencies: ["ValseCore", "ValseEffects", "ValseEngine", "ValseAI",
                                               .product(name: "Perception", package: "swift-perception")],
                path: "app/Sources/ValseUI", resources: [.process("Resources")], swiftSettings: mainActorByDefault),
        .executableTarget(name: "ValseApp", dependencies: ["ValseUI", .product(name: "Sparkle", package: "Sparkle")], path: "app/Sources/ValseApp",
                          swiftSettings: mainActorByDefault),
        // Shared test helpers: synthetic media, renderFrame/export harness, pixel asserts, ffprobe.
        .target(name: "ValseTestSupport", dependencies: ["ValseCore", "ValseEffects", "ValseEngine"],
                path: "app/Sources/ValseTestSupport", swiftSettings: strict),

        .testTarget(name: "ValseCoreTests", dependencies: ["ValseCore"], path: "app/Tests/ValseCoreTests"),
        .testTarget(name: "ValseEffectsTests", dependencies: ["ValseEffects", "ValseTestSupport"],
                    path: "app/Tests/ValseEffectsTests"),
        .testTarget(name: "ValseEngineTests", dependencies: ["ValseEngine", "ValseTestSupport"],
                    path: "app/Tests/ValseEngineTests"),
        .testTarget(name: "ValseUITests", dependencies: ["ValseUI", "ValseTestSupport",
                                                           .product(name: "Perception", package: "swift-perception")],
                    path: "app/Tests/ValseUITests"),
        .testTarget(name: "ValseAITests", dependencies: ["ValseAI", "ValseTestSupport"], path: "app/Tests/ValseAITests"),
        .testTarget(name: "ValsePerfTests", dependencies: ["ValseEngine", "ValseTestSupport"],
                    path: "app/Tests/ValsePerfTests"),
    ]
)
