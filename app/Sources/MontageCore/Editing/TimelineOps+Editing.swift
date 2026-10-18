import Foundation

/// One copied clip with enough context to paste it back onto a similar track (CapCut ⌘C / ⌘V).
public struct ClipboardItem: Codable, Sendable, Equatable {
    public var clip: Clip
    public var trackKind: TrackKind
    public var trackID: TrackID
    public var wasMain: Bool
    public init(clip: Clip, trackKind: TrackKind, trackID: TrackID, wasMain: Bool) {
        self.clip = clip; self.trackKind = trackKind; self.trackID = trackID; self.wasMain = wasMain
    }
}

/// Attribute groups offered by "Paste attributes" (TL-011).
public enum AttributeGroup: String, Codable, Sendable, CaseIterable {
    /// `effects` = effects + filters; `adjust` = Adjust-tab grading (adjustment-category effects, LUT, HSL, curves,
    /// wheels) + the Adjust ▸ Mask (CL-025).
    case basic, effects, adjust, animation, keyframes, speed, audio, textStyle
    public var nameKey: String { "attr.\(rawValue)" }
}

/// Keyframe timing when pasting keyframes onto a clip of a different length.
public enum KeyframeTiming: String, Codable, Sendable, CaseIterable {
    /// Keep absolute clip-local times (keyframes past the end are dropped).
    case keep
    /// Stretch keyframe times to the target clip's duration.
    case stretch
    public var nameKey: String { "attr.timing.\(rawValue)" }
}

/// "Arrange layers" (TL-019).
public enum LayerArrangement: String, Sendable, CaseIterable {
    case forward, backward, front, back
    public var nameKey: String { "arrange.\(rawValue)" }
}

/// Timeline-editing operations of the W1 workstream (groups, clipboard, freeze, reverse, gaps, roll/slip, markers,
/// beats, extract audio, arrange, track management). Same contract as `TimelineOps`: pure, invariant-keeping
/// (`validate`), throwing `EditError` on refusal.
extension TimelineOps {

    // MARK: Linkage

    /// Linkage-settings category of a non-main clip.
    public static func linkageCategory(of c: Clip, on kind: TrackKind) -> LinkageCategory {
        switch kind {
        case .text: return .text
        case .sticker: return .stickers
        case .audio: return .audio
        case .video: return .overlay
        case .effect: return .effects
        case .filter: return .filters
        case .adjustment:
            if let t = c.effects.first?.typeID {
                if t.contains(".filter.") { return .filters }
                if t.contains(".effect.") { return .effects }
            }
            return .adjust
        }
    }

    /// Whether a linked clip follows (and is deleted with) its main-track clip under the current linkage settings.
    public static func followsMain(_ c: Clip, on kind: TrackKind, in tl: Timeline) -> Bool {
        tl.linkage && !(tl.linkageExcluded ?? []).contains(linkageCategory(of: c, on: kind))
    }

    // MARK: Selection helpers

    /// Expands a selection to whole groups.
    public static func expandGroups(_ ids: Set<ClipID>, in tl: Timeline) -> Set<ClipID> {
        let groups = Set(ids.compactMap { tl.clip($0)?.groupID })
        guard !groups.isEmpty else { return ids }
        var out = ids
        for t in tl.tracks { for c in t.clips where c.groupID.map(groups.contains) == true { out.insert(c.id) } }
        return out
    }

    /// CapCut "[" / "]": every clip on unlocked tracks left (starting before) / right (ending after) of `t`.
    public static func clips(leftOf t: Time, in tl: Timeline) -> Set<ClipID> {
        Set(tl.tracks.filter { !$0.isLocked }.flatMap { $0.clips.filter { $0.start < t }.map(\.id) })
    }
    public static func clips(rightOf t: Time, in tl: Timeline) -> Set<ClipID> {
        Set(tl.tracks.filter { !$0.isLocked }.flatMap { $0.clips.filter { $0.end > t }.map(\.id) })
    }

    /// Sorted, de-duplicated cut points (clip starts/ends on every track, plus 0) for ↑ / ↓ navigation.
    public static func cutPoints(_ tl: Timeline) -> [Time] {
        var s = Set<Time>([.zero])
        for t in tl.tracks { for c in t.clips { s.insert(c.start); s.insert(c.end) } }
        return s.sorted()
    }

    // MARK: Groups

