import Foundation

public enum EditError: Error, Equatable, Sendable {
    case clipNotFound
    case trackNotFound
    case mediaNotFound
    case trackLocked
    case invalidTime
    case incompatibleTrack
    case nothingToDo

    /// Localization key for user-facing toasts.
    public var messageKey: String {
        switch self {
        case .clipNotFound: return "error.clipNotFound"
        case .trackNotFound: return "error.trackNotFound"
        case .mediaNotFound: return "error.mediaNotFound"
        case .trackLocked: return "error.trackLocked"
        case .invalidTime: return "error.invalidTime"
        case .incompatibleTrack: return "error.incompatibleTrack"
        case .nothingToDo: return "error.nothingToDo"
        }
    }
}

public enum TrimEdge: String, Codable, Sendable { case head, tail }

/// Lane kind of an adjustment-layer clip (CapCut: effects, filters and adjustments each get their own lane type, colour
/// and icon, UX.md §1.2 / §6.4). Derived from the category of the clip's first effect; MontageCore can't see the effect
/// registry, so MontageEffects installs `resolver` at bootstrap (`EffectsResources.register()`). Without it every
/// adjustment clip is `.adjustment`.
public enum AdjustmentLanes {
    /// Effect type id → `.effect` / `.filter` / `.adjustment` (nil = unknown). Lock-protected (tests bootstrap in parallel).
    public static var resolver: (@Sendable (String) -> TrackKind?)? {
        get { lock.withLock { _resolver } }
        set { lock.withLock { _resolver = newValue } }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _resolver: (@Sendable (String) -> TrackKind?)?


    public static func kind(of clip: Clip) -> TrackKind {
        guard case .adjustment = clip.content else { return .adjustment }
        return clip.effects.first.flatMap { resolver?($0.typeID) } ?? .adjustment
    }
}

/// Where a new clip goes.
public enum InsertTarget: Equatable, Sendable {
    /// Main track (magnetic insert at the nearest cut) for video/images; first free audio track for audio.
    case automatic
    case track(TrackID)
    /// Create a new track of the clip's kind above every existing visual track (or below audio).
    case newTrack
    /// Create a new track of the clip's kind directly above this track's lane (audio: appended below). Timeline drops
    /// at a lane boundary (C3).
    case newTrackAbove(TrackID)
}

/// Pure timeline editing operations on `Timeline` (and `Project` where media is needed).
/// All functions are deterministic, never touch I/O, and keep these invariants (checked by `validate()`):
/// - clips sorted by start, no overlap on a track except transitions (clip i overlaps i+1 by its `transitionOut`);
/// - with `mainTrackMagnet`, main-track clips are contiguous from 0;
/// - exactly one main track; no empty non-main tracks after an edit.
/// Commands (Commands.swift) wrap these for undo.
public enum TimelineOps {
    /// Shortest clip allowed after a trim/split.
    public static let minimumClipDuration = Time(ticks: Time.ticksPerSecond / 30)

    // MARK: Creating clips

    /// Builds a clip for a media asset with default duration and audio/visual settings.
    public static func makeClip(for asset: MediaAsset, at start: Time = .zero) -> Clip {
        var c = Clip(content: .media(asset.id), start: start, duration: asset.defaultClipDuration)
        c.name = asset.name
        return c
    }

    /// Track kind a clip belongs on.
    public static func trackKind(for clip: Clip, in project: Project) -> TrackKind {
        switch clip.content {
        case .media(let id): return project.asset(id)?.kind == .audio ? .audio : .video
        case .text: return .text
        case .sticker: return .sticker
        case .solid: return .video
        case .adjustment: return AdjustmentLanes.kind(of: clip)
        case .compound: return .video
        }
    }

