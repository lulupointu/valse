import Testing
import Foundation
@testable import MontageCore

/// BUG-AUTOCAPTION-SHIFT: adding generated captions (auto captions, lyrics, scripts, imported subtitle files, a second
/// generation over existing captions) never moves, trims or re-tracks a clip that was already on the timeline.
@Suite struct CaptionInsertionStabilityTests {
    struct Place: Equatable, CustomStringConvertible {
        let track: TrackID, start: Time, duration: Time, sourceStart: Time
        var description: String { "track \(track) \(start.seconds)+\(duration.seconds) src \(sourceStart.seconds)" }
    }

    static func places(_ tl: Timeline, where keep: (Clip) -> Bool = { _ in true }) -> [ClipID: Place] {
        var out: [ClipID: Place] = [:]
        for t in tl.tracks { for c in t.clips where keep(c) {
            out[c.id] = Place(track: t.id, start: c.start, duration: c.duration, sourceStart: c.sourceStart)
        } }
        return out
    }

    /// Every clip of `before` is still there, on the same track, at the same time.
    static func unchanged(_ before: [ClipID: Place], in tl: Timeline, sourceLocation: SourceLocation = #_sourceLocation) {
        let after = places(tl)
        for (id, b) in before {
            #expect(after[id] == b, "clip \(id) moved: \(b) → \(after[id].map(\.description) ?? "removed")", sourceLocation: sourceLocation)
        }
    }

    /// Pre-existing tracks keep their relative order (a new track may be inserted between them).
    static func sameOrder(_ before: Timeline, _ after: Timeline, sourceLocation: SourceLocation = #_sourceLocation) {
        let old = before.tracks.map(\.id)
        let kept = after.tracks.map(\.id).filter(old.contains)
        #expect(kept == old.filter(kept.contains), "track order changed", sourceLocation: sourceLocation)
    }

    static func text(_ s: String, _ start: Double, _ d: Double) -> Clip {
        var c = Clip(content: .text(TextContent(string: s, fontSize: 0.08)), start: Time(start), duration: Time(d))
        c.name = s
        return c
    }

    /// Busy timeline: 3 magnetic main clips (0–12 s), a PiP overlay, a voice-over, a title + a sticker overlapping the
    /// caption range, a locked text track. Linkage on: overlays are linked to the main clips.
    static func busy() throws -> Project {
        var (p, _) = Fx.project(mainClips: 3, seconds: 4)
        p.timeline.mainTrackMagnet = true
        p.timeline.linkage = true
        let pip = Fx.video("pip"), vo = Fx.audio("vo")
        p.media += [pip, vo]
        var o = TimelineOps.makeClip(for: pip, at: Time(2)); o.duration = Time(3)
        try TimelineOps.insert(o, into: &p, target: .newTrack)
        var a = TimelineOps.makeClip(for: vo, at: Time(1)); a.duration = Time(6)
        try TimelineOps.insert(a, into: &p)
        try TimelineOps.insert(text("Title", 1, 4), into: &p, target: .newTrack)
        try TimelineOps.insert(Clip(content: .sticker(id: "emoji.smile"), start: Time(3), duration: Time(3)), into: &p, target: .newTrack)
        let locked = try TimelineOps.insert(text("Locked", 0, 12), into: &p, target: .newTrack)
        p.timeline.tracks[p.timeline.trackIndex(locked)!].isLocked = true
        #expect(TimelineOps.validate(p.timeline).isEmpty)
        return p
    }

    static func speech(_ words: [String], from start: Double, step: Double = 1.5) -> [CaptionSegment] {
        words.enumerated().map { i, w in
            let s = start + Double(i) * step
            return CaptionSegment(text: w, start: s, end: s + step - 0.2, words: [(w, s, s + step - 0.2)])
        }
    }

    /// The generated-caption edit (`CaptionGenerator.insert` without the speaker step, which lives in MontageAI).
    @discardableResult
    static func generate(_ segs: [CaptionSegment], origin: CaptionOrigin = .auto, replacing: Bool, in p: inout Project) -> TrackID? {
        guard let id = CaptionOps.addCaptionTrack(segs, to: &p, origin: origin, replacing: replacing) else { return nil }
        SpeechCaptions.finish(trackID: id, in: &p)
        return id
    }

