import Testing
import Foundation
import AppKit
import ValseCore
import ValseEffects
import ValseEngine
import ValseAI
@testable import ValseUI

/// macOS 13 draws NOTHING for an SF Symbol newer than SF Symbols 4. Enforces the deployment floor for every symbol name
/// (static literals via scripts/check_sf_symbols.py, registry symbols at runtime) and checks `SFSymbolCompat`.
@MainActor
struct SFSymbolAvailabilityTests {
    static let resources = "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources"
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// symbol → first macOS version (from the host's CoreGlyphs availability table; old spellings resolve via aliases).
    static let firstMacOS: [String: String] = {
        guard let av = NSDictionary(contentsOfFile: "\(resources)/name_availability.plist") as? [String: Any],
              let symbols = av["symbols"] as? [String: String],
              let releases = av["year_to_release"] as? [String: [String: String]] else { return [:] }
        let aliases = NSDictionary(contentsOfFile: "\(resources)/name_aliases.strings") as? [String: String] ?? [:]
        var out: [String: String] = [:]
        for (name, year) in symbols { out[name] = releases[year]?["macOS"] }
        for (old, new) in aliases where out[old] == nil { out[old] = out[new] }
        return out
    }()

    static func onMacOS13(_ name: String) -> Bool {
        guard let v = firstMacOS[name] else { return false }
        return v.split(separator: ".").compactMap { Int($0) }.lexicographicallyPrecedes([13, 0, 1])
    }

    @Test func sourceLiteralsPassTheScript() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", Self.repoRoot.appendingPathComponent("scripts/check_sf_symbols.py").path]
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        try p.run(); p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(p.terminationStatus == 0, "\(text)")
    }

    @Test func registrySymbolsExistOnMacOS13() {
        #expect(!Self.firstMacOS.isEmpty, "CoreGlyphs availability table not found")
        var names: [(String, String)] = []
        names += Registries.effects.all.map { ("effect \($0.id)", $0.symbol) }
        names += Registries.transitions.all.map { ("transition \($0.id)", $0.symbol) }
        names += Registries.animations.all.map { ("animation \($0.id)", $0.symbol) }
        names += VoiceEffects.all.map { ("voice \($0.id)", $0.symbol) }
        names += AIRegistry.tools.all.map { ("ai tool \($0.id)", $0.symbol) }
        names += AssetTabRegistry.tabs.map { ("asset tab \($0.id)", $0.symbol) }
        names += AIMovementOptions.Preset.allCases.map { ("ai movement \($0.rawValue)", $0.symbol) }
        #expect(names.count > 200)
        for (owner, name) in names where !name.isEmpty {
            let on13 = SFSymbolCompat.macOS13Name(name)
            #expect(Self.onMacOS13(on13), "\(owner): '\(on13)' does not exist on macOS 13 (renders nothing)")
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(owner): '\(name)' unknown here")
        }
    }

    @Test func compatFallbacksAndOldSpellings() {
        for (name, fallback) in SFSymbolCompat.fallbacks {
            #expect(!Self.onMacOS13(name), "'\(name)' exists on 13: drop its fallback")
            #expect(Self.onMacOS13(fallback), "fallback '\(fallback)' for '\(name)' is not on macOS 13")
            #expect(NSImage(systemSymbolName: fallback, accessibilityDescription: nil) != nil)
            #expect(SFSymbolCompat.compat(name) == name, "macOS 14+ keeps the original glyph")
        }
        // Renamed glyphs written with their old spelling must still resolve on current systems.
        for old in ["speedometer", "waveform.and.magnifyingglass", "point.topleft.down.curvedto.point.bottomright.up"] {
            #expect(Self.onMacOS13(old))
            #expect(NSImage(systemSymbolName: old, accessibilityDescription: nil) != nil, "'\(old)' no longer resolves")
        }
    }
}
