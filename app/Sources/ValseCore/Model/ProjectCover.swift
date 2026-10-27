import Foundation

/// The project cover (CapCut "Cover" at the main-track head, TL-045; text on cover, TX-036): a timeline frame or an
/// imported image, with optional text layers drawn by the normal text engine. Used for the export artwork / prepended
/// cover frame and the Home thumbnail.
public struct ProjectCover: Codable, Sendable, Equatable {
    /// Timeline time of the cover frame (used when `imagePath` is nil).
    public var time: Time
    /// Imported still image (absolute path); nil = a frame of the video.
    public var imagePath: String?
    /// Text layers on the cover: `.text` clips (content, transform, opacity); their start/duration are ignored.
    public var texts: [Clip]

    public init(time: Time = .zero, imagePath: String? = nil, texts: [Clip] = []) {
        self.time = time; self.imagePath = imagePath; self.texts = texts
    }

    /// True when the cover is just a frame of the timeline (no image, no text): the export can render it directly.
    public var isPlainFrame: Bool { imagePath == nil && texts.isEmpty }

    /// A one-frame project that renders the cover through the regular compositor, and the time to render.
    /// - `base`: the project (its frame at `time` is the background unless `image` is given).
    /// - `image`: the probed asset of `imagePath` (nil = use the timeline frame).
    public func compositionProject(base: Project, image: MediaAsset?) -> (project: Project, time: Time) {
        let frame = base.settings.frameRate.frameDuration
        var p: Project
        var t: Time
        if let image {
            p = Project(name: base.name, settings: base.settings)
            p.media = [image]
            var c = Clip(content: .media(image.id), start: .zero, duration: Time(1))
            // cover the canvas (CapCut fills the cover frame with the picture)
            let ca = base.settings.canvasSize, ia = image.pixelSize
            if ca.width > 0, ca.height > 0, ia.width > 0, ia.height > 0 {
                let fit = min(ca.width / ia.width, ca.height / ia.height), fill = max(ca.width / ia.width, ca.height / ia.height)
                c.transform.scale = Vec2(fill / fit, fill / fit)
            }
            p.timeline.tracks[p.timeline.mainTrackIndex ?? 0].clips = [c]
            t = .zero
        } else {
            p = base
            t = min(max(time, .zero), max(.zero, base.duration - frame))
        }
        if !texts.isEmpty {
            var track = Track(kind: .text)
            for var c in texts {
                c.start = t; c.duration = frame * 2; c.linkedTo = nil; c.keyframes = [:]
                c.animations = ClipAnimations()
                track.clips = [c]
                p.timeline.tracks.append(track)
                track = Track(kind: .text)
            }
        }
        return (p, t)
    }
}
