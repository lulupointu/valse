import Foundation
import CoreGraphics
import MontageCore
import MontageEffects
import MontageEngine

/// `--demo`: builds a small project from synthetic media (no user files) that exercises every visible feature:
/// main-track clips with a transition, an overlay, text, a sticker, a filter clip and a music track.
public enum DemoProject {
    public static func make() async throws -> Project {
        let dir = MontagePaths.cacheDirectory.appendingPathComponent("demo-media-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func video(_ name: String, _ pattern: SyntheticMedia.Pattern, seconds: Double, hz: Double?) async throws -> URL {
            let u = dir.appendingPathComponent("\(name).mp4")
            if !FileManager.default.fileExists(atPath: u.path) {
                try await SyntheticMedia.writeVideo(to: u, size: CGSize(width: 1280, height: 720), seconds: seconds, fps: 30,
                                                    pattern: pattern, audioHz: hz)
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
        if !FileManager.default.fileExists(atPath: musicURL.path) { try await SyntheticMedia.writeAudio(to: musicURL, seconds: 12, hz: 220) }

        var p = Project(name: tr("demo.name"))
        let (assets, _) = await MediaProbe.probeAll(urls + [musicURL])
        p.media = assets
        for a in assets.prefix(3) {
            try TimelineOps.insert(TimelineOps.makeClip(for: a, at: Time(1000)), into: &p)
        }
        let main = p.timeline.mainTrack!.clips
        try TimelineOps.setTransition(main[0].id, Registries.transitions["montage.transition.dissolve"]!.makeInstance(), in: &p.timeline)
        // overlay picture-in-picture
        var o = TimelineOps.makeClip(for: assets[3], at: Time(2))
        o.transform = Transform(position: Vec2(0.28, -0.25), scale: Vec2(0.35, 0.35))
        o.animations.inAnim = AnimationInstance(typeID: "montage.anim.in.zoom")
        try TimelineOps.insert(o, into: &p, target: .newTrack)
        // title
        var t = TextContent(string: tr("demo.title"), fontSize: 0.09)
        Registries.textStyles["montage.text.outline"]!.apply(&t)
        var title = Clip(content: .text(t), start: Time(0.5), duration: Time(4))
        title.transform.position = Vec2(0, 0.3)
        title.animations.inAnim = AnimationInstance(typeID: "montage.anim.in.slideUp")
        try TimelineOps.insert(title, into: &p)
        // sticker
        var s = Clip(content: .sticker(id: "montage.sticker.sparkles"), start: Time(6), duration: Time(4))
        s.transform = Transform(position: Vec2(-0.32, -0.28), scale: Vec2(0.6, 0.6))
        s.animations.combo = AnimationInstance(typeID: "montage.anim.combo.pulse", duration: Time(1))
        try TimelineOps.insert(s, into: &p)
        // filter clip
        var f = Clip(content: .adjustment, start: Time(9), duration: Time(4))
        f.effects = [Registries.effects["montage.filter.warm"]!.makeInstance()]
        try TimelineOps.insert(f, into: &p, target: .newTrack)
        // music
        var m = TimelineOps.makeClip(for: assets[4], at: .zero)
        m.audio.volume = 0.5; m.audio.fadeOut = Time(1)
        try TimelineOps.insert(m, into: &p)
        return p
    }
}
