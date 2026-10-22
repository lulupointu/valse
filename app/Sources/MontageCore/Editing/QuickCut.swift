import Foundation

/// A clip Quick cut works on, with the clips that play its sound.
/// `primary` is the clip whose footprint is cut. `members` = `primary` + the audio clips extracted from it
/// ("Extract audio", `Clip.extractedFrom`): what the user hears of a video whose audio was detached is that audio clip,
/// so the blanks come from every audible member and the cuts apply to all of them together.
public struct QuickCutTarget: Sendable, Equatable, Hashable {
    public var primary: ClipID
    public var members: [ClipID]
    public init(primary: ClipID, members: [ClipID]) { self.primary = primary; self.members = members }
}

/// What Quick cut will remove for one max-blank value (pure result of `QuickCut.plan`, recomputed on every slider change).
public struct QuickCutPlan: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public var target: QuickCutTarget
        /// The primary is on the main track: its cuts ripple the main track.
        public var onMainTrack: Bool
        /// Removed slices, timeline time, sorted, inside the primary's footprint.
        public var slices: [TimeRange]
    }

    public var maxBlank: Double
    /// Targets with at least one slice.
    public var items: [Item]
    /// Media still to analyse (targets that need them are left out of `items` until their mask is passed in).
    public var pending: Set<MediaID>
    /// Removed slices per clip (members included), clipped to each clip's footprint: what the timeline draws.
    public var slicesByClip: [ClipID: [TimeRange]]

    /// Number of blanks removed.
    public var count: Int { items.reduce(0) { $0 + $1.slices.count } }
    /// Total time removed.
    public var removed: Time { items.reduce(Time.zero) { acc, i in i.slices.reduce(acc) { $0 + $1.duration } } }
    public var isEmpty: Bool { items.isEmpty }
    public func slices(for clip: ClipID) -> [TimeRange] { slicesByClip[clip] ?? [] }

    public init(maxBlank: Double, items: [Item] = [], pending: Set<MediaID> = [], slicesByClip: [ClipID: [TimeRange]] = [:]) {
        self.maxBlank = maxBlank; self.items = items; self.pending = pending; self.slicesByClip = slicesByClip
    }
}

/// Quick cut (TL-048, docs/QUICK_CUT.md): removes the blanks of audio / video clips from a per-media speech mask.
/// Pure (no I/O): `targets` → `plan` (fast, every slider change) → `apply` (one edit, `ApplyQuickCut`).
public enum QuickCut {
    /// Handles kept around speech (s): before the next speech / after the previous one (§4 "Per clip").
    public static let handleBefore = 0.06
    public static let handleAfter = 0.14
    /// Slices shorter than this are not removed.
    public static let minimumSlice = 0.04
    /// Effective gain at or below this (−40 dB) is inaudible: blank.
    public static let inaudibleGain = 0.01
    /// Slider range (s).
    public static let maxBlankRange: ClosedRange<Double> = 0.1...5

    // MARK: Targets

    /// No selection = every audio / video clip with audio on any track; otherwise the selected ones. A video whose audio
    /// was extracted is grouped with its extracted audio clip(s) (selecting either one targets both).
    /// Disabled clips, locked tracks, images, freeze frames and media without audio are left out.
    public static func targets(_ project: Project, selection: Set<ClipID>) -> [QuickCutTarget] {
        let tl = project.timeline
        let lookup = MediaLookup(project.media)
        func eligible(_ c: Clip, _ t: Track) -> Bool {
            guard t.kind.acceptsMedia, !t.isLocked, c.isEnabled, !c.isFreezeFrame, let id = c.mediaID,
                  let a = lookup[id], a.kind != .image else { return false }
            return true
        }
        var present: [ClipID: Bool] = [:]   // eligible clips (value: has audio)
        for t in tl.tracks { for c in t.clips where eligible(c, t) { present[c.id] = lookup[c.mediaID!]?.hasAudio ?? false } }
        var detached: [ClipID: [ClipID]] = [:]
        var isMember = Set<ClipID>()
        for t in tl.tracks where t.kind == .audio {
            for c in t.clips where present[c.id] != nil {
                if let v = c.extractedFrom, present[v] != nil { detached[v, default: []].append(c.id); isMember.insert(c.id) }
            }
        }
        var out: [QuickCutTarget] = []
        for t in tl.tracks {
            for c in t.clips where present[c.id] != nil && !isMember.contains(c.id) {
                let members = [c.id] + (detached[c.id] ?? [])
                guard members.contains(where: { present[$0] == true }) else { continue }
                if !selection.isEmpty, !members.contains(where: selection.contains) { continue }
                out.append(QuickCutTarget(primary: c.id, members: members))
            }
        }
        return out
    }