    @discardableResult
    public static func group(_ ids: Set<ClipID>, in tl: inout Timeline) throws -> ClipGroupID {
        let found = ids.filter { tl.clip($0) != nil }
        guard found.count >= 2 else { throw EditError.nothingToDo }
        let g = ClipGroupID()
        for id in found { tl[clip: id]?.groupID = g }
        return g
    }

    public static func ungroup(_ ids: Set<ClipID>, in tl: inout Timeline) throws {
        let groups = Set(ids.compactMap { tl.clip($0)?.groupID })
        guard !groups.isEmpty else { throw EditError.nothingToDo }
        for ti in tl.tracks.indices {
            for ci in tl.tracks[ti].clips.indices where tl.tracks[ti].clips[ci].groupID.map(groups.contains) == true {
                tl.tracks[ti].clips[ci].groupID = nil
            }
        }
    }

    // MARK: Multi-clip move

    /// Moves several clips by `delta` together (multi-selection / group drag). Main-track clips with the magnet
    /// move as one block re-inserted at the nearest cut; other clips keep their track when free, otherwise the
    /// whole set from that track moves to a new track right above it.
    public static func moveClips(_ ids: Set<ClipID>, by delta: Time, in tl: inout Timeline) throws {
        let present = ids.filter { tl.clip($0) != nil }
        guard !present.isEmpty else { throw EditError.clipNotFound }
        for t in tl.tracks where t.isLocked && t.clips.contains(where: { present.contains($0.id) }) { throw EditError.trackLocked }
        if present.count == 1, let id = present.first, let c = tl.clip(id) {
            try move(id, to: max(.zero, c.start + delta), in: &tl); return
        }
        let minStart = tl.tracks.flatMap(\.clips).filter { present.contains($0.id) }.map(\.start).min() ?? .zero
        let d = max(delta, -minStart)
        let oldMainStarts = mainStarts(tl)
        // Main track
        if let mi = tl.mainTrackIndex {
            let moving = tl.tracks[mi].clips.filter { present.contains($0.id) }
            if !moving.isEmpty {
                if tl.mainTrackMagnet {
                    tl.tracks[mi].clips.removeAll { present.contains($0.id) }
                    let blockStart = moving[0].start + d
                    // nearest cut among the remaining clips, as they will be packed
                    var idx = 0, acc = Time.zero
                    for c in tl.tracks[mi].clips {
                        if acc + c.duration / 2.0 <= blockStart { idx += 1 } else { break }
                        acc += c.duration
                    }
                    var block = moving
                    block[block.count - 1].transitionOut = nil
                    if idx > 0 { tl.tracks[mi].clips[idx - 1].transitionOut = nil }
                    tl.tracks[mi].clips.insert(contentsOf: block, at: idx)
                } else {
                    try shiftOnTrack(mi, present, by: d, in: &tl)
                }
            }
        }
        // Other tracks
        for ti in tl.tracks.indices.reversed() where !tl.tracks[ti].isMain {
            guard tl.tracks[ti].clips.contains(where: { present.contains($0.id) }) else { continue }
            try shiftOnTrack(ti, present, by: d, in: &tl)
        }
        if tl.mainTrackMagnet { compactMain(&tl, previousStarts: oldMainStarts, except: present) }
        else if tl.linkage, let main = tl.mainTrack {
            for c in main.clips where present.contains(c.id) { shiftLinked(to: c.id, by: d, in: &tl, except: present) }
        }
        removeEmptyTracks(&tl)
    }

    /// Shifts the given clips of one track; if they collide with the rest they go to a new track above.
    private static func shiftOnTrack(_ ti: Int, _ ids: Set<ClipID>, by d: Time, in tl: inout Timeline) throws {
        var moving = tl.tracks[ti].clips.filter { ids.contains($0.id) }
        tl.tracks[ti].clips.removeAll { ids.contains($0.id) }
        for i in moving.indices { moving[i].start += d; moving[i].transitionOut = nil }
        let free = moving.allSatisfy { fits($0.range, in: tl.tracks[ti]) }
        if free {
            tl.tracks[ti].clips.append(contentsOf: moving); tl.tracks[ti].sortClips()
        } else {
            let kind = tl.tracks[ti].kind
            let nid = addTrack(kind, to: &tl, above: ti)
            let ni = tl.trackIndex(nid)!
            tl.tracks[ni].clips = moving.sorted { $0.start < $1.start }
        }
    }

    // MARK: Multi-clip trim ("many select extend")

