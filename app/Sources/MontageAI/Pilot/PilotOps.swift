import Foundation
import NaturalLanguage
import MontageCore
import MontageEffects

/// Inputs an EditPilot step may need, gathered by `EditPilotExecutor` before applying (analysis results are per media,
/// in media time, so they stay valid while earlier steps cut / retime the timeline).
public struct PilotContext: Sendable {
    public var selection: Set<ClipID> = []
    public var activity: [MediaID: ActivityProfile] = [:]
    /// Transcripts with disfluencies kept (used for filler removal and captions).
    public var transcripts: [MediaID: Transcript] = [:]
    /// Integrated loudness per clip (LUFS) for "normalize loudness".
    public var loudness: [ClipID: Double] = [:]
    public init() {}
}

/// The pure part of every EditPilot action: `apply` mutates a project (no I/O, no models) and returns a localized
/// result line ("4 silences removed (−6.2 s)"), or nil when nothing changed. Async inputs come from `PilotContext`.
public enum PilotOps {
    public static func apply(_ a: PilotAction, to p: inout Project, context ctx: PilotContext) throws -> String? {
        switch a {
        case .removeSilences(let m): return try removeSilences(minPause: m, in: &p, ctx)
        case .addCaptions(let lang, _): return addCaptions(language: lang, in: &p, ctx)
        case .highlightKeywords: return nil   // async (language model), done by the executor
        case .setAspect(let r, let fill): return setAspect(r, fill: fill, in: &p)
        case .setSpeed(let f, let s): return try setSpeed(f, clips: targets(s, p, ctx, visual: true), in: &p)
        case .speedUpQuiet(let f): return try speedUpQuiet(factor: f, in: &p, ctx)
        case .addTransitions(let id, let d): return try addTransitions(id, duration: d, in: &p)
        case .applyFilter(let id, let i, let s): return applyEffect(id, intensity: i, clips: targets(s, p, ctx, visual: true), in: &p)
        case .applyEffect(let id, let s): return applyEffect(id, intensity: nil, clips: targets(s, p, ctx, visual: true), in: &p)
        case .fade(let s): return fade(seconds: s, in: &p)
        case .volume(let db, let s): return volume(db: db, clips: targets(s, p, ctx, visual: false), in: &p)
        case .mute(let s):
            return audio(targets(s, p, ctx, visual: false), in: &p, key: "pilot.result.mute") { $0.isMuted = true }
        case .reduceNoise(let s):
            return audio(targets(s, p, ctx, visual: false), in: &p, key: "pilot.result.reduceNoise") { $0.noiseReduction = $0.noiseReduction ?? 0.6 }
        case .enhanceVoice(let s):
            return audio(targets(s, p, ctx, visual: false), in: &p, key: "pilot.result.enhanceVoice") { $0.enhanceVoice = $0.enhanceVoice ?? 0.7 }
        case .normalizeLoudness(let s): return normalize(targets(s, p, ctx, visual: false), in: &p, ctx)
        case .addTitle(let text, let s): return try addTitle(text, seconds: s, in: &p)
        case .fitDuration(let s): return try fitDuration(s, in: &p)
        case .stabilize(let s):
            let ids = targets(s, p, ctx, visual: true).filter { id in p.timeline.clip(id).flatMap(\.mediaID).flatMap(p.asset)?.kind == .video }
            for id in ids where p.timeline.clip(id)?.stabilization == nil { p.timeline[clip: id]?.stabilization = Stabilization() }
            return ids.isEmpty ? nil : tr("pilot.result.clips", ids.count)
        }
    }

    // MARK: Targets

    /// Clips an action applies to: the selection when asked for (and non-empty), else every main-track clip
    /// (`visual`) or every enabled clip with audio.
    static func targets(_ s: PilotScope, _ p: Project, _ ctx: PilotContext, visual: Bool) -> [ClipID] {
        let tl = p.timeline
        func ok(_ c: Clip) -> Bool {
            guard c.isEnabled, let kind = tl.locate(c.id).map({ tl.tracks[$0.track].kind }) else { return false }
            if visual { return kind != .audio && c.mediaID != nil }
            guard let a = c.mediaID.flatMap(p.asset) else { return false }
            return a.hasAudio
        }
        if s == .selected, !ctx.selection.isEmpty {
            return tl.allClips.filter { ctx.selection.contains($0.id) && ok($0) }.map(\.id)
        }
        if visual { return (tl.mainTrack?.clips ?? []).filter(ok).map(\.id) }
        return tl.allClips.filter(ok).map(\.id)
    }

