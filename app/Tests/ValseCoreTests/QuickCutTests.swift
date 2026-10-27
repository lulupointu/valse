import Testing
import Foundation
@testable import ValseCore

/// TL-048 Quick cut: mask model, planner (pure, per slider change) and apply (one edit).
@Suite struct QuickCutTests {
    func ok(_ p: Project) { #expect(TimelineOps.validate(p.timeline).isEmpty, "\(TimelineOps.validate(p.timeline))") }

    /// Mask of `seconds` of media with speech in the given source spans.
    static func mask(_ seconds: Double, _ speech: [(Double, Double)], dynamics: Bool = true) -> QuickCutMask {
        let n = Int((seconds * 100).rounded())
        var m = [Bool](repeating: false, count: n)
        for (a, b) in speech { for k in Int((a * 100).rounded())..<min(n, Int((b * 100).rounded())) { m[k] = true } }
        return QuickCutMask(speech: m, hasDynamics: dynamics)
    }

    /// One main-track clip of a 10 s video (with audio), 10 s long.
    static func oneClip(seconds: Double = 10) -> (Project, Clip) {
        let (p, ids) = Fx.project(mainClips: 1, seconds: seconds)
        return (p, p.timeline.clip(ids[0])!)
    }

    static func near(_ r: [TimeRange], _ e: [(Double, Double)], tol: Double = 0.011) -> Bool {
        guard r.count == e.count else { return false }
        return zip(r, e).allSatisfy { abs($0.start.seconds - $1.0) <= tol && abs($0.end.seconds - $1.1) <= tol }
    }

    func plan(_ p: Project, _ x: Double, _ masks: [MediaID: QuickCutMask], selection: Set<ClipID> = []) -> QuickCutPlan {
        QuickCut.plan(p, targets: QuickCut.targets(p, selection: selection), maxBlank: x, masks: masks)
    }

    // MARK: Mask

    @Test func maskBitsRunsAndCoding() throws {
        var bools = (0..<1000).map { i in (i / 37) % 3 != 0 }
        bools[0] = true; bools[999] = true
        for i in 128..<200 { bools[i] = true }   // a run across word boundaries
        let m = QuickCutMask(speech: bools, hasDynamics: true)
        #expect(m.speech == bools)
        // runs = maximal true spans
        var expected: [Range<Int>] = []
        var i = 0
        while i < bools.count { if bools[i] { var j = i; while j < bools.count && bools[j] { j += 1 }; expected.append(i..<j); i = j } else { i += 1 } }
        #expect(m.speechRuns == expected)
        let d = try JSONEncoder().encode(m)
        #expect(d.count < 400)   // compact: 1 bit per frame (1000 frames = 125 B, base64 in JSON)
        let back = try JSONDecoder().decode(QuickCutMask.self, from: d)
        #expect(back == m)
        #expect(QuickCutMask(speech: [Bool](repeating: true, count: 64), hasDynamics: true).speechRuns == [0..<64])
        #expect(QuickCutMask(speech: [Bool](repeating: false, count: 65), hasDynamics: true).speechRuns.isEmpty)
    }

    // MARK: Plan

    @Test func handlesAndEdgeRule() {
        let (p, c) = Self.oneClip()
        let masks = [c.mediaID!: Self.mask(10, [(0.5, 2), (4, 6), (8, 9.5)])]
        let plan = plan(p, 0.3, masks)
        // leading / trailing runs keep only the speech-side handle; inner runs keep 50 ms after and 50 ms before speech
        // (owner decision 2026-10-23: a cut pause plays as 0.1 s, symmetric)
        #expect(Self.near(plan.slices(for: c.id), [(0, 0.45), (2.05, 3.95), (6.05, 7.95), (9.55, 10)]), "\(plan.slices(for: c.id))")
        #expect(plan.count == 4)
        #expect(QuickCut.handleBefore == 0.05 && QuickCut.handleAfter == 0.05)
        // what is left of each inner pause after the cut: 0.1 s, split evenly around the cut point
        let inner = plan.slices(for: c.id).dropFirst().dropLast()
        for (sl, gap) in zip(inner, [(2.0, 4.0), (6.0, 8.0)]) {
            #expect(abs((sl.start.seconds - gap.0) - 0.05) < 0.011 && abs((gap.1 - sl.end.seconds) - 0.05) < 0.011)
        }
        #expect(abs(plan.removed.seconds - (0.45 + 1.9 + 1.9 + 0.45)) < 0.03)
        // raw length must be MORE than X: the 0.5 s leading blank no longer qualifies at X = 0.5
        #expect(Self.near(self.plan(p, 0.5, masks).slices(for: c.id), [(2.05, 3.95), (6.05, 7.95)]))
        #expect(self.plan(p, 2.5, masks).isEmpty)
    }

    @Test func shortSlicesAreDropped() {
        let (p, c) = Self.oneClip()
        // 0.13 s inner blank: 0.13 − 0.05 − 0.05 = 0.03 s < 40 ms → nothing removed
        let masks = [c.mediaID!: Self.mask(10, [(0, 5), (5.13, 10)])]
        #expect(plan(p, 0.1, masks).isEmpty)
        let masks2 = [c.mediaID!: Self.mask(10, [(0, 5), (5.15, 10)])]
        #expect(Self.near(plan(p, 0.1, masks2).slices(for: c.id), [(5.05, 5.10)]))
    }

    @Test func speedTwiceMapsSourceToTimeline() throws {
        var (p, c) = Self.oneClip()
        try TimelineOps.setSpeed(c.id, .constant(2), in: &p.timeline)   // 10 s of source in 5 s
        let c2 = p.timeline.clip(c.id)!
        #expect(abs(c2.duration.seconds - 5) < 0.001)
        let masks = [c.mediaID!: Self.mask(10, [(0, 2), (4, 6), (8, 10)])]
        // source gaps [2,4] and [6,8] → timeline [1,2] and [3,4]
        #expect(Self.near(plan(p, 0.5, masks).slices(for: c.id), [(1.05, 1.95), (3.05, 3.95)]))
    }

    @Test func reversedClipMirrorsTheMask() {
        var (p, c) = Self.oneClip()
        p.timeline[clip: c.id]?.reversed = true
        let masks = [c.mediaID!: Self.mask(10, [(0, 7), (8, 10)])]
        // source gap [7,8] plays at timeline [2,3]
        #expect(Self.near(plan(p, 0.5, masks).slices(for: c.id), [(2.05, 2.95)]))
    }

    @Test func trimmedClipUsesItsSourceRange() {
        var (p, c) = Self.oneClip(seconds: 4)
        p.timeline[clip: c.id]?.sourceStart = Time(3)   // plays source 3 … 7
        let masks = [c.mediaID!: Self.mask(10, [(0, 4), (5.5, 10)])]
        #expect(Self.near(plan(p, 0.5, masks).slices(for: c.id), [(1.05, 2.45)]))
    }

    @Test func mutedRangeByVolumeKeyframeIsBlank() {
        var (p, c) = Self.oneClip()
        var kf = KeyframeTrack()
        kf.set(.scalar(1), at: Time(0)); kf.set(.scalar(1), at: Time(4)); kf.set(.scalar(0), at: Time(4.01))
        kf.set(.scalar(0), at: Time(6)); kf.set(.scalar(1), at: Time(6.01))
        p.timeline[clip: c.id]?.keyframes[ParamKey.volume.raw] = kf
        let masks = [c.mediaID!: Self.mask(10, [(0, 10)])]   // talking all along
        let s = plan(p, 0.5, masks).slices(for: c.id)
        #expect(Self.near(s, [(4.06, 5.95)], tol: 0.02), "\(s)")
        // whole clip at 0 volume or muted: nothing heard = no speech = untouched
        p.timeline[clip: c.id]?.keyframes = [:]
        p.timeline[clip: c.id]?.audio.volume = 0.005
        #expect(plan(p, 0.5, masks).isEmpty)
        p.timeline[clip: c.id]?.audio.volume = 1
        p.timeline[clip: c.id]?.audio.isMuted = true
        #expect(plan(p, 0.5, masks).isEmpty)
    }

    @Test func fadeTailIsBlank() {
        var (p, c) = Self.oneClip()
        p.timeline[clip: c.id]?.audio.volume = 0.02          // −34 dB
        p.timeline[clip: c.id]?.audio.fadeOut = Time(4)      // under −40 dB for the last 2 s
        p.timeline[clip: c.id]?.audio.fadeIn = Time(1)       // under −40 dB for the first 0.5 s
        let masks = [c.mediaID!: Self.mask(10, [(0, 10)])]
        let s = plan(p, 0.3, masks).slices(for: c.id)
        #expect(Self.near(s, [(0, 0.45), (8.05, 10)], tol: 0.02), "\(s)")
        // uniform volume changes don't matter (detection is relative per media)
        p.timeline[clip: c.id]?.audio.fadeOut = .zero
        p.timeline[clip: c.id]?.audio.fadeIn = .zero
        #expect(plan(p, 0.3, masks).isEmpty)
    }

    @Test func wholeClipUntouchedWithoutSpeechOrDynamics() {
        let (p, c) = Self.oneClip()
        #expect(plan(p, 0.3, [c.mediaID!: Self.mask(10, [])]).isEmpty)
        #expect(plan(p, 0.3, [c.mediaID!: Self.mask(10, [(1, 2)], dynamics: false)]).isEmpty)
        #expect(plan(p, 0.3, [c.mediaID!: .empty]).isEmpty)
        // not analysed yet: pending, not cut
        let pending = plan(p, 0.3, [:])
        #expect(pending.isEmpty && pending.pending == [c.mediaID!])
    }

    @Test func clipsWithoutAudioAreNotTargets() {
        var (p, _) = Fx.project(mainClips: 2, seconds: 4)
        p.media[0].hasAudio = false
        let t = QuickCut.targets(p, selection: [])
        #expect(t.count == 1 && t[0].primary == p.timeline.mainTrack!.clips[1].id)
        #expect(QuickCut.media(of: t, in: p).map(\.id) == [p.media[1].id])
    }

    @Test func selectionScope() throws {
        var (p, ids) = Fx.project(mainClips: 2, seconds: 4)
        let a = Fx.audio("music", seconds: 30)
        p.media.append(a)
        try TimelineOps.insert(TimelineOps.makeClip(for: a, at: Time(1)), into: &p)
        let audioID = p.timeline.tracks.first { $0.kind == .audio }!.clips[0].id
        #expect(QuickCut.targets(p, selection: []).count == 3)
        #expect(QuickCut.targets(p, selection: [audioID]).map(\.primary) == [audioID])
        let two = Set(QuickCut.targets(p, selection: [ids[1], audioID]).map(\.primary))
        #expect(two == [ids[1], audioID])
        // a selected text clip is not a media clip: nothing
        var t = TextContent(string: "Hi", fontSize: 0.09); t.bold = true
        let text = Clip(content: .text(t), start: .zero, duration: Time(2))
        let tt = TimelineOps.addTrack(.text, to: &p.timeline)
        try TimelineOps.insert(text, into: &p, target: .track(tt))
        #expect(QuickCut.targets(p, selection: [text.id]).isEmpty)
    }

    /// Video whose audio was extracted: the extracted clip is what is heard; both are cut together.
    @Test func detachedAudioIsAnalysedAndCutWithItsVideo() throws {
        var (p, c) = Self.oneClip()
        let audioID = try TimelineOps.extractAudio(c.id, in: &p)
        #expect(p.timeline.clip(c.id)!.audio.isMuted)
        let targets = QuickCut.targets(p, selection: [audioID])
        #expect(targets == [QuickCutTarget(primary: c.id, members: [c.id, audioID])])
        #expect(QuickCut.targets(p, selection: [c.id]) == targets)
        let masks = [c.mediaID!: Self.mask(10, [(0, 2), (4, 6), (8, 10)])]
        let plan = QuickCut.plan(p, targets: targets, maxBlank: 0.5, masks: masks)
        #expect(Self.near(plan.slices(for: c.id), [(2.05, 3.95), (6.05, 7.95)]))
        #expect(plan.slices(for: audioID) == plan.slices(for: c.id))
        // muting the extracted audio instead: nothing heard any more → untouched
        var q = p
        q.timeline[clip: audioID]?.audio.isMuted = true
        #expect(QuickCut.plan(q, targets: targets, maxBlank: 0.5, masks: masks).isEmpty)

        try QuickCut.apply(plan, to: &p)
        ok(p)
        let video = p.timeline.mainTrack!.clips
        let audio = p.timeline.tracks.first { $0.kind == .audio }!.clips
        #expect(video.count == 3 && audio.count == 3)
        #expect(abs(p.timeline.mainTrack!.end.seconds - (10 - 3.8)) < 0.01)
        for (v, a) in zip(video, audio) {
            #expect(v.start == a.start && v.duration == a.duration && v.sourceStart == a.sourceStart)
            #expect(a.linkedTo == v.id)
        }
    }

    // MARK: Apply

    @Test func mainTrackRipplesAndCaptionsFollow() throws {
        var (p, ids) = Fx.project(mainClips: 1, seconds: 8)
        let words = SpeechCaptionTests.words()
        let segs = SpeechCaptions.segments(Transcript(engine: "t", language: "fr", words: words), for: p.timeline.clip(ids[0])!)
        let capTrack = try #require(CaptionOps.addCaptionTrack(segs, to: &p, origin: .auto, replacing: true))
        SpeechCaptions.finish(trackID: capTrack, in: &p)
        let mid = p.timeline.clip(ids[0])!.mediaID!
        // speech = the words; pause 1.1 … 2.0 s and the tail after 6.5 s
        let masks = [mid: Self.mask(10, words.map { (Double($0.start), Double($0.end)) })]
        let plan = plan(p, 0.5, masks)
        #expect(Self.near(plan.slices(for: ids[0]), [(1.15, 1.95), (6.55, 8)]), "\(plan.slices(for: ids[0]))")
        let startOf = { (p: Project) in SpeechCaptions.captions(in: p.timeline).first { CaptionOps.text($0)?.string.hasPrefix("Aujourd") == true }!.start.seconds }
        let before = startOf(p)
        try QuickCut.apply(plan, to: &p)
        ok(p)
        #expect(abs(p.timeline.mainTrack!.end.seconds - (8 - plan.removed.seconds)) < 0.01)
        #expect(abs(startOf(p) - (before - 0.8)) < 0.02)   // captions moved with the cut
        #expect(SpeechCaptions.captions(in: p.timeline).allSatisfy { $0.end.seconds <= p.timeline.mainTrack!.end.seconds + 0.01 })
    }

    @Test func otherTrackClosesUpInsideItsFootprint() throws {
        var (p, _) = Self.oneClip(seconds: 20)
        p.timeline.linkage = false
        let vo = Fx.audio("voice", seconds: 30), later = Fx.audio("later", seconds: 30)
        p.media += [vo, later]
        var a = TimelineOps.makeClip(for: vo, at: Time(1)); a.duration = Time(10)
        try TimelineOps.insert(a, into: &p)
        let track = p.timeline.tracks.first { $0.kind == .audio }!.id
        var b = TimelineOps.makeClip(for: later, at: Time(12)); b.duration = Time(3)
        try TimelineOps.insert(b, into: &p, target: .track(track))
        let masks = [vo.id: Self.mask(30, [(0, 3), (5, 10)]), later.id: Self.mask(30, [(0, 0.2), (2, 30)])]
        let plan = plan(p, 0.5, masks, selection: [a.id, b.id])
        #expect(Self.near(plan.slices(for: a.id), [(4.05, 5.95)]))
        #expect(Self.near(plan.slices(for: b.id), [(12.25, 13.95)]))
        let mainBefore = p.timeline.mainTrack!.clips
        try QuickCut.apply(plan, to: &p)
        ok(p)
        let clips = p.timeline.tracks[p.timeline.trackIndex(track)!].clips
        #expect(clips.count == 4)
        // pieces of `a` packed from its start, `b` too; nothing moves outside the footprints, main track untouched
        #expect(abs(clips[0].start.seconds - 1) < 0.001 && abs(clips[1].start.seconds - clips[0].end.seconds) < 0.001)
        #expect(abs(clips[1].end.seconds - (11 - 1.9)) < 0.011)
        #expect(abs(clips[1].sourceStart.seconds - 4.95) < 0.011)   // the second piece plays from after the blank
        #expect(abs(clips[2].start.seconds - 12) < 0.001 && abs(clips[3].start.seconds - clips[2].end.seconds) < 0.001)
        #expect(p.timeline.mainTrack!.clips == mainBefore)
    }

    @Test func linkedTitleInsideARemovedRangeIsKept() throws {
        var (p, c) = Self.oneClip()
        let tt = TimelineOps.addTrack(.text, to: &p.timeline)
        let title = Clip(content: .text(TextContent(string: "Title", fontSize: 0.09)), start: Time(3), duration: Time(1))
        try TimelineOps.insert(title, into: &p, target: .track(tt))
        #expect(p.timeline.clip(title.id)?.linkedTo == c.id)
        let after = Clip(content: .text(TextContent(string: "After", fontSize: 0.09)), start: Time(7), duration: Time(1))
        try TimelineOps.insert(after, into: &p, target: .track(tt))
        let masks = [c.mediaID!: Self.mask(10, [(0, 2), (5, 10)])]
        let plan = plan(p, 0.5, masks)
        #expect(Self.near(plan.slices(for: c.id), [(2.05, 4.95)]))
        try QuickCut.apply(plan, to: &p)
        ok(p)
        let t = try #require(p.timeline.clip(title.id))
        #expect(abs(t.start.seconds - 2.05) < 0.01)   // at the cut point
        #expect(t.linkedTo != nil)
        #expect(abs(p.timeline.clip(after.id)!.start.seconds - (7 - 2.9)) < 0.01)   // followed its main piece
    }

    /// A closed-up overlay piece that reaches past a main-track cut stays with the main piece under its start, while the
    /// next piece moves left with the ripple: it must not end up overlapping (AVFoundation volume ramps throw on that).
    @Test func linkedPiecesNeverOverlapAfterTheRipple() throws {
        var (p, c) = Self.oneClip()
        let pip = Fx.video("pip")
        p.media.append(pip)
        var o = TimelineOps.makeClip(for: pip, at: Time(2)); o.duration = Time(7)
        let overlayTrack = try TimelineOps.insert(o, into: &p, target: .newTrack)
        let masks = [c.mediaID!: Self.mask(10, [(0, 4), (4.6, 10)]), pip.id: Self.mask(10, [(0, 3), (3.6, 10)])]
        let plan = plan(p, 0.3, masks)
        #expect(Self.near(plan.slices(for: c.id), [(4.05, 4.55)]))
        #expect(Self.near(plan.slices(for: o.id), [(5.05, 5.55)]))
        try QuickCut.apply(plan, to: &p)
        ok(p)
        let pieces = p.timeline.tracks.filter { !$0.isMain && $0.kind == .video }.flatMap(\.clips).sorted { $0.start < $1.start }
        #expect(pieces.count == 2)
        // nothing lost or shifted in time: the first piece keeps its place, the second one follows the ripple
        #expect(abs(pieces[0].start.seconds - 2) < 0.001 && abs(pieces[0].end.seconds - 5.05) < 0.011)
        #expect(abs(pieces[1].start.seconds - (5.05 - 0.5)) < 0.011 && abs(pieces[1].duration.seconds - 3.45) < 0.011)
        #expect(p.timeline.trackIndex(overlayTrack) != nil)
    }

    @Test func applyIsOneUndoStep() throws {
        let (p, c) = Self.oneClip()
        let plan = plan(p, 0.3, [c.mediaID!: Self.mask(10, [(0.5, 2), (4, 6), (8, 9.5)])])
        var s = EditSession(project: p)
        try s.perform(ApplyQuickCut(plan))
        #expect(s.undoStack.count == 1 && s.undoNameKey == "cmd.quickCut")
        #expect(s.project.timeline.mainTrack!.clips.count == 3)
        s.undo()
        #expect(s.project == p)
        // an empty plan changes nothing and records nothing
        #expect(throws: EditError.nothingToDo) { try s.perform(ApplyQuickCut(QuickCutPlan(maxBlank: 1))) }
        #expect(s.undoStack.isEmpty)
    }

    // MARK: Speed

    /// 30 clips × 5 min (2.5 h of rushes): a full re-plan must fit in a slider tick (< 2 ms in release).
    @Test func planIsFastEnoughForTheSlider() {
        var p = Project(name: "perf")
        var masks: [MediaID: QuickCutMask] = [:]
        var rng = SystemRandomNumberGenerator()
        for i in 0..<30 {
            var a = Fx.video("r\(i)", seconds: 300)
            a.hasAudio = true
            p.media.append(a)
            var c = TimelineOps.makeClip(for: a, at: Time(100_000))
            c.duration = Time(300)
            try! TimelineOps.insert(c, into: &p)
            // speech-like: 0.3 … 4 s of speech, 0.05 … 2 s of pause
            var bools: [Bool] = []
            while bools.count < 30_000 {
                bools += [Bool](repeating: true, count: Int.random(in: 30...400, using: &rng))
                bools += [Bool](repeating: false, count: Int.random(in: 5...200, using: &rng))
            }
            masks[a.id] = QuickCutMask(speech: Array(bools.prefix(30_000)), hasDynamics: true)
        }
        let targets = QuickCut.targets(p, selection: [])
        #expect(targets.count == 30)
        var best = Double.infinity
        var plan = QuickCutPlan(maxBlank: 0)
        for k in 0..<5 {
            let t0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            plan = QuickCut.plan(p, targets: targets, maxBlank: 0.3 + Double(k) * 0.1, masks: masks)
            best = min(best, Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - t0) / 1e6)
        }
        #expect(plan.count > 1000)
        print("{\"stack\":\"valse\",\"metric\":\"unit_quickcut_plan_30x5min_ms\",\"value\":\((best * 100).rounded() / 100),\"unit\":\"ms\"}")
        // thread CPU time (load-robust). Release builds measure well under 2 ms; debug builds (the test gate) are
        // unoptimised, so the gross bound is 10× the budget.
        #if DEBUG
        #expect(best < 20, "plan took \(best) ms")
        #else
        #expect(best < 2 * 4, "plan took \(best) ms")
        #endif
    }