    /// Applies the same edge delta to several clips (each one clamped by its own limits).
    public static func trimClips(_ ids: [ClipID], edge: TrimEdge, by delta: Time, in project: inout Project) throws {
        let base = project.timeline
        var did = false
        for id in ids {
            guard let c = base.clip(id) else { continue }
            let target = edge == .head ? c.start + delta : c.end + delta
            if (try? trim(id, edge: edge, to: target, in: &project)) != nil { did = true }
        }
        if !did { throw EditError.invalidTime }
    }

    // MARK: Clipboard

    public static func copyItems(_ ids: Set<ClipID>, from tl: Timeline) -> [ClipboardItem] {
        var out: [ClipboardItem] = []
        for t in tl.tracks {
            for c in t.clips where ids.contains(c.id) {
                out.append(ClipboardItem(clip: c, trackKind: t.kind, trackID: t.id, wasMain: t.isMain))
            }
        }
        return out.sorted { $0.clip.start < $1.clip.start }
    }

    /// Pastes clipboard items so the earliest starts at `time`. Returns the new clip ids.
    @discardableResult
    public static func paste(_ items: [ClipboardItem], at time: Time, in project: inout Project) throws -> [ClipID] {
        guard !items.isEmpty else { throw EditError.nothingToDo }
        var tl = project.timeline
        let offset = time - (items.map(\.clip.start).min() ?? .zero)
        var groupMap: [ClipGroupID: ClipGroupID] = [:]
        var newTrackFor: [TrackID: TrackID] = [:]
        var out: [ClipID] = []
        let oldMainStarts = mainStarts(tl)
        for item in items.sorted(by: { $0.clip.start < $1.clip.start }) {
            var c = item.clip
            c.id = ClipID()
            c.start = max(.zero, c.start + offset)
            c.transitionOut = nil
            c.linkedTo = nil
            if let g = c.groupID { c.groupID = groupMap[g] ?? { let n = ClipGroupID(); groupMap[g] = n; return n }() }
            if let m = c.mediaID, project.asset(m) == nil { throw EditError.mediaNotFound }
            if item.wasMain, let mi = tl.mainTrackIndex, !tl.tracks[mi].isLocked {
                if tl.mainTrackMagnet {
                    tl.tracks[mi].clips.insert(c, at: magneticIndex(for: c.start, in: tl.tracks[mi]))
                    compactMain(&tl, previousStarts: oldMainStarts)
                    out.append(c.id); continue
                } else if fits(c.range, in: tl.tracks[mi]) {
                    tl.tracks[mi].clips.append(c); tl.tracks[mi].sortClips(); out.append(c.id); continue
                }
            }
            var target: Int?
            if let ti = tl.trackIndex(item.trackID), !tl.tracks[ti].isMain, !tl.tracks[ti].isLocked,
               compatible(tl.tracks[ti].kind, item.trackKind), fits(c.range, in: tl.tracks[ti]) {
                target = ti
            } else if let nt = newTrackFor[item.trackID], let ti = tl.trackIndex(nt), fits(c.range, in: tl.tracks[ti]) {
                target = ti
            }
            if target == nil {
                let above = tl.trackIndex(item.trackID) ?? tl.mainTrackIndex
                let nid = addTrack(item.trackKind, to: &tl, above: above)
                newTrackFor[item.trackID] = nid
                target = tl.trackIndex(nid)
            }
            let ti = target!
            if tl.linkage, !tl.tracks[ti].isMain { c.linkedTo = mainClip(at: c.start, in: tl)?.id }
            tl.tracks[ti].clips.append(c)
            tl.tracks[ti].sortClips()
            out.append(c.id)
        }
        project.timeline = tl
        return out
    }

    /// Duplicates clips right after the selection (or at `time`). Returns the copies.
    @discardableResult
    public static func duplicate(_ ids: Set<ClipID>, at time: Time? = nil, in project: inout Project) throws -> [ClipID] {
        let items = copyItems(ids, from: project.timeline)
        guard !items.isEmpty else { throw EditError.clipNotFound }
        let end = items.map(\.clip.end).max()!
        return try paste(items, at: time ?? end, in: &project)
    }

    // MARK: Copy / paste attributes