    /// Inserts a clip. Returns the track it landed on.
    @discardableResult
    public static func insert(_ clip: Clip, into project: inout Project, target: InsertTarget = .automatic) throws -> TrackID {
        let kind = trackKind(for: clip, in: project)
        var tl = project.timeline
        let tid: TrackID
        switch target {
        case .automatic:
            if kind == .video, let mi = tl.mainTrackIndex {
                tid = tl.tracks[mi].id
            } else if let free = tl.tracks.first(where: { compatible($0.kind, kind) && !$0.isLocked && fits(clip.range, in: $0) }) {
                tid = free.id
            } else {
                tid = addTrack(kind, to: &tl)
            }
        case .track(let id):
            guard let ti = tl.trackIndex(id) else { throw EditError.trackNotFound }
            guard compatible(tl.tracks[ti].kind, kind) else { throw EditError.incompatibleTrack }
            guard !tl.tracks[ti].isLocked else { throw EditError.trackLocked }
            if tl.tracks[ti].isMain || fits(clip.range, in: tl.tracks[ti]) {
                tid = id
            } else {
                tid = addTrack(kind, to: &tl, above: ti)
            }
        case .newTrack:
            tid = addTrack(kind, to: &tl)
        case .newTrackAbove(let ref):
            tid = addTrack(kind, to: &tl, above: kind == .audio ? nil : tl.trackIndex(ref))
        }
        let ti = tl.trackIndex(tid)!
        var c = clip
        if tl.tracks[ti].isMain && tl.mainTrackMagnet {
            let idx = magneticIndex(for: c.start, in: tl.tracks[ti])
            tl.tracks[ti].clips.insert(c, at: idx)
            compactMain(&tl)
        } else {
            if tl.linkage, !tl.tracks[ti].isMain { c.linkedTo = mainClip(at: c.start, in: tl)?.id }
            tl.tracks[ti].clips.append(c)
            tl.tracks[ti].sortClips()
        }
        project.timeline = tl
        return tid
    }

    // MARK: Move

    /// Moves a clip to `start` on `trackID` (nil = same track). On the main track with magnet the clip is
    /// re-ordered by position and the track compacted; elsewhere an overlap pushes the clip onto a new track.
    /// Returns the track the clip ended on.
    @discardableResult
    public static func move(_ id: ClipID, to start: Time, track trackID: TrackID? = nil, in tl: inout Timeline) throws -> TrackID {
        guard let loc = tl.locate(id) else { throw EditError.clipNotFound }
        guard !tl.tracks[loc.track].isLocked else { throw EditError.trackLocked }
        let srcTrackID = tl.tracks[loc.track].id
        let srcWasMain = tl.tracks[loc.track].isMain
        let dstTrackID = trackID ?? srcTrackID
        guard let dstIndex0 = tl.trackIndex(dstTrackID) else { throw EditError.trackNotFound }
        guard compatible(tl.tracks[dstIndex0].kind, tl.tracks[loc.track].kind) else { throw EditError.incompatibleTrack }
        guard !tl.tracks[dstIndex0].isLocked else { throw EditError.trackLocked }

        let oldMainStarts = mainStarts(tl)
        var clip = tl.tracks[loc.track].clips.remove(at: loc.clip)
        let delta = max(start, .zero) - clip.start
        clip.start = max(start, .zero)
        var landed = dstTrackID
        if tl.tracks[dstIndex0].isMain && tl.mainTrackMagnet {
            let idx = magneticIndex(for: clip.start + clip.duration / 2.0, in: tl.tracks[dstIndex0], excluding: clip.id)
            // A re-ordered clip drops its outgoing transition (its neighbour changed).
            if !(srcTrackID == dstTrackID && idx == loc.clip) { clip.transitionOut = nil }
            clip.linkedTo = nil
            tl.tracks[dstIndex0].clips.insert(clip, at: idx)
        } else {
            if tl.linkage, !tl.tracks[dstIndex0].isMain { clip.linkedTo = mainClip(at: clip.start, in: tl)?.id }
            if fits(clip.range, in: tl.tracks[dstIndex0]) {
                tl.tracks[dstIndex0].clips.append(clip)
                tl.tracks[dstIndex0].sortClips()
            } else {
                let kind = tl.tracks[dstIndex0].kind == .video && tl.tracks[dstIndex0].isMain ? .video : tl.tracks[dstIndex0].kind
                landed = addTrack(kind, to: &tl, above: dstIndex0)
                let ni = tl.trackIndex(landed)!
                tl.tracks[ni].clips.append(clip)
            }
        }
        // Clips linked to a moved main clip follow it when it is moved freely (no magnet).
        if tl.linkage, srcWasMain, !tl.mainTrackMagnet {
            shiftLinked(to: id, by: delta, in: &tl)
        }
        if tl.mainTrackMagnet { compactMain(&tl, previousStarts: oldMainStarts) }
        removeEmptyTracks(&tl)
        return landed
    }

