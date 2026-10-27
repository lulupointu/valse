import Foundation
import CoreGraphics
import ValseCore
import ValseEffects
import ValseEngine

/// `--demo`: builds a small project from synthetic media (no user files) that exercises every visible feature:
/// main-track clips with a transition, an overlay, text, a sticker, a filter clip and a music track.
public enum DemoProject {
    /// Runs a synthetic-media write up to 5 times, waiting 0.25 / 0.5 / 1 / 2 s between attempts (a transient encoder or
    /// IOSurface failure on a loaded machine clears in a moment; a second back-to-back attempt often hit it too).
    static func withEncoderRetries(_ write: () async throws -> Void) async throws {
        var delay: UInt64 = 250_000_000
        for _ in 0..<4 {
            do { try await write(); return } catch {
                try await Task.sleep(nanoseconds: delay)
                delay *= 2
            }
        }
        try await write()
    }

    /// Where the demo media is built: `VALSE_UITEST_SHARED_MEDIA` (set by scripts/uitest.sh to a folder of its private
    /// TMPDIR) is shared by every app of one UI-test run, so the media is encoded once per run instead of once per
    /// script launch (FLAKY-SYS-UI: each launch encoding 5 files while the machine is loaded was the setup failure class
    /// of FLAKY-FIN `Code=62` / FLAKY-UI2's SIGSEGV in the pixel-buffer pool). The files are only read once written
    /// (written to a temp name, moved in atomically; a concurrent app that lost the race keeps the winner's file).
    static var mediaDirectory: URL {
        if let s = ProcessInfo.processInfo.environment["VALSE_UITEST_SHARED_MEDIA"], !s.isEmpty {
            return URL(fileURLWithPath: s, isDirectory: true).appendingPathComponent("demo-media-v1", isDirectory: true)
        }
        return ValsePaths.cacheDirectory.appendingPathComponent("demo-media-v1", isDirectory: true)
    }

    /// Moves a finished temp file to `u`, unless another process put it there first (then that one is kept: same content).
    private static func install(_ tmp: URL, at u: URL) throws {
        do { try FileManager.default.moveItem(at: tmp, to: u) } catch {
            if FileManager.default.fileExists(atPath: u.path) { return }
            throw error
        }
    }

    public static func make() async throws -> Project {
        let dir = mediaDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func video(_ name: String, _ pattern: SyntheticMedia.Pattern, seconds: Double, hz: Double?) async throws -> URL {
            let u = dir.appendingPathComponent("\(name).mp4")
            if !FileManager.default.fileExists(atPath: u.path) {
                // atomic (a failed / interrupted write never leaves a partial file that later runs take as done), and
                // retried with backoff: the encoder can fail under heavy load (SyntheticMedia then throws instead of
                // hanging). One immediate retry was not enough: every UI-test launch builds this media in its own
                // cache, and a busy machine failed both back-to-back attempts (FLAKY-FIN, setup "Code=62").
                let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).mp4")
                defer { try? FileManager.default.removeItem(at: tmp) }
                try await withEncoderRetries {
                    try await SyntheticMedia.writeVideo(to: tmp, size: CGSize(width: 1280, height: 720), seconds: seconds, fps: 30,
                                                        pattern: pattern, audioHz: hz)
                }
                try install(tmp, at: u)
            }
            return u
        }
        let urls = [
            try await video(tr("demo.clip.ocean"), .movingBox(RGBA(hex: 0x1C5D8A), RGBA(hex: 0xF5F1E3)), seconds: 6, hz: 330),
            try await video(tr("demo.clip.sunset"), .movingBox(RGBA(hex: 0xC2562F), RGBA(hex: 0xFFD27A)), seconds: 5, hz: 440),
            try await video(tr("demo.clip.forest"), .movingBox(RGBA(hex: 0x2F6B3A), RGBA(hex: 0xD8F0C8)), seconds: 6, hz: 550),
            try await video(tr("demo.clip.overlay"), .split(RGBA(hex: 0x8E44AD), RGBA(hex: 0x57BECB)), seconds: 4, hz: nil),
        ]
        let musicURL = dir.appendingPathComponent("\(tr("demo.clip.music")).m4a")
        if !FileManager.default.fileExists(atPath: musicURL.path) {
            let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try await withEncoderRetries { try await SyntheticMedia.writeAudio(to: tmp, seconds: 12, hz: 220) }
            try install(tmp, at: musicURL)
        }

        var p = Project(name: tr("demo.name"))
        let (assets, _) = await MediaProbe.probeAll(urls + [musicURL])
        p.media = assets
        for a in assets.prefix(3) {
            try TimelineOps.insert(TimelineOps.makeClip(for: a, at: Time(1000)), into: &p)
        }
        let main = p.timeline.mainTrack!.clips
        try TimelineOps.setTransition(main[0].id, Registries.transitions["valse.transition.dissolve"]!.makeInstance(), in: &p.timeline)
        // overlay picture-in-picture
        var o = TimelineOps.makeClip(for: assets[3], at: Time(2))
        o.transform = Transform(position: Vec2(0.28, -0.25), scale: Vec2(0.35, 0.35))
        o.animations.inAnim = AnimationInstance(typeID: "valse.anim.in.zoom")
        try TimelineOps.insert(o, into: &p, target: .newTrack)
        // title
        var t = TextContent(string: tr("demo.title"), fontSize: 0.09)
        Registries.textStyles["valse.text.outline"]!.apply(&t)
        var title = Clip(content: .text(t), start: Time(0.5), duration: Time(4))
        title.transform.position = Vec2(0, 0.3)
        title.animations.inAnim = AnimationInstance(typeID: "valse.anim.in.slideUp")
        try TimelineOps.insert(title, into: &p)
        // sticker
        var s = Clip(content: .sticker(id: "valse.sticker.sparkles"), start: Time(6), duration: Time(4))
        s.transform = Transform(position: Vec2(-0.32, -0.28), scale: Vec2(0.6, 0.6))
        s.animations.combo = AnimationInstance(typeID: "valse.anim.combo.pulse", duration: Time(1))
        try TimelineOps.insert(s, into: &p)
        // filter clip
        var f = Clip(content: .adjustment, start: Time(9), duration: Time(4))
        f.effects = [Registries.effects["valse.filter.warm"]!.makeInstance()]
        try TimelineOps.insert(f, into: &p, target: .newTrack)
        // music
        var m = TimelineOps.makeClip(for: assets[4], at: .zero)
        m.audio.volume = 0.5; m.audio.fadeOut = Time(1)
        m.beats = stride(from: 1.0, to: 12, by: 2).map { Time($0) }
        try TimelineOps.insert(m, into: &p)
        _ = try TimelineOps.addMarker(at: Time(8), in: &p.timeline)
        return p
    }
}