    public static func pasteAttributes(from src: Clip, groups: Set<AttributeGroup>, timing: KeyframeTiming = .stretch,
                                       to ids: Set<ClipID>, in tl: inout Timeline) throws {
        var did = false
        for id in ids where id != src.id {
            guard var c = tl.clip(id) else { continue }
            if groups.contains(.basic) {
                c.transform = src.transform; c.opacity = src.opacity; c.blendMode = src.blendMode
                c.crop = src.crop; c.mask = src.mask
            }
            if groups.contains(.adjust) { c.adjustMask = src.adjustMask }
            var effectIDMap: [String: String] = [:]
            // Effects / filters and Adjust grading are separate groups: each replaces only its own part of the stack.
            let isAdjust: (EffectInstance) -> Bool = { AdjustmentLanes.resolver?($0.typeID) == .adjustment }
            let replaces: (EffectInstance) -> Bool = { e in isAdjust(e) ? groups.contains(.adjust) : groups.contains(.effects) }
            if groups.contains(.effects) || groups.contains(.adjust) {
                let removed = Set(c.effects.filter(replaces).map { $0.id.raw.uuidString })
                let copied = src.effects.filter(replaces).map { e in
                    var n = e; n.id = EffectInstanceID()
                    effectIDMap[e.id.raw.uuidString] = n.id.raw.uuidString
                    return n
                }
                // keep the untouched part in place; pasted adjustments go first (grade, then effects), effects last
                let kept = c.effects.filter { !replaces($0) }
                c.effects = kept.isEmpty ? copied : copied.filter(isAdjust) + kept + copied.filter { !isAdjust($0) }
                c.keyframes = c.keyframes.filter { k in
                    guard let (eid, _) = ParamKey(k.key).effectParam else { return true }
                    return !removed.contains(eid.raw.uuidString)
                }
            }
            if groups.contains(.animation) { c.animations = src.animations }
            if groups.contains(.audio) { c.audio = src.audio }
            if groups.contains(.textStyle), case .text(let s) = src.content, case .text(var t) = c.content {
                let string = t.string
                t = s; t.string = string
                c.content = .text(t)
            }
            if groups.contains(.keyframes) {
                var kfs: [String: KeyframeTrack] = [:]
                let k = src.duration.ticks > 0 ? c.duration / src.duration : 1
                for (key, track) in src.keyframes {
                    var newKey = key
                    if let (eid, param) = ParamKey(key).effectParam {
                        guard let mapped = effectIDMap[eid.raw.uuidString]
                            ?? (c.effects.contains { $0.id == eid } ? eid.raw.uuidString : nil) else { continue }
                        newKey = "effect.\(mapped).\(param)"
                    }
                    var frames = track.keyframes
                    if timing == .stretch { frames = frames.map { var f = $0; f.time = f.time * k; return f } }
                    else { frames.removeAll { $0.time > c.duration } }
                    if !frames.isEmpty { kfs[newKey] = KeyframeTrack(frames) }
                }
                // effect keyframes of replaced effects were dropped above; the rest stay valid
                c.keyframes = c.keyframes.filter { $0.key.hasPrefix("effect.") }.merging(kfs) { _, b in b }
            }
            tl[clip: id] = c
            if groups.contains(.speed), c.mediaID != nil, src.mediaID != nil, !c.isFreezeFrame {
                try? setSpeed(id, src.speed, in: &tl)
            }
            did = true
        }
        if !did { throw EditError.nothingToDo }
    }

    // MARK: Freeze / reverse / enable

    /// CapCut "Freeze": splits the clip at `t` and inserts a held-frame clip of `duration` there, rippling the rest of
    /// the track. Returns the freeze clip id.
    @discardableResult
    public static func freezeFrame(_ id: ClipID, at t: Time, duration: Time = EditDefaults.current.freezeDuration, in project: inout Project) throws -> ClipID {
        var tl = project.timeline
        guard let loc = tl.locate(id) else { throw EditError.clipNotFound }
        guard !tl.tracks[loc.track].isLocked else { throw EditError.trackLocked }
        let c = tl.tracks[loc.track].clips[loc.clip]
        guard let mid = c.mediaID, let asset = project.asset(mid), asset.kind == .video else { throw EditError.incompatibleTrack }
        guard t >= c.start, t <= c.end else { throw EditError.invalidTime }
        let frame = project.settings.frameRate.frameDuration
        var f = c.resolved(at: (t - c.start).clamped(.zero, c.duration))
        f.id = ClipID()
        f.keyframes = [:]
        f.sourceStart = c.sourceTime(at: t).clamped(.zero, max(.zero, asset.duration - frame))
        f.reversed = false
        f.start = t
        f.duration = duration
        f.speed = .constant(frame / duration)
        f.freezeFrame = true
        f.audio.isMuted = true
        f.transitionOut = nil
        f.animations = ClipAnimations()
        f.name = nil
        f.beats = nil
        f.groupID = nil
        let trackID = tl.tracks[loc.track].id
        let magnetic = tl.tracks[loc.track].isMain && tl.mainTrackMagnet
        // split (when strictly inside)
        var insertAfter: ClipID? = id
        if t - c.start >= minimumClipDuration, c.end - t >= minimumClipDuration {
            _ = try split(id, at: t, in: &tl)
        } else if t - c.start < minimumClipDuration {
            insertAfter = nil
            f.start = c.start
        } else {
            f.start = c.end
        }
        let ti = tl.trackIndex(trackID)!
        let oldMainStarts = mainStarts(tl)
        let idx = insertAfter.flatMap { tl.tracks[ti].clipIndex($0) }.map { $0 + 1 } ?? tl.tracks[ti].clipIndex(id)!
        if !magnetic {
            // ripple following clips on this track
            for j in idx..<tl.tracks[ti].clips.count { tl.tracks[ti].clips[j].start += f.duration }
        }
        if idx > 0 { tl.tracks[ti].clips[idx - 1].transitionOut = nil }
        tl.tracks[ti].clips.insert(f, at: idx)
        if magnetic { compactMain(&tl, previousStarts: oldMainStarts) }
        project.timeline = tl
        return f.id
    }