    static func mainMediaClips(_ p: Project) -> [Clip] {
        (p.timeline.mainTrack?.clips ?? []).filter { $0.mediaID != nil && !$0.reversed && !$0.isFreezeFrame && $0.isEnabled }
    }

    static func timelineRange(_ r: TimeRange, in c: Clip) -> TimeRange? {
        guard let a = c.timelineTime(forSource: r.start), let b = c.timelineTime(forSource: r.end), b > a else { return nil }
        return TimeRange(start: a, end: b)
    }

    // MARK: Cuts

    static func removeSilences(minPause: Double, in p: inout Project, _ ctx: PilotContext) throws -> String? {
        var ranges: [TimeRange] = []
        for c in mainMediaClips(p) {
            guard let mid = c.mediaID, let prof = ctx.activity[mid] else { continue }
            ranges += prof.silences(minimum: minPause, in: c.sourceRange).compactMap { timelineRange($0, in: c) }
        }
        guard !ranges.isEmpty else { return nil }
        let before = p.timeline.duration
        try TranscriptEditing.rippleDelete(ranges, in: &p)
        return tr("pilot.result.removeSilences", ranges.count, PilotFormat.seconds((before - p.timeline.duration).seconds))
    }

    // MARK: Timing

    static func setSpeed(_ factor: Double, clips: [ClipID], in p: inout Project) throws -> String? {
        var n = 0
        for id in clips {
            guard let c = p.timeline.clip(id), !c.isFreezeFrame, c.speed != .constant(factor) else { continue }
            try TimelineOps.setSpeed(id, .constant(factor), in: &p.timeline)
            n += 1
        }
        return n == 0 ? nil : tr("pilot.result.clips", n)
    }

    static func speedUpQuiet(factor: Double, in p: inout Project, _ ctx: PilotContext) throws -> String? {
        let before = p.timeline.duration
        var parts = 0
        // right to left so the remaining clips keep their timeline positions while we split
        for c in mainMediaClips(p).reversed() {
            guard let mid = c.mediaID, let prof = ctx.activity[mid], case .constant(let v) = c.speed else { continue }
            let runs = prof.boringRuns(minimum: 1.5, in: c.sourceRange).compactMap { timelineRange($0, in: c) }
            for r in runs.reversed() {
                guard let cur = p.timeline.clip(c.id) ?? p.timeline.mainTrack?.clips.first(where: { $0.range.contains(r.start) }) else { continue }
                var target = cur.id
                let minD = TimelineOps.minimumClipDuration
                if r.end - cur.start >= minD, cur.end - r.end >= minD { _ = try TimelineOps.split(target, at: r.end, in: &p.timeline) }
                if let piece = p.timeline.clip(target), r.start - piece.start >= minD, piece.end - r.start >= minD {
                    target = try TimelineOps.split(target, at: r.start, in: &p.timeline)
                }
                guard let piece = p.timeline.clip(target), piece.start >= r.start - minD, piece.end <= r.end + minD else { continue }
                try TimelineOps.setSpeed(target, .constant(min(v * factor, 100)), in: &p.timeline)
                parts += 1
            }
        }
        guard parts > 0 else { return nil }
        return tr("pilot.result.speedUpQuiet", parts, PilotFormat.seconds((before - p.timeline.duration).seconds))
    }

    static func fitDuration(_ seconds: Double, in p: inout Project) throws -> String? {
        let total = p.timeline.duration.seconds
        guard total > 0.1, abs(total - seconds) / seconds > 0.02 else { return nil }
        for _ in 0..<3 {   // transitions don't scale: refine twice
            let cur = p.timeline.duration.seconds
            guard abs(cur - seconds) / seconds > 0.01 else { break }
            let step = cur / seconds
            for c in p.timeline.mainTrack?.clips ?? [] where !c.isFreezeFrame {
                guard case .constant(let v) = c.speed else { continue }
                try TimelineOps.setSpeed(c.id, .constant(min(max(v * step, 0.1), 100)), in: &p.timeline)
            }
        }
        return tr("pilot.result.fitDuration", PilotFormat.duration(total), PilotFormat.duration(p.timeline.duration.seconds))
    }