    // MARK: Trim

    /// Trims a clip edge to timeline time `to`. Respects media bounds and the minimum duration.
    public static func trim(_ id: ClipID, edge: TrimEdge, to time: Time, in project: inout Project) throws {
        var tl = project.timeline
        guard let loc = tl.locate(id) else { throw EditError.clipNotFound }
        guard !tl.tracks[loc.track].isLocked else { throw EditError.trackLocked }
        var c = tl.tracks[loc.track].clips[loc.clip]
        if c.isFreezeFrame { return try trimFreeze(id, edge: edge, to: time, in: &project) }
        let mediaDuration = c.mediaID.flatMap { project.asset($0) }.map { $0.kind == .image ? Time.indefinite : $0.duration }
        let rate = c.speed.averageRate
        let oldMainStarts = mainStarts(tl)
        switch edge {
        case .head:
            var newStart = min(time, c.end - minimumClipDuration)
            if mediaDuration != nil, !c.reversed {
                // can't reveal media before 0
                let earliest = c.start - c.sourceStart / rate
                newStart = max(newStart, earliest)
            }
            // On the magnetic main track the clip may grow leftwards past 0; compaction re-packs it.
            let magnetic = tl.tracks[loc.track].isMain && tl.mainTrackMagnet
            if !magnetic { newStart = max(newStart, .zero) }
            let delta = newStart - c.start
            guard delta.ticks != 0 else { return }
            if !c.reversed { c.sourceStart = max(.zero, c.sourceStart + delta * rate) }
            c.start = newStart
            c.duration -= delta
            for k in c.keyframes.keys { c.keyframes[k]?.shift(by: -delta) }
            c.shiftMarkers(by: -delta)
        case .tail:
            var newEnd = max(time, c.start + minimumClipDuration)
            if let md = mediaDuration, md != .indefinite {
                let available = c.reversed ? c.sourceStart + c.sourceDuration : md - c.sourceStart
                newEnd = min(newEnd, c.start + available / rate)
            }
            let newDuration = newEnd - c.start
            guard newDuration != c.duration else { return }
            if c.reversed { c.sourceStart += c.sourceDuration - c.speed.sourceDuration(forOutput: newDuration) }
            c.duration = newDuration
        }
        // other clips on a free track must not overlap
        if !(tl.tracks[loc.track].isMain && tl.mainTrackMagnet) {
            let others = tl.tracks[loc.track].clips.enumerated().filter { $0.offset != loc.clip }.map(\.element)
            if others.contains(where: { $0.range.overlaps(c.range) }) { throw EditError.invalidTime }
        }
        tl.tracks[loc.track].clips[loc.clip] = c
        clampTransitions(&tl.tracks[loc.track])
        if tl.mainTrackMagnet { compactMain(&tl, previousStarts: oldMainStarts) }
        project.timeline = tl
    }

    // MARK: Split