    /// Freeze clips are generator-like: any duration, the source extent stays one frame.
    static func trimFreeze(_ id: ClipID, edge: TrimEdge, to time: Time, in project: inout Project) throws {
        var tl = project.timeline
        guard let loc = tl.locate(id) else { throw EditError.clipNotFound }
        var c = tl.tracks[loc.track].clips[loc.clip]
        let extent = c.sourceDuration
        let magnetic = tl.tracks[loc.track].isMain && tl.mainTrackMagnet
        let oldMainStarts = mainStarts(tl)
        switch edge {
        case .head:
            var s = min(time, c.end - minimumClipDuration)
            if !magnetic { s = max(s, .zero) }
            c.duration = c.end - s; c.start = s
        case .tail:
            c.duration = max(time, c.start + minimumClipDuration) - c.start
        }
        c.speed = .constant(extent / c.duration)
        if !magnetic {
            let others = tl.tracks[loc.track].clips.enumerated().filter { $0.offset != loc.clip }.map(\.element)
            if others.contains(where: { $0.range.overlaps(c.range) }) { throw EditError.invalidTime }
        }
        tl.tracks[loc.track].clips[loc.clip] = c
        clampTransitions(&tl.tracks[loc.track])
        if tl.mainTrackMagnet { compactMain(&tl, previousStarts: oldMainStarts) }
        project.timeline = tl
    }

    /// CapCut "Reverse": toggles reverse playback and mirrors keyframes in time. (Rendering of reversed media is the
    /// media pipeline's job, see ARCHITECTURE §18.)
    public static func toggleReverse(_ ids: Set<ClipID>, in tl: inout Timeline) throws {
        var did = false
        for id in ids {
            guard var c = tl.clip(id), c.mediaID != nil, !c.isFreezeFrame else { continue }
            c.reversed.toggle()
            for (k, track) in c.keyframes {
                c.keyframes[k] = KeyframeTrack(track.keyframes.map { var f = $0; f.time = c.duration - f.time; return f })
            }
            tl[clip: id] = c
            did = true
        }
        if !did { throw EditError.nothingToDo }
    }

    /// "Deactivate clip" (V): toggles `isEnabled` (all become enabled if any was disabled).
    public static func toggleEnabled(_ ids: Set<ClipID>, in tl: inout Timeline) throws {
        let clips = ids.compactMap { tl.clip($0) }
        guard !clips.isEmpty else { throw EditError.clipNotFound }
        let newValue = !clips.allSatisfy(\.isEnabled)
        for c in clips { tl[clip: c.id]?.isEnabled = newValue }
    }

    // MARK: Gaps

    /// Gap (empty range between clips, or before the first clip) on a track containing `t`.
    public static func gap(at t: Time, on trackID: TrackID, in tl: Timeline) -> TimeRange? {
        guard let ti = tl.trackIndex(trackID) else { return nil }
        var prevEnd = Time.zero
        for c in tl.tracks[ti].clips {
            if t >= prevEnd && t < c.start { return TimeRange(start: prevEnd, end: c.start) }
            prevEnd = max(prevEnd, c.end)
        }
        return nil
    }