    // MARK: Structure & looks

    static func setAspect(_ ratio: String, fill: Bool, in p: inout Project) -> String? {
        guard let size = ProjectSettings.presetSize(ratio) else { return nil }
        let changed = p.settings.canvasSize != size
        p.settings.canvasSize = size
        p.settings.aspectPreset = ratio
        var filled = 0
        if fill {
            for i in p.timeline.tracks.indices where p.timeline.tracks[i].kind == .video {
                for j in p.timeline.tracks[i].clips.indices {
                    let c = p.timeline.tracks[i].clips[j]
                    guard p.timeline.tracks[i].isMain, let a = c.mediaID.flatMap(p.asset), a.kind != .audio,
                          c.keyframes[ParamKey.scale.raw] == nil, c.reframe == nil, c.cameraLock == nil else { continue }
                    let s = a.pixelSize
                    guard s.width > 0, s.height > 0 else { continue }
                    let fit = min(size.width / s.width, size.height / s.height), cover = max(size.width / s.width, size.height / s.height)
                    let k = cover / fit
                    p.timeline.tracks[i].clips[j].transform.scale = Vec2(k, k)
                    p.timeline.tracks[i].clips[j].transform.position = .zero
                    filled += 1
                }
            }
        }
        guard changed || filled > 0 else { return nil }
        return filled > 0 ? tr("pilot.result.aspectFill", ratio, filled) : tr("pilot.result.aspect", ratio)
    }

    static func addTransitions(_ typeID: String, duration: Double, in p: inout Project) throws -> String? {
        guard let d = Registries.transitions[typeID] ?? Registries.transitions[PilotCatalog.defaultTransition],
              let main = p.timeline.mainTrack else { return nil }
        var n = 0
        for c in main.clips.dropLast() {
            guard TimelineOps.transitionIssue(after: c.id, in: p.timeline) == nil else { continue }
            var inst = d.makeInstance()
            inst.duration = Time(duration)
            try TimelineOps.setTransition(c.id, inst, in: &p.timeline)
            n += 1
        }
        return n == 0 ? nil : tr("pilot.result.transitions", n)
    }

    static func applyEffect(_ typeID: String, intensity: Double?, clips: [ClipID], in p: inout Project) -> String? {
        guard let d = Registries.effects[typeID], !clips.isEmpty else { return nil }
        for id in clips {
            guard var c = p.timeline.clip(id) else { continue }
            if d.category == .filter { c.effects.removeAll { Registries.effects[$0.typeID]?.category == .filter } }
            var inst = d.makeInstance()
            if let intensity, let spec = d.params.first(where: { ["intensity", "strength", "amount", "mix"].contains($0.key) }),
               case .scalar(let lo, let hi, _) = spec.kind {
                inst.params[spec.key] = .scalar(lo + (hi - lo) * intensity / 100)
            }
            c.effects.append(inst)
            p.timeline[clip: id] = c
        }
        return tr("pilot.result.clips", clips.count)
    }

    static func fade(seconds: Double, in p: inout Project) -> String? {
        guard let main = p.timeline.mainTrack, let first = main.clips.first, let last = main.clips.last else { return nil }
        let d = Time(seconds)
        p.timeline[clip: first.id]?.animations.inAnim = AnimationInstance(typeID: "montage.anim.in.fade", duration: min(d, first.duration))
        p.timeline[clip: first.id]?.animations.combo = nil
        p.timeline[clip: last.id]?.animations.outAnim = AnimationInstance(typeID: "montage.anim.out.fade", duration: min(d, last.duration))
        p.timeline[clip: last.id]?.animations.combo = nil
        // audio: every clip touching the start / the end of the video
        let end = p.timeline.duration
        for c in p.timeline.allClips where c.mediaID.flatMap(p.asset)?.hasAudio == true {
            if c.start <= Time(0.05) { p.timeline[clip: c.id]?.audio.fadeIn = min(d, c.duration) }
            if c.end >= end - Time(0.05) { p.timeline[clip: c.id]?.audio.fadeOut = min(d, c.duration) }
        }
        return tr("pilot.result.fade")
    }