    /// Splits the clip at timeline time `t`. Returns the id of the new right-hand clip.
    @discardableResult
    public static func split(_ id: ClipID, at t: Time, in tl: inout Timeline) throws -> ClipID {
        guard let loc = tl.locate(id) else { throw EditError.clipNotFound }
        guard !tl.tracks[loc.track].isLocked else { throw EditError.trackLocked }
        let c = tl.tracks[loc.track].clips[loc.clip]
        let local = t - c.start
        guard local >= minimumClipDuration, c.duration - local >= minimumClipDuration else { throw EditError.invalidTime }
        var left = c, right = c
        right.id = ClipID()
        left.duration = local
        right.start = t
        right.duration = c.duration - local
        // speed / source mapping
        switch c.speed {
        case .constant:
            let off = c.speed.sourceOffset(at: local, outputDuration: c.duration)
            if c.reversed { left.sourceStart = c.sourceStart + c.sourceDuration - off; right.sourceStart = c.sourceStart }
            else { right.sourceStart = c.sourceStart + off }
        case .curve(let curve):
            let a = local / c.duration
            left.speed = .curve(curve.subcurve(from: 0, to: a))
            right.speed = .curve(curve.subcurve(from: a, to: 1))
            let off = c.speed.sourceOffset(at: local, outputDuration: c.duration)
            if c.reversed { left.sourceStart = c.sourceStart + c.sourceDuration - off; right.sourceStart = c.sourceStart }
            else { right.sourceStart = c.sourceStart + off }
        }
        // keyframes: keep values continuous across the cut
        for (k, track) in c.keyframes {
            var l = KeyframeTrack(track.keyframes.filter { $0.time <= local })
            var r = KeyframeTrack(track.keyframes.filter { $0.time >= local })
            if let v = track.value(at: local) { l.set(v, at: local); r.set(v, at: local) }
            r.shift(by: -local)
            left.keyframes[k] = l
            right.keyframes[k] = r
        }
        if let ms = c.markers {
            let l = ms.filter { $0.time < local }, r = ms.filter { $0.time >= local }.map { var m = $0; m.time = m.time - local; return m }
            left.markers = l.isEmpty ? nil : l
            right.markers = r.isEmpty ? nil : r
        }
        left.transitionOut = nil
        left.animations.outAnim = nil
        right.animations.inAnim = nil
        left.audio.fadeOut = .zero
        right.audio.fadeIn = .zero
        if let combo = c.animations.combo { left.animations.combo = combo; right.animations.combo = combo }
        tl.tracks[loc.track].clips[loc.clip] = left
        tl.tracks[loc.track].clips.insert(right, at: loc.clip + 1)
        // linked clips that start after the cut now follow the right half
        if tl.tracks[loc.track].isMain {
            for ti in tl.tracks.indices where !tl.tracks[ti].isMain {
                for ci in tl.tracks[ti].clips.indices where tl.tracks[ti].clips[ci].linkedTo == id && tl.tracks[ti].clips[ci].start >= t {
                    tl.tracks[ti].clips[ci].linkedTo = right.id
                }
            }
        }
        return right.id
    }

    // MARK: Move with a placeholder (C3b)

    /// The timeline with clip `id` taken out, as a move gesture previews it: the magnetic main track re-packed (no
    /// linked-clip shifts), every track KEPT even when it becomes empty (lane rows stay put under the pointer).
    public static func liftForMove(_ id: ClipID, from tl: Timeline) throws -> (timeline: Timeline, clip: Clip) {
        var tl = tl
        guard let loc = tl.locate(id) else { throw EditError.clipNotFound }
        guard !tl.tracks[loc.track].isLocked else { throw EditError.trackLocked }
        var clip = tl.tracks[loc.track].clips.remove(at: loc.clip)
        if tl.tracks[loc.track].isMain {
            // its neighbours change: transitions at both of its cuts go
            if loc.clip > 0 { tl.tracks[loc.track].clips[loc.clip - 1].transitionOut = nil }
            clip.transitionOut = nil
            let linkage = tl.linkage
            tl.linkage = false
            compactMain(&tl)
            tl.linkage = linkage
        }
        return (tl, clip)
    }