    /// "Close gap": shifts everything after the gap left by its length (on that track; main-track linkage follows).
    public static func closeGap(at t: Time, on trackID: TrackID, in tl: inout Timeline) throws {
        guard let g = gap(at: t, on: trackID, in: tl), let ti = tl.trackIndex(trackID) else { throw EditError.nothingToDo }
        guard !tl.tracks[ti].isLocked else { throw EditError.trackLocked }
        for ci in tl.tracks[ti].clips.indices where tl.tracks[ti].clips[ci].start >= g.end {
            tl.tracks[ti].clips[ci].start -= g.duration
            if tl.tracks[ti].isMain, tl.linkage { shiftLinked(to: tl.tracks[ti].clips[ci].id, by: -g.duration, in: &tl) }
        }
    }

    /// "Close all gaps" on a track.
    public static func closeAllGaps(on trackID: TrackID, in tl: inout Timeline) throws {
        var did = false
        while let ti = tl.trackIndex(trackID), let first = tl.tracks[ti].clips.first {
            var probe: Time?
            if first.start > .zero { probe = .zero }
            else {
                var end = first.end
                for c in tl.tracks[ti].clips.dropFirst() { if c.start > end { probe = end; break }; end = max(end, c.end) }
            }
            guard let p = probe else { break }
            try closeGap(at: p, on: trackID, in: &tl)
            did = true
        }
        if !did { throw EditError.nothingToDo }
    }

    // MARK: Roll / slip

    /// Roll edit: moves the cut between `leftID` and the clip right after it to `t` (left tail and right head
    /// together, nothing else moves). Clamped by both clips' media and the minimum duration.
    public static func roll(_ leftID: ClipID, to t: Time, in project: inout Project) throws {
        guard let loc = project.timeline.locate(leftID) else { throw EditError.clipNotFound }
        let track = project.timeline.tracks[loc.track]
        guard !track.isLocked else { throw EditError.trackLocked }
        guard loc.clip + 1 < track.clips.count else { throw EditError.invalidTime }
        let l = track.clips[loc.clip], r = track.clips[loc.clip + 1]
        guard l.transitionOut == nil, l.end == r.start else { throw EditError.invalidTime }
        func limits(_ c: Clip) -> (head: Time, tail: Time) {
            guard let a = c.mediaID.flatMap(project.asset), a.kind != .image, !c.isFreezeFrame else { return (-.indefinite, .indefinite) }
            let rate = c.speed.averageRate
            if c.reversed { return (c.start - (a.duration - c.sourceStart - c.sourceDuration) / rate, c.start + (c.sourceStart + c.sourceDuration) / rate) }
            return (c.start - c.sourceStart / rate, c.start + (a.duration - c.sourceStart) / rate)
        }
        let lt = limits(l).tail, rh = limits(r).head
        let lo = max(l.start + minimumClipDuration, rh), hi = min(r.end - minimumClipDuration, lt)
        guard lo <= hi else { throw EditError.invalidTime }
        let cut = t.clamped(lo, hi)
        guard cut != l.end else { return }
        let magnet = project.timeline.mainTrackMagnet
        project.timeline.mainTrackMagnet = false
        defer { project.timeline.mainTrackMagnet = magnet }
        if cut > l.end {
            try trim(r.id, edge: .head, to: cut, in: &project)
            try trim(l.id, edge: .tail, to: cut, in: &project)
        } else {
            try trim(l.id, edge: .tail, to: cut, in: &project)
            try trim(r.id, edge: .head, to: cut, in: &project)
        }
    }

    /// Slip edit: shifts the media under a clip by `delta` (source time) keeping its timeline position.
    public static func slip(_ id: ClipID, by delta: Time, in project: inout Project) throws {
        guard let loc = project.timeline.locate(id) else { throw EditError.clipNotFound }
        guard !project.timeline.tracks[loc.track].isLocked else { throw EditError.trackLocked }
        var c = project.timeline.tracks[loc.track].clips[loc.clip]
        guard let a = c.mediaID.flatMap(project.asset), a.kind != .image else { throw EditError.incompatibleTrack }
        let maxStart = max(.zero, a.duration - c.sourceDuration)
        let s = (c.sourceStart + delta).clamped(.zero, maxStart)
        guard s != c.sourceStart else { return }
        c.sourceStart = s
        project.timeline.tracks[loc.track].clips[loc.clip] = c
    }

    // MARK: Markers

    @discardableResult
    public static func addMarker(at t: Time, color: RGBA? = nil, in tl: inout Timeline) throws -> MarkerID {
        let near = Time(1.0 / 120)
        guard !tl.markers.contains(where: { abs(($0.time - t).ticks) < near.ticks }) else { throw EditError.nothingToDo }
        var m = Marker(time: max(.zero, t))
        if let color { m.color = color }
        tl.markers.append(m)
        tl.markers.sort { $0.time < $1.time }
        return m.id
    }

