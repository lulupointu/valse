import Testing
import Foundation
@testable import MontageCore

@Suite struct PersistenceTests {
    func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("montage-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func roundTripIsLossless() throws {
        var (p, ids) = Fx.project(mainClips: 3)
        p.timeline[clip: ids[0]]!.speed = .curve(SpeedCurve(points: [SpeedPoint(0, 1), SpeedPoint(1, 2)], presetID: "x"))
        p.timeline[clip: ids[1]]!.effects = [EffectInstance(typeID: "f", params: ["a": .scalar(1), "c": .color(.red), "b": .bool(true)])]
        p.timeline[clip: ids[1]]!.mask = Mask(shape: .circle, feather: 0.2)
        p.timeline[clip: ids[2]]!.aiMovement = AIMovementOptions(preset: .shake, strength: 0.7, syncToBeats: false)
        p.timeline[clip: ids[2]]!.cameraLock = CameraLockOptions(target: .hand, keepSize: true)
        p.timeline[clip: ids[2]]!.relight = RelightSettings.preset(.creative)
        p.timeline[clip: ids[1]]!.keyframes[ParamKey.position.raw] = KeyframeTrack([
            Keyframe(time: 0, value: .vec2(.zero), easing: .bezier(x1: 0.1, y1: 0.2, x2: 0.3, y2: 1.4)),
            Keyframe(time: 1, value: .vec2(Vec2(0.5, 0.1)), easing: .hold)])
        try TimelineOps.setTransition(ids[0], TransitionInstance(typeID: "t", duration: 0.5), in: &p.timeline)
        try TimelineOps.insert(Clip(content: .text(TextContent(string: "Bonjour é ✨")), start: 1, duration: 2), into: &p)
        // speaker-tagged caption + project speakers (AI-005)
        var cap = TextContent(string: "Salut")
        cap.caption = CaptionData(words: [CaptionWord("Salut", start: 0, end: 0.5)], speaker: "2", origin: .auto)
        try TimelineOps.insert(Clip(content: .text(cap), start: 4, duration: 1), into: &p)
        p.speakers = [CaptionSpeaker(id: "1", name: "Alice", color: .white), CaptionSpeaker(id: "2", color: RGBA(hex: 0xFFE14D))]
        let dir = tempDir()
        let url = dir.appendingPathComponent("A.montage")
        try ProjectPackage.save(p, to: url)
        let q = try ProjectPackage.load(from: url)
        // relativePath is filled on save; compare the rest
        var p2 = p; for i in p2.media.indices { p2.media[i].relativePath = q.media[i].relativePath }
        #expect(q == p2)
        #expect(q.schemaVersion == Project.currentSchemaVersion)
    }

    @Test func rejectsNewerSchemaAndMissingPackage() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("B.montage")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #expect(throws: PersistenceError.notAPackage) { try ProjectPackage.load(from: dir.appendingPathComponent("none.montage")) }
        let json = #"{"schemaVersion": 999}"#
        try json.write(to: url.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)
        #expect(throws: PersistenceError.newerSchema(999)) { try ProjectPackage.load(from: url) }
    }

    @Test func relinksMovedMediaThroughRelativePath() throws {
        let dir = tempDir()
        let media = dir.appendingPathComponent("clip.mp4")
        try Data([1, 2, 3]).write(to: media)
        var p = Project(name: "R")
        var a = Fx.video("clip"); a.url = media
        p.media = [a]
        let pkg = dir.appendingPathComponent("R.montage")
        try ProjectPackage.save(p, to: pkg)
        // move both to a new folder
        let dir2 = tempDir()
        try FileManager.default.moveItem(at: pkg, to: dir2.appendingPathComponent("R.montage"))
        try FileManager.default.moveItem(at: media, to: dir2.appendingPathComponent("clip.mp4"))
        let q = try ProjectPackage.load(from: dir2.appendingPathComponent("R.montage"))
        #expect(q.media[0].url.standardizedFileURL.path == dir2.appendingPathComponent("clip.mp4").standardizedFileURL.path)
    }

    @Test func sessionLockDetectsCrash() throws {
        let pkg = tempDir().appendingPathComponent("L.montage")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        #expect(SessionLock.acquire(pkg) == false)
        // simulate a lock from a dead process
        try "999999".write(to: pkg.appendingPathComponent(".session.lock"), atomically: true, encoding: .utf8)
        #expect(SessionLock.acquire(pkg) == true)
        SessionLock.release(pkg)
        #expect(!FileManager.default.fileExists(atPath: pkg.appendingPathComponent(".session.lock").path))
    }
}

@Suite struct LocalizationTests {
    @Test func englishAndFrenchTablesLoad() {
        let l = L10n.shared
        let en = L10n.load("en", from: [CoreResources.bundle]), fr = L10n.load("fr", from: [CoreResources.bundle])
        #expect(en["cmd.split"] == "Split")
        #expect(Set(fr.keys) == Set(en.keys))
        // The session language is process-global and UI-test suites switch it in parallel: retry the switch a few
        // times so a concurrent flip by another suite doesn't fail this check (seen in check_clean).
        func switches(_ lang: String, _ expected: String) -> Bool {
            for _ in 0..<50 {
                l.setLanguageForSession(lang)
                if tr("cmd.split") == expected { return true }
                usleep(2_000)
            }
            return false
        }
        #expect(switches("fr", "Fractionner"))
        #expect(switches("en", "Split"))
        #expect(tr("no.such.key") == "no.such.key")
    }
}

@Suite struct EvaluatorTests {
    @Test func layersInTrackOrderWithResolvedKeyframes() throws {
        var (p, ids) = Fx.project(mainClips: 2)
        var text = Clip(content: .text(TextContent(string: "A")), start: 0, duration: 8)
        text.keyframes[ParamKey.opacity.raw] = KeyframeTrack([Keyframe(time: 0, value: .scalar(0)), Keyframe(time: 2, value: .scalar(1))])
        try TimelineOps.insert(text, into: &p)
        let f = FrameEvaluator.evaluate(p, at: 1)
        #expect(f.items.count == 2)
        guard case .layer(let base) = f.items[0], case .layer(let top) = f.items[1] else { Issue.record("bad items"); return }
        #expect(base.clipID == ids[0])
        #expect(top.opacity == 0.5)
        if case .media(_, let st) = base.source { #expect(st == Time(1)) } else { Issue.record("not media") }
    }

    @Test func geometryFitsAndRotates() {
        let g = LayerGeometry(sourceSize: Size2(1000, 1000), canvasSize: Size2(1920, 1080), transform: Transform())
        #expect(g.halfSize == Vec2(540, 540))
        #expect(g.contains(Vec2(960, 540)) && !g.contains(Vec2(100, 540)))
        var t = Transform(); t.rotation = 90; t.position = Vec2(0.25, 0)
        let r = LayerGeometry(sourceSize: Size2(1920, 1080), canvasSize: Size2(1920, 1080), transform: t)
        #expect(abs(r.center.x - 1440) < 1e-9)
        #expect(abs(r.corners[0].x - (1440 + 540)) < 1e-6)
    }
}