    /// Moves clip `id` to `start` with an insert target, exactly as the move preview showed it (`liftForMove`, then an
    /// insert: ripple at the main-track boundary, a lane, a new lane above a track…). Clips linked to moved main-track
    /// clips follow them. Returns the track the clip landed on.
    @discardableResult
    public static func relocate(_ id: ClipID, to start: Time, target: InsertTarget, in project: inout Project) throws -> TrackID {
        let old = mainStarts(project.timeline)
        var (tl, clip) = try liftForMove(id, from: project.timeline)
        clip.start = max(.zero, start)
        clip.linkedTo = nil
        let linkage = tl.linkage
        tl.linkage = false
        var p = project
        p.timeline = tl
        let landed = try insert(clip, into: &p, target: target)
        tl = p.timeline
        tl.linkage = linkage
        if linkage, let ti = tl.trackIndex(landed), !tl.tracks[ti].isMain,
           let ci = tl.tracks[ti].clips.firstIndex(where: { $0.id == id }) {
            tl.tracks[ti].clips[ci].linkedTo = mainClip(at: tl.tracks[ti].clips[ci].start, in: tl)?.id
        }
        if tl.mainTrackMagnet { compactMain(&tl, previousStarts: old) }
        if let mi = tl.mainTrackIndex { clampTransitions(&tl.tracks[mi]) }
        removeEmptyTracks(&tl)
        project.timeline = tl
        return landed
    }

    // MARK: Delete

    public static func delete(_ ids: Set<ClipID>, in tl: inout Timeline) throws {
        guard !ids.isEmpty else { throw EditError.nothingToDo }
        let oldMainStarts = mainStarts(tl)
        var ids = ids
        // Linkage: clips attached to a deleted main-track clip are deleted with it (CapCut, UX.md §7 "Delete").
        if tl.linkage, let main = tl.mainTrack {
            let mainIDs = Set(main.clips.map(\.id)).intersection(ids)
            if !mainIDs.isEmpty {
                for t in tl.tracks where !t.isMain && !t.isLocked {
                    for c in t.clips where c.linkedTo.map(mainIDs.contains) == true && followsMain(c, on: t.kind, in: tl) { ids.insert(c.id) }
                }
            }
        }
        var removed = 0
        for ti in tl.tracks.indices where !tl.tracks[ti].isLocked {
            let before = tl.tracks[ti].clips.count
            tl.tracks[ti].clips.removeAll { ids.contains($0.id) }
            removed += before - tl.tracks[ti].clips.count
        }
        guard removed > 0 else { throw EditError.clipNotFound }
        for ti in tl.tracks.indices {
            for ci in tl.tracks[ti].clips.indices where tl.tracks[ti].clips[ci].linkedTo.map(ids.contains) == true {
                tl.tracks[ti].clips[ci].linkedTo = nil
            }
        }
        if tl.mainTrackMagnet { compactMain(&tl, previousStarts: oldMainStarts) }
        removeEmptyTracks(&tl)
    }

    // MARK: Speed / transitions

    /// Changes speed keeping the consumed source extent (the clip gets shorter/longer on the timeline, like CapCut).
    public static func setSpeed(_ id: ClipID, _ speed: Speed, in tl: inout Timeline) throws {
        guard let loc = tl.locate(id) else { throw EditError.clipNotFound }
        var c = tl.tracks[loc.track].clips[loc.clip]
        let source = c.sourceDuration
        let oldDuration = c.duration
        let oldMainStarts = mainStarts(tl)
        c.speed = speed
        c.duration = max(minimumClipDuration, speed.outputDuration(forSource: source))
        let k = c.duration / oldDuration
        for key in c.keyframes.keys {
            c.keyframes[key] = KeyframeTrack(c.keyframes[key]!.keyframes.map { var f = $0; f.time = f.time * k; return f })
        }
        if let ms = c.markers { c.markers = ms.map { var m = $0; m.time = m.time * k; return m } }
        tl.tracks[loc.track].clips[loc.clip] = c
        if !(tl.tracks[loc.track].isMain && tl.mainTrackMagnet) {
            let others = tl.tracks[loc.track].clips.enumerated().filter { $0.offset != loc.clip }.map(\.element)
            if others.contains(where: { $0.range.overlaps(c.range) }) {
                // move to a new track rather than overlapping
                tl.tracks[loc.track].clips.remove(at: loc.clip)
                let nt = addTrack(tl.tracks[loc.track].kind, to: &tl, above: loc.track)
                tl.tracks[tl.trackIndex(nt)!].clips.append(c)
            }
        }
        clampTransitions(&tl.tracks[tl.locate(id)!.track])
        if tl.mainTrackMagnet { compactMain(&tl, previousStarts: oldMainStarts) }
    }