    /// Media the targets need a mask for (with audio, each once, in target order).
    public static func media(of targets: [QuickCutTarget], in project: Project) -> [MediaAsset] {
        let lookup = MediaLookup(project.media)
        var seen = Set<MediaID>(), out: [MediaAsset] = []
        for t in targets {
            for m in t.members {
                guard let id = project.timeline.clip(m)?.mediaID, let a = lookup[id], a.hasAudio, seen.insert(id).inserted else { continue }
                out.append(a)
            }
        }
        return out
    }

    // MARK: Plan

    /// Slices to remove for blanks longer than `maxBlank` seconds. `masks` = analysis per media; targets whose media
    /// has no mask yet are reported in `pending` and left out.
    public static func plan(_ project: Project, targets: [QuickCutTarget], maxBlank: Double,
                            masks: [MediaID: QuickCutMask]) -> QuickCutPlan {
        let tl = project.timeline
        let lookup = MediaLookup.cached(project.media)
        var locations: [ClipID: (track: Int, clip: Int)] = [:]
        for (ti, t) in tl.tracks.enumerated() { for (ci, c) in t.clips.enumerated() { locations[c.id] = (ti, ci) } }
        var result = QuickCutPlan(maxBlank: maxBlank)
        var speech: [Span] = [], scratch: [Span] = []
        for target in targets {
            guard let pl = locations[target.primary] else { continue }
            let primary = tl.tracks[pl.track].clips[pl.clip]
            let s0 = primary.start.seconds, e0 = primary.end.seconds
            guard e0 - s0 > minimumSlice else { continue }
            speech.removeAll(keepingCapacity: true)
            var pending = false, untouched = false
            for id in target.members {
                guard let loc = locations[id] else { continue }
                let track = tl.tracks[loc.track], c = track.clips[loc.clip]
                guard c.isEnabled, tl.isAudible(track), !c.audio.isMuted, let mid = c.mediaID, let asset = lookup[mid],
                      asset.hasAudio else { continue }
                guard let mask = masks[mid] else { pending = true; result.pending.insert(mid); continue }
                guard mask.frameCount > 0 else { continue }
                if !mask.hasDynamics { untouched = true; continue }
                scratch.removeAll(keepingCapacity: true)
                memberSpeech(c, mask, into: &scratch)
                subtractInaudible(c, trackGain: track.gain, from: &scratch)
                for sp in scratch { let a = max(sp.a, s0), b = min(sp.b, e0); if b > a { speech.append(Span(a, b)) } }
            }
            guard !pending, !untouched, !speech.isEmpty else { continue }
            if target.members.count > 1 { speech.sort { $0.a < $1.a } }
            let slices = blanks(speech: speech, start: s0, end: e0, maxBlank: maxBlank)
            guard !slices.isEmpty else { continue }
            let ranges = slices.map { TimeRange(start: Time($0.a), end: Time($0.b)) }
            result.items.append(.init(target: target, onMainTrack: tl.tracks[pl.track].isMain, slices: ranges))
            for id in target.members {
                guard let loc = locations[id] else { continue }
                let c = tl.tracks[loc.track].clips[loc.clip]
                let own = id == target.primary ? ranges : clipped(ranges, to: c.range)
                if !own.isEmpty { result.slicesByClip[id] = own }
            }
        }
        return result
    }

    /// Timeline span in seconds (planner arithmetic is in Double: fast, converted to `Time` once per slice).
    struct Span: Equatable { var a: Double; var b: Double; init(_ a: Double, _ b: Double) { self.a = a; self.b = b } }

    static func clipped(_ ranges: [TimeRange], to r: TimeRange) -> [TimeRange] {
        ranges.compactMap { x in
            let a = max(x.start, r.start), b = min(x.end, r.end)
            return b - a >= Time(minimumSlice) ? TimeRange(start: a, end: b) : nil
        }
    }