    @Test func autoCaptionsLeaveEveryExistingClipInPlace() throws {
        var p = try Self.busy()
        let before = p.timeline
        let snap = Self.places(before)
        // captions all over the timeline, incl. from 0 and past the end of the main track
        let id = try #require(Self.generate(Self.speech(["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"], from: 0),
                                            replacing: true, in: &p))
        Self.unchanged(snap, in: p.timeline)
        Self.sameOrder(before, p.timeline)
        #expect(TimelineOps.validate(p.timeline).isEmpty)
        // a new text track directly above the main track holds only the captions
        let ti = try #require(p.timeline.trackIndex(id))
        #expect(p.timeline.tracks.count == before.tracks.count + 1)
        #expect(ti == before.mainTrackIndex! + 1)
        #expect(p.timeline.tracks[ti].kind == .text && p.timeline.tracks[ti].clips.allSatisfy(CaptionOps.isCaption))
        #expect(!before.tracks.contains { $0.id == id })
        // the title / sticker / locked text overlapping the caption range are untouched (content too)
        for t in before.tracks { for c in t.clips { #expect(p.timeline.clip(c.id) == c) } }
    }

    @Test func secondGenerationReplacesOnlyCaptions() throws {
        var p = try Self.busy()
        Self.generate(Self.speech(["a", "b", "c", "d"], from: 0.5), replacing: true, in: &p)
        let nonCaption = Self.places(p.timeline) { !CaptionOps.isCaption($0) }
        let before = p.timeline
        // "Delete current captions" on: the old auto captions go, everything else stays put
        Self.generate(Self.speech(["e", "f", "g", "h", "i"], from: 0.2, step: 1.1), replacing: true, in: &p)
        Self.unchanged(nonCaption, in: p.timeline)
        Self.sameOrder(before, p.timeline)
        #expect(CaptionOps.captionTracks(p.timeline).count == 1)
        #expect(SpeechCaptions.captions(in: p.timeline).map { CaptionOps.text($0)?.string } == ["e", "f", "g", "h", "i"])
        #expect(TimelineOps.validate(p.timeline).isEmpty)
    }

    @Test func secondGenerationWithoutReplacingKeepsOldCaptionsToo() throws {
        var p = try Self.busy()
        Self.generate(Self.speech(["a", "b", "c", "d"], from: 0.5), replacing: true, in: &p)
        let all = Self.places(p.timeline)
        let before = p.timeline
        let second = try #require(Self.generate(Self.speech(["e", "f", "g"], from: 0.2), replacing: false, in: &p))
        Self.unchanged(all, in: p.timeline)   // the first captions too
        Self.sameOrder(before, p.timeline)
        #expect(CaptionOps.captionTracks(p.timeline).count == 2)
        #expect(!before.tracks.contains { $0.id == second })
        #expect(TimelineOps.validate(p.timeline).isEmpty)
    }

    @Test func replacingKeepsATitleDroppedOnTheCaptionTrack() throws {
        var p = try Self.busy()
        let first = try #require(Self.generate(Self.speech(["a", "b"], from: 0.5), replacing: true, in: &p))
        // the user dropped a title on the caption track after the captions, and added script captions elsewhere
        let title = Self.text("On caption track", 8, 2)
        try TimelineOps.insert(title, into: &p, target: .track(first))
        #expect(p.timeline.locate(title.id).map { p.timeline.tracks[$0.track].id } == first)
        Self.generate(Self.speech(["script"], from: 5), origin: .script, replacing: false, in: &p)
        let kept = Self.places(p.timeline) { CaptionOps.text($0)?.caption?.origin != .auto }
        let before = p.timeline
        Self.generate(Self.speech(["x", "y", "z"], from: 0.3), replacing: true, in: &p)
        Self.unchanged(kept, in: p.timeline)   // the title stays on its track, the script captions stay
        Self.sameOrder(before, p.timeline)
        // no duplicate: the old auto captions are gone even though their track survives for the title
        let auto = SpeechCaptions.captions(in: p.timeline).filter { CaptionOps.text($0)?.caption?.origin == .auto }
        #expect(auto.map { CaptionOps.text($0)?.string } == ["x", "y", "z"])
        #expect(p.timeline.trackIndex(first).map { p.timeline.tracks[$0].clips.map(\.id) } == [title.id])
        #expect(TimelineOps.validate(p.timeline).isEmpty)
    }

    @Test func otherCaptionSourcesLeaveExistingClipsInPlace() throws {
        var p = try Self.busy()
        Self.generate(Self.speech(["a", "b"], from: 0.5), replacing: true, in: &p)
        // lyrics, script (AI writer / align script), imported SRT (CaptionOps) and imported caption file (CaptionFile)
        for origin in [CaptionOrigin.lyrics, .script] {
            let snap = Self.places(p.timeline), before = p.timeline
            #expect(Self.generate(Self.speech(["l1", "l2", "l3"], from: 1), origin: origin, replacing: true, in: &p) != nil)
            Self.unchanged(snap, in: p.timeline)
            Self.sameOrder(before, p.timeline)
        }
        let snap = Self.places(p.timeline), before = p.timeline
        let segs = try CaptionFiles.parse("1\n00:00:01,000 --> 00:00:03,000\nHello\n\n2\n00:00:02,500 --> 00:00:05,000\nWorld\n", format: .srt)
        #expect(CaptionOps.addCaptionTrack(segs, to: &p, origin: .imported) != nil)
        Self.unchanged(snap, in: p.timeline)
        Self.sameOrder(before, p.timeline)
        let snap2 = Self.places(p.timeline), before2 = p.timeline
        try CaptionFile.insert([CaptionCue(start: Time(0), end: Time(2), text: "Hi"), CaptionCue(start: Time(1.5), end: Time(4), text: "there")],
                               into: &p)
        Self.unchanged(snap2, in: p.timeline)
        Self.sameOrder(before2, p.timeline)
        #expect(TimelineOps.validate(p.timeline).isEmpty)
    }

    @Test func captionsOnAnEmptyOrFreeTimelineAndAfterUndo() throws {
        // free main track (magnet off, gaps) + nothing else: still a new track, the main clips keep their gaps
        var (p, ids) = Fx.project(mainClips: 2, seconds: 3)
        p.timeline.mainTrackMagnet = false
        let mi = p.timeline.mainTrackIndex!
        p.timeline.tracks[mi].clips[1].start = Time(5)
        let snap = Self.places(p.timeline)
        var session = EditSession(project: p)
        try session.perform(Edit("cmd.captions") { p in
            guard Self.generate(Self.speech(["a", "b", "c", "d", "e", "f"], from: 0), replacing: true, in: &p) != nil else {
                throw EditError.nothingToDo
            }
        })
        Self.unchanged(snap, in: session.project.timeline)
        #expect(session.project.timeline.clip(ids[1])?.start == Time(5))
        _ = session.undo()
        #expect(session.project == p)
    }
}
