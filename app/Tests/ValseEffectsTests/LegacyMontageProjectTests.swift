import Foundation
import Testing
@testable import ValseCore
import ValseEffects

/// Projects saved before the Montage → Valse rename (`.montage` packages, built-in content IDs "montage.…", media in
/// `Application Support/Montage`) load identically: IDs resolve to the Valse items, moved media are found.
/// Fixture: app/Tests/UIScripts/fixtures/legacy/Old Film.montage (also used by scripts/updater_e2e.sh), written by
/// `VALSE_WRITE_LEGACY_FIXTURE=1 scripts/test.sh --filter LegacyMontageProjectTests` from `build()` below with every
/// "valse." ID turned into "montage." and the home folder replaced by `/__HOME__` (in plain and file-URL paths).
@Suite struct LegacyMontageProjectTests {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("UIScripts/fixtures/legacy/Old Film.montage", isDirectory: true)
    static let homeToken = "/__HOME__"
    static let files = [ProjectPackage.projectFileName, ProjectPackage.summaryFileName]

    /// A project using one built-in item of every kind, its picture pasted into Application Support/Montage.
    static func build(home: String) throws -> Project {
        var p = Project(name: "Old Film")
        let png = URL(fileURLWithPath: home + "/Library/Application Support/Montage/Pasted Media/legacy.png")
        let a = MediaAsset(name: "legacy", kind: .image, url: png, duration: .indefinite, pixelSize: Size2(64, 36),
                           frameRate: nil, hasVideo: true, hasAudio: false, contentHash: "legacy-fixture")
        p.media = [a]
        for _ in 0..<2 {
            var c = TimelineOps.makeClip(for: a, at: Time(1000))
            c.duration = Time(3)
            try TimelineOps.insert(c, into: &p)
        }
        let main = p.timeline.mainTrack!.clips
        try TimelineOps.setTransition(main[0].id, Registries.transitions["valse.transition.dissolve"]!.makeInstance(), in: &p.timeline)
        var first = p.timeline[clip: main[0].id]!
        first.effects = [Registries.effects["valse.effect.blur"]!.makeInstance(), Registries.effects["valse.filter.warm"]!.makeInstance()]
        first.animations.inAnim = AnimationInstance(typeID: "valse.anim.in.zoom")
        first.speed = .curve(SpeedCurvePreset.heroTime.curve)
        p.timeline[clip: main[0].id] = first
        var t = TextContent(string: "Titre", fontSize: 0.09)
        Registries.textStyles["valse.text.outline"]!.apply(&t)
        var title = Clip(content: .text(t), start: Time(0.5), duration: Time(2))
        title.animations.inAnim = AnimationInstance(typeID: "valse.anim.in.slideUp")
        try TimelineOps.insert(title, into: &p)
        var s = Clip(content: .sticker(id: "valse.sticker.sparkles"), start: Time(1), duration: Time(2))
        s.animations.combo = AnimationInstance(typeID: "valse.anim.combo.pulse", duration: Time(1))
        try TimelineOps.insert(s, into: &p)
        return p
    }