    /// Sets (or clears) the transition between `id` and the next clip on its track.
    public static func setTransition(_ id: ClipID, _ transition: TransitionInstance?, in tl: inout Timeline) throws {
        guard let loc = tl.locate(id) else { throw EditError.clipNotFound }
        guard loc.clip + 1 < tl.tracks[loc.track].clips.count || transition == nil else { throw EditError.invalidTime }
        if !tl.tracks[loc.track].isMain {   // PiP transitions (TimelineOps+Transitions.swift)
            try setOverlayTransition(track: loc.track, clip: loc.clip, transition, in: &tl); return
        }
        let oldMainStarts = mainStarts(tl)
        tl.tracks[loc.track].clips[loc.clip].transitionOut = transition
        clampTransitions(&tl.tracks[loc.track])
        if tl.mainTrackMagnet { compactMain(&tl, previousStarts: oldMainStarts) }
    }

    // MARK: Main track magnet & linkage

    /// Packs main-track clips from 0 (transitions overlap neighbours) and moves linked clips by the same delta.
    public static func compactMain(_ tl: inout Timeline, previousStarts: [ClipID: Time]? = nil, except: Set<ClipID> = []) {
        guard tl.mainTrackMagnet, let mi = tl.mainTrackIndex else { return }
        let before = previousStarts ?? mainStarts(tl)
        var t = Time.zero
        let n = tl.tracks[mi].clips.count
        for i in 0..<n {
            tl.tracks[mi].clips[i].start = t
            let c = tl.tracks[mi].clips[i]
            let overlap = (i + 1 < n) ? (c.transitionOut?.duration ?? .zero) : .zero
            if i + 1 == n { tl.tracks[mi].clips[i].transitionOut = nil }
            t = c.end - overlap
        }
        guard tl.linkage else { return }
        for c in tl.tracks[mi].clips {
            guard let old = before[c.id], old != c.start else { continue }
            shiftLinked(to: c.id, by: c.start - old, in: &tl, except: except)
        }
    }

    static func mainStarts(_ tl: Timeline) -> [ClipID: Time] {
        guard let m = tl.mainTrack else { return [:] }
        return Dictionary(uniqueKeysWithValues: m.clips.map { ($0.id, $0.start) })
    }

    static func shiftLinked(to mainID: ClipID, by delta: Time, in tl: inout Timeline, except: Set<ClipID> = []) {
        guard delta.ticks != 0 else { return }
        for ti in tl.tracks.indices where !tl.tracks[ti].isMain {
            var changed = false
            let kind = tl.tracks[ti].kind
            for ci in tl.tracks[ti].clips.indices where tl.tracks[ti].clips[ci].linkedTo == mainID
                && !except.contains(tl.tracks[ti].clips[ci].id) && followsMain(tl.tracks[ti].clips[ci], on: kind, in: tl) {
                tl.tracks[ti].clips[ci].start = max(.zero, tl.tracks[ti].clips[ci].start + delta)
                changed = true
            }
            if changed { tl.tracks[ti].sortClips() }
        }
    }

    /// Main-track clip under timeline time `t`.
    public static func mainClip(at t: Time, in tl: Timeline) -> Clip? {
        tl.mainTrack?.clips.last { $0.start <= t && t < $0.end }
    }