    public static func updateMarker(_ id: MarkerID, in tl: inout Timeline, _ body: (inout Marker) -> Void) throws {
        guard let i = tl.markers.firstIndex(where: { $0.id == id }) else { throw EditError.nothingToDo }
        body(&tl.markers[i])
        tl.markers[i].time = max(.zero, tl.markers[i].time)
        tl.markers.sort { $0.time < $1.time }
    }

    public static func removeMarkers(_ ids: Set<MarkerID>, in tl: inout Timeline) throws {
        let n = tl.markers.count
        tl.markers.removeAll { ids.contains($0.id) }
        if tl.markers.count == n { throw EditError.nothingToDo }
    }

    public static func nextMarker(after t: Time, in tl: Timeline) -> Marker? {
        tl.markers.first { $0.time > t + Time(ticks: 1) }
    }
    public static func previousMarker(before t: Time, in tl: Timeline) -> Marker? {
        tl.markers.last { $0.time < t - Time(ticks: 1) }
    }

    /// CapCut marker colour cycle (⌥M "Add marker with new colour").
    public static let markerColors: [RGBA] = [RGBA(hex: 0x00C1CD), RGBA(hex: 0xF2C230), RGBA(hex: 0xE5484D),
                                              RGBA(hex: 0x30A46C), RGBA(hex: 0x8E4EC6), RGBA(hex: 0xF76B15)]

    // MARK: Beats

    /// Toggles a beat marker on a clip at timeline time `t` (removes one within 1/30 s).
    public static func toggleBeat(_ id: ClipID, at t: Time, in tl: inout Timeline) throws {
        guard var c = tl.clip(id), t >= c.start, t <= c.end else { throw EditError.invalidTime }
        let local = t - c.start
        var b = c.beats ?? []
        if let i = b.firstIndex(where: { abs(($0 - local).ticks) < Time(1.0 / 30).ticks }) { b.remove(at: i) }
        else { b.append(local); b.sort() }
        c.beats = b.isEmpty ? nil : b
        tl[clip: id] = c
    }

    public static func clearBeats(_ ids: Set<ClipID>, in tl: inout Timeline) throws {
        var did = false
        for id in ids where tl.clip(id)?.beats != nil { tl[clip: id]?.beats = nil; did = true }
        if !did { throw EditError.nothingToDo }
    }

    // MARK: Extract / restore audio

    /// "Extract audio": copies the clip's audio to an audio track (linked to the clip) and mutes the original.
    @discardableResult
    public static func extractAudio(_ id: ClipID, in project: inout Project) throws -> ClipID {
        var tl = project.timeline
        guard let loc = tl.locate(id) else { throw EditError.clipNotFound }
        let c = tl.tracks[loc.track].clips[loc.clip]
        guard tl.tracks[loc.track].kind == .video, let a = c.mediaID.flatMap(project.asset), a.kind == .video, a.hasAudio,
              !c.audio.isMuted else { throw EditError.nothingToDo }
        var x = Clip(content: c.content, start: c.start, duration: c.duration, sourceStart: c.sourceStart)
        x.name = c.name ?? a.name
        x.speed = c.speed; x.reversed = c.reversed; x.audio = c.audio
        x.keyframes = c.keyframes.filter { $0.key == ParamKey.volume.raw }
        x.extractedFrom = c.id
        x.linkedTo = tl.tracks[loc.track].isMain ? c.id : nil
        let ti: Int
        if let free = tl.tracks.firstIndex(where: { $0.kind == .audio && !$0.isLocked && fits(x.range, in: $0) }) { ti = free }
        else { let nid = addTrack(.audio, to: &tl); ti = tl.trackIndex(nid)! }
        tl.tracks[ti].clips.append(x); tl.tracks[ti].sortClips()
        tl[clip: id]?.audio.isMuted = true
        project.timeline = tl
        return x.id
    }

    /// "Restore audio": deletes the extracted audio clip(s) of `id` and unmutes it.
    public static func restoreAudio(_ id: ClipID, in tl: inout Timeline) throws {
        guard tl.clip(id) != nil else { throw EditError.clipNotFound }
        let extracted = Set(tl.allClips.filter { $0.extractedFrom == id }.map(\.id))
        guard !extracted.isEmpty || tl.clip(id)?.audio.isMuted == true else { throw EditError.nothingToDo }
        for ti in tl.tracks.indices { tl.tracks[ti].clips.removeAll { extracted.contains($0.id) } }
        tl[clip: id]?.audio.isMuted = false
        removeEmptyTracks(&tl)
    }