    /// Rewrites every string of a JSON file through `f`.
    static func mapStrings(_ src: URL, to dst: URL, _ f: (String) -> String) throws {
        func walk(_ v: Any) -> Any {
            switch v {
            case let s as String: return f(s)
            case let a as [Any]: return a.map(walk)
            case let d as [String: Any]: return Dictionary(uniqueKeysWithValues: d.map { (f($0.key), walk($0.value)) })
            default: return v
            }
        }
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: src))
        try JSONSerialization.data(withJSONObject: walk(obj), options: [.sortedKeys, .withoutEscapingSlashes]).write(to: dst)
    }

    static func fileURLPath(_ path: String) -> String { URL(fileURLWithPath: path).absoluteString.replacingOccurrences(of: "file://", with: "") }

    @Test func writeFixtureWhenAsked() throws {
        guard ProcessInfo.processInfo.environment["VALSE_WRITE_LEGACY_FIXTURE"] == "1" else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = dir.standardizedFileURL.path
        let pkg = dir.appendingPathComponent("Movies/Montage/Old Film.montage", isDirectory: true)
        try ProjectPackage.save(try Self.build(home: home), to: pkg)
        try? FileManager.default.removeItem(at: Self.fixture)
        try FileManager.default.createDirectory(at: Self.fixture, withIntermediateDirectories: true)
        let encodedHome = Self.fileURLPath(home).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for name in Self.files {
            try Self.mapStrings(pkg.appendingPathComponent(name), to: Self.fixture.appendingPathComponent(name)) { s in
                s.hasPrefix("valse.") && !s.contains(" ") && !s.contains("/") ? "montage." + s.dropFirst("valse.".count) : s
                    .replacingOccurrences(of: "/" + encodedHome, with: Self.homeToken)
                    .replacingOccurrences(of: home, with: Self.homeToken)
            }
        }
    }

    /// Copies the fixture into `home` (Movies/<folder>/Old Film.montage) with the home token resolved.
    static func install(home: URL, folder: String) throws -> URL {
        let pkg = home.appendingPathComponent("Movies/\(folder)/Old Film.montage", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        let h = home.standardizedFileURL.path
        let encoded = "/" + fileURLPath(h).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for name in files {
            try mapStrings(fixture.appendingPathComponent(name), to: pkg.appendingPathComponent(name)) { s in
                s.hasPrefix("file://") ? s.replacingOccurrences(of: homeToken, with: encoded) : s.replacingOccurrences(of: homeToken, with: h)
            }
        }
        return pkg
    }

    @Test func fixtureUsesOnlyOldIDs() throws {
        let s = try String(contentsOf: Self.fixture.appendingPathComponent(ProjectPackage.projectFileName), encoding: .utf8)
        #expect(s.contains("\"montage.effect.blur\"") && s.contains("\"montage.transition.dissolve\""))
        #expect(!s.contains("\"valse."))
        #expect(s.contains(Self.homeToken + "/Library/Application"))
    }

    @Test func oldProjectLoadsWithValseIDsAndMovedMedia() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        // as after the first-launch migration: folders renamed, the package itself still `.montage`
        let pkg = try Self.install(home: home, folder: "Valse")
        let moved = home.appendingPathComponent("Library/Application Support/Valse/Pasted Media/legacy.png")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("png".utf8).write(to: moved)

        let p = try ProjectPackage.load(from: pkg)
        #expect(p.media.first?.url.standardizedFileURL.path == moved.standardizedFileURL.path)
        let json = String(decoding: try ProjectPackage.encoder().encode(p), as: UTF8.self)
        #expect(!json.contains("\"montage."), "an old ID survived the load")

        let clips = p.timeline.tracks.flatMap(\.clips)
        let main = p.timeline.mainTrack!.clips
        #expect(main[0].effects.map(\.typeID) == ["valse.effect.blur", "valse.filter.warm"])
        #expect(main[0].effects.allSatisfy { Registries.effects[$0.typeID] != nil })
        #expect(main[0].transitionOut.map { Registries.transitions[$0.typeID] != nil } == true)
        #expect(main[0].animations.inAnim?.typeID == "valse.anim.in.zoom")
        if case .curve(let c) = main[0].speed { #expect(SpeedCurvePreset.preset(c.presetID)?.id == SpeedCurvePreset.heroTime.id) }
        else { Issue.record("speed curve lost") }
        let animIDs = clips.flatMap { [$0.animations.inAnim, $0.animations.outAnim, $0.animations.combo].compactMap { $0?.typeID } }
        #expect(animIDs.count >= 3 && animIDs.allSatisfy { Registries.animations[$0] != nil })
        #expect(clips.contains { if case .sticker(let id) = $0.content { return id == "valse.sticker.sparkles" }; return false })
        // the same project built today has the same clips and IDs
        let today = try Self.build(home: home.path)
        #expect(clips.count == today.timeline.tracks.flatMap(\.clips).count)
        #expect(Set(animIDs) == Set(today.timeline.tracks.flatMap(\.clips).flatMap {
            [$0.animations.inAnim, $0.animations.outAnim, $0.animations.combo].compactMap { $0?.typeID } }))
    }

    @Test func oldIDsStillResolveInTheRegistries() {
        #expect(Registries.effects["montage.effect.blur"]?.id == "valse.effect.blur")
        #expect(Registries.transitions["montage.transition.dissolve"]?.id == "valse.transition.dissolve")
        #expect(Registries.stickers["montage.sticker.sparkles"]?.id == "valse.sticker.sparkles")
        #expect(SpeedCurvePreset.preset("montage.speed.montage")?.id == SpeedCurvePreset.montage.id)
        #expect(Registries.effects["montage.nope"] == nil)
    }
}