    /// Apply of ~300 cuts on 30 clips: < 300 ms (§5).
    @Test func applyManyCutsIsQuick() throws {
        var p = Project(name: "apply")
        var masks: [MediaID: QuickCutMask] = [:]
        for i in 0..<30 {
            let a = Fx.video("r\(i)", seconds: 60)
            p.media.append(a)
            var c = TimelineOps.makeClip(for: a, at: Time(100_000))
            c.duration = Time(60)
            try TimelineOps.insert(c, into: &p)
            masks[a.id] = Self.mask(60, (0..<10).map { k in (Double(k) * 6, Double(k) * 6 + 4.5) })
        }
        let plan = QuickCut.plan(p, targets: QuickCut.targets(p, selection: []), maxBlank: 0.5, masks: masks)
        #expect(plan.count == 300)
        let t0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        try QuickCut.apply(plan, to: &p)
        let ms = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - t0) / 1e6
        print("{\"stack\":\"valse\",\"metric\":\"unit_quickcut_apply_300_ms\",\"value\":\((ms * 100).rounded() / 100),\"unit\":\"ms\"}")
        ok(p)
        #expect(p.timeline.mainTrack!.clips.count == 30 * 10)
        #expect(abs(p.timeline.duration.seconds - (1800 - plan.removed.seconds)) < 0.1)
        #if !DEBUG
        #expect(ms < 300 * 4)
        #endif
    }
}