    /// Speech of a clip in timeline seconds (sorted), from the media mask through the clip's source → timeline mapping.
    static func memberSpeech(_ c: Clip, _ mask: QuickCutMask, into out: inout [Span]) {
        let f = QuickCutMask.frameSeconds
        let t0 = c.start.seconds, dur = c.duration.seconds
        guard dur > 0 else { return }
        if case .constant(let rate) = c.speed, rate > 0 {
            let ss = c.sourceStart.seconds, se = ss + dur * rate
            let runs = mask.speechRuns
            // first run ending after the source start (binary search)
            var lo = 0, hi = runs.count
            while lo < hi { let m = (lo + hi) / 2; if Double(runs[m].upperBound) * f <= ss { lo = m + 1 } else { hi = m } }
            var spans: [Span] = []
            var i = lo
            while i < runs.count {
                let a = max(Double(runs[i].lowerBound) * f, ss), b = min(Double(runs[i].upperBound) * f, se)
                if a >= se { break }
                if b > a {
                    spans.append(c.reversed ? Span(t0 + (se - b) / rate, t0 + (se - a) / rate) : Span(t0 + (a - ss) / rate, t0 + (b - ss) / rate))
                }
                i += 1
            }
            out += c.reversed ? spans.reversed() : spans
            return
        }
        // speed curve (rare): sample the source time per 10 ms of timeline
        let n = Int((dur / f).rounded(.up))
        var runStart: Double?
        for k in 0..<n {
            let t = t0 + (Double(k) + 0.5) * f
            let s = c.sourceTime(at: Time(t)).seconds
            let on = mask[Int((s / f).rounded(.down))]
            let edge = t0 + Double(k) * f
            if on, runStart == nil { runStart = edge }
            if !on, let r = runStart { out.append(Span(r, edge)); runStart = nil }
        }
        if let r = runStart { out.append(Span(r, t0 + dur)) }
    }

    /// Removes from `spans` (sorted) the parts where the clip's effective gain is ≤ −40 dB (mute is handled by the
    /// caller): clip volume × volume keyframes × fades × track volume.
    static func subtractInaudible(_ c: Clip, trackGain: Double, from spans: inout [Span]) {
        guard !spans.isEmpty else { return }
        let t0 = c.start.seconds, dur = c.duration.seconds
        let vol = c.audio.volume * trackGain
        let fi = c.audio.fadeIn.seconds, fo = c.audio.fadeOut.seconds
        var quiet: [Span] = []
        if let kf = c.keyframes[ParamKey.volume.raw], !kf.keyframes.isEmpty {
            // keyframed volume: sample every 10 ms (eased spans are curves)
            let f = QuickCutMask.frameSeconds
            let n = Int((dur / f).rounded(.up))
            var runStart: Double?
            for k in 0..<n {
                let local = (Double(k) + 0.5) * f
                var g = (c.value(.volume, at: Time(local))?.scalar ?? c.audio.volume) * trackGain
                if fi > 0, local < fi { g *= local / fi }
                if fo > 0, local > dur - fo { g *= max(0, (dur - local) / fo) }
                let off = g <= inaudibleGain
                if off, runStart == nil { runStart = t0 + Double(k) * f }
                if !off, let r = runStart { quiet.append(Span(r, t0 + Double(k) * f)); runStart = nil }
            }
            if let r = runStart { quiet.append(Span(r, t0 + dur)) }
        } else {
            if vol <= inaudibleGain { spans.removeAll(); return }
            // linear fades: gain(local) = vol · local / fadeIn reaches −40 dB at local = fadeIn · 0.01 / vol
            if fi > 0 { quiet.append(Span(t0, t0 + min(dur, fi * inaudibleGain / vol))) }
            if fo > 0 { quiet.append(Span(t0 + max(0, dur - fo * inaudibleGain / vol), t0 + dur)) }
        }
        guard !quiet.isEmpty else { return }
        var out: [Span] = []
        out.reserveCapacity(spans.count)
        for s in spans {
            var a = s.a
            for q in quiet where q.b > a && q.a < s.b {
                if q.a > a { out.append(Span(a, q.a)) }
                a = max(a, q.b)
                if a >= s.b { break }
            }
            if a < s.b { out.append(Span(a, s.b)) }
        }
        spans = out
    }

    /// Removed slices of a clip spanning [start, end) with `speech` (sorted, inside it): blank runs longer than
    /// `maxBlank` minus the handles (only the speech-side handle at the clip's edges), slices < 40 ms dropped.
    static func blanks(speech: [Span], start: Double, end: Double, maxBlank: Double) -> [Span] {
        var out: [Span] = []
        let eps = 1e-6
        func gap(_ a0: Double, _ b0: Double) {
            guard b0 - a0 > maxBlank + eps else { return }
            let a = a0 <= start + eps ? start : a0 + handleAfter
            let b = b0 >= end - eps ? end : b0 - handleBefore
            if b - a >= minimumSlice - eps { out.append(Span(a, b)) }
        }
        var cursor = start
        for s in speech {
            if s.a > cursor { gap(cursor, s.a) }
            cursor = max(cursor, s.b)
        }
        if end > cursor { gap(cursor, end) }
        return out
    }
}