    // MARK: Replace

    /// "Replace clip": swaps the media keeping position, duration (shortened if the new media is shorter) and attributes.
    public static func replaceMedia(_ id: ClipID, with asset: MediaAsset, in project: inout Project) throws {
        guard let loc = project.timeline.locate(id) else { throw EditError.clipNotFound }
        let kind = project.timeline.tracks[loc.track].kind
        guard kind == .video ? asset.kind != .audio : (kind == .audio && asset.kind != .image) else { throw EditError.incompatibleTrack }
        if project.asset(asset.id) == nil { project.media.append(asset) }
        var c = project.timeline.tracks[loc.track].clips[loc.clip]
        c.content = .media(asset.id)
        c.name = asset.name
        c.sourceStart = .zero
        c.reversed = false
        c.freezeFrame = nil
        if asset.kind != .image {
            let maxOut = c.speed.outputDuration(forSource: asset.duration)
            if c.duration > maxOut { c.duration = max(minimumClipDuration, maxOut) }
        }
        let oldMainStarts = mainStarts(project.timeline)
        project.timeline.tracks[loc.track].clips[loc.clip] = c
        clampTransitions(&project.timeline.tracks[loc.track])
        if project.timeline.mainTrackMagnet { compactMain(&project.timeline, previousStarts: oldMainStarts) }
    }

    // MARK: Arrange layers / tracks

    /// "Arrange layers": moves a non-main visual clip one layer up/down, or to the top/bottom of the overlay stack.
    public static func arrange(_ id: ClipID, _ how: LayerArrangement, in tl: inout Timeline) throws {
        guard let loc = tl.locate(id) else { throw EditError.clipNotFound }
        let track = tl.tracks[loc.track]
        guard !track.isMain, track.kind.isVisual, !track.isLocked else { throw EditError.incompatibleTrack }
        let visual = tl.tracks.indices.filter { tl.tracks[$0].kind.isVisual }
        guard let pos = visual.firstIndex(of: loc.track) else { throw EditError.trackNotFound }
        let mainPos = tl.mainTrackIndex.flatMap { visual.firstIndex(of: $0) } ?? 0
        let clip = tl.tracks[loc.track].clips.remove(at: loc.clip)
        // insertion position in the visual order (new track goes right above `abovePos`)
        let abovePos: Int
        switch how {
        case .forward: abovePos = min(pos + 1, visual.count - 1)
        case .backward: abovePos = max(pos - 2, mainPos)
        case .front: abovePos = visual.count - 1
        case .back: abovePos = mainPos
        }
        let wasAlone = tl.tracks[loc.track].clips.isEmpty
        if wasAlone && ((how == .forward || how == .front) && pos == visual.count - 1 || (how == .backward || how == .back) && pos == mainPos + 1) {
            tl.tracks[loc.track].clips.insert(clip, at: loc.clip); throw EditError.nothingToDo
        }
        let nid = addTrack(track.kind, to: &tl, above: visual[abovePos])
        tl.tracks[tl.trackIndex(nid)!].clips = [clip]
        removeEmptyTracks(&tl)
    }

    /// Track drag-reorder: moves a non-main visual track so it sits right above `target` (nil = top of the stack).
    public static func reorderTrack(_ id: TrackID, above target: TrackID?, in tl: inout Timeline) throws {
        guard let from = tl.trackIndex(id), !tl.tracks[from].isMain, tl.tracks[from].kind.isVisual else { throw EditError.incompatibleTrack }
        if let target, target == id { throw EditError.nothingToDo }
        let t = tl.tracks.remove(at: from)
        if let target, let ti = tl.trackIndex(target) { tl.tracks.insert(t, at: ti + 1) }
        else { tl.tracks.append(t) }
        // keep overlays above the main track
        if let mi = tl.mainTrackIndex, let ni = tl.trackIndex(id), ni < mi { tl.tracks.remove(at: ni); tl.tracks.insert(t, at: mi) }
        if tl.trackIndex(id) == from { throw EditError.nothingToDo }
    }

    // MARK: In / out

    public static func setRangePoint(in isIn: Bool, at t: Time?, in tl: inout Timeline) {
        if isIn { tl.inPoint = t; if let t, let o = tl.outPoint, o <= t { tl.outPoint = nil } }
        else { tl.outPoint = t; if let t, let i = tl.inPoint, i >= t { tl.inPoint = nil } }
    }
}