    /// Index at which a clip dropped at time `t` goes on a magnetic track (nearest cut).
    public static func magneticIndex(for t: Time, in track: Track, excluding: ClipID? = nil) -> Int {
        var idx = 0
        for c in track.clips where c.id != excluding {
            if c.start + c.duration / 2.0 <= t { idx += 1 }
        }
        return idx
    }

    /// Transitions can't exceed half of either neighbour.
    static func clampTransitions(_ track: inout Track) {
        for i in track.clips.indices {
            guard var tr = track.clips[i].transitionOut else { continue }
            guard i + 1 < track.clips.count else { track.clips[i].transitionOut = nil; continue }
            let maxD = min(track.clips[i].duration, track.clips[i + 1].duration) / 2.0
            if tr.duration > maxD { tr.duration = maxD; track.clips[i].transitionOut = tr }
        }
        normalizeOverlayTransitions(&track)
    }

    // MARK: Tracks

    /// Lanes hold one kind of clip: effects, filters and adjustment layers never share a lane (UX.md §6.4).
    public static func compatible(_ trackKind: TrackKind, _ clipKind: TrackKind) -> Bool { trackKind == clipKind }

    static func fits(_ range: TimeRange, in track: Track) -> Bool {
        !track.clips.contains { $0.range.overlaps(range) }
    }

    /// Adds a track. Visual tracks go above `above` (or on top of the stack); audio tracks go at the end.
    @discardableResult
    public static func addTrack(_ kind: TrackKind, to tl: inout Timeline, above: Int? = nil) -> TrackID {
        let t = Track(kind: kind)
        if kind == .audio || above == nil {
            tl.tracks.append(t)
        } else {
            tl.tracks.insert(t, at: min(above! + 1, tl.tracks.count))
        }
        return t.id
    }

    public static func removeEmptyTracks(_ tl: inout Timeline) {
        tl.tracks.removeAll { !$0.isMain && $0.clips.isEmpty }
    }

    /// Invariant violations (empty = OK). Used by tests and debug assertions.
    public static func validate(_ tl: Timeline) -> [String] {
        var problems: [String] = []
        if tl.tracks.filter(\.isMain).count != 1 { problems.append("expected exactly one main track") }
        for t in tl.tracks {
            for i in t.clips.indices {
                let c = t.clips[i]
                if c.duration.ticks <= 0 { problems.append("clip \(c.id.short) has non-positive duration") }
                if c.start < .zero { problems.append("clip \(c.id.short) starts before 0") }
                if i > 0 {
                    let p = t.clips[i - 1]
                    if p.start > c.start { problems.append("track \(t.id.short) not sorted") }
                    let allowed = p.transitionOut?.duration ?? .zero   // main and overlay (PiP) transitions
                    if p.end - c.start > allowed { problems.append("overlap \(p.id.short)/\(c.id.short)") }
                }
            }
            if t.isMain && tl.mainTrackMagnet {
                if let f = t.clips.first, f.start != .zero { problems.append("main track does not start at 0") }
                for i in t.clips.indices.dropFirst() {
                    let p = t.clips[i - 1], c = t.clips[i]
                    if c.start != p.end - (p.transitionOut?.duration ?? .zero) { problems.append("gap on main track before \(c.id.short)") }
                }
            }
        }
        return problems
    }
}

extension SpeedCurve {
    /// The curve restricted to output positions [a, b], renormalized to [0, 1].
    public func subcurve(from a: Double, to b: Double) -> SpeedCurve {
        guard b > a else { return self }
        var pts: [SpeedPoint] = [SpeedPoint(0, value(at: a))]
        for p in points where p.x > a && p.x < b { pts.append(SpeedPoint((p.x - a) / (b - a), p.v)) }
        pts.append(SpeedPoint(1, value(at: b)))
        return SpeedCurve(points: pts, presetID: presetID, interpolation: interpolation)
    }
}