    // MARK: Audio

    static func volume(db: Double, clips: [ClipID], in p: inout Project) -> String? {
        let k = pow(10, db / 20)
        return audio(clips, in: &p, key: "pilot.result.volume") { $0.volume = min(max($0.volume * k, 0), 10); $0.isMuted = false }
    }

    static func audio(_ clips: [ClipID], in p: inout Project, key: String, _ body: (inout AudioProps) -> Void) -> String? {
        guard !clips.isEmpty else { return nil }
        for id in clips { if var a = p.timeline.clip(id)?.audio { body(&a); p.timeline[clip: id]?.audio = a } }
        return tr(key, clips.count)
    }

    static func normalize(_ clips: [ClipID], in p: inout Project, _ ctx: PilotContext) -> String? {
        var n = 0
        for id in clips {
            guard let l = ctx.loudness[id], let c = p.timeline.clip(id) else { continue }
            p.timeline[clip: id]?.audio.loudness = LoudnessNormalization(targetLUFS: -14, measuredLUFS: l, measuredRange: c.sourceRange)
            n += 1
        }
        return n == 0 ? nil : tr("pilot.result.normalize", n)
    }

    // MARK: Text

    /// Dominant language of the captions' text (NaturalLanguage), nil without captions.
    public static func captionLanguage(_ tl: Timeline) -> String? {
        let text = SpeechCaptions.captions(in: tl).prefix(30).compactMap { CaptionOps.text($0)?.string }.joined(separator: " ")
        guard !text.isEmpty else { return nil }
        let r = NLLanguageRecognizer()
        r.processString(text)
        return r.dominantLanguage?.rawValue
    }

    /// Captions from the gathered transcripts on the current timeline (every audible media clip), replacing earlier
    /// auto captions. Filler words are left out of the caption text.
    static func addCaptions(language: String?, in p: inout Project, _ ctx: PilotContext) -> String? {
        var settings = CaptionSettings()
        settings.removeFillers = true
        var segments: [CaptionSegment] = []
        for c in CaptionGenerator.sourceClips(p, .allTracks) {
            guard let t = c.mediaID.flatMap({ ctx.transcripts[$0] }), !t.words.isEmpty else { continue }
            segments += SpeechCaptions.segments(t, for: c, settings: settings)
        }
        guard !segments.isEmpty else { return nil }
        guard let id = CaptionOps.addCaptionTrack(segments, to: &p, origin: .auto, replacing: true) else { return nil }
        SpeechCaptions.finish(trackID: id, in: &p)
        return tr("pilot.result.captions", segments.count)
    }

    static func addTitle(_ text: String, seconds: Double, in p: inout Project) throws -> String? {
        var t = TextContent(string: text, fontSize: 0.09)
        t.bold = true
        var c = Clip(content: .text(t), start: .zero, duration: Time(min(seconds, max(p.timeline.duration.seconds, seconds))))
        c.transform.position = Vec2(0, -0.05)
        c.animations.inAnim = AnimationInstance(typeID: "montage.anim.in.fade", duration: Time(0.4))
        c.animations.outAnim = AnimationInstance(typeID: "montage.anim.out.fade", duration: Time(0.4))
        let track = TimelineOps.addTrack(.text, to: &p.timeline)
        try TimelineOps.insert(c, into: &p, target: .track(track))
        return tr("pilot.result.title")
    }

    /// Marks keywords (from the language model / statistical picker) on the auto captions with the karaoke keyword
    /// style, like Captions ▸ Highlight keywords.
    static func markKeywords(_ keys: Set<String>, in p: inout Project) -> String? {
        let n = SpeechCaptions.markKeywords(keys, in: &p.timeline)
        guard n > 0 else { return nil }
        for ti in p.timeline.tracks.indices where CaptionOps.isCaptionTrack(p.timeline.tracks[ti]) {
            for i in p.timeline.tracks[ti].clips.indices {
                guard case .text(var t) = p.timeline.tracks[ti].clips[i].content, t.karaoke == nil else { continue }
                t.karaoke = KaraokeStyle(mode: .highlightWord, highlightColor: t.color, highlightScale: 1)
                p.timeline.tracks[ti].clips[i].content = .text(t)
            }
        }
        return tr("pilot.result.keywords", keys.count)
    }
}
