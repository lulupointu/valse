import Testing
import Foundation
@testable import MontageCore

/// C4: "Remove filler words" in timeline time (pauses at clip edges, across cuts, scope), captions following the cuts,
/// "Apply to all main captions" (CaptionStyleSync + EditSession.postProcess), caption list ＋ / 🗑.
@Suite struct FillerCleanupTests {
    func ok(_ p: Project) { #expect(TimelineOps.validate(p.timeline).isEmpty, "\(TimelineOps.validate(p.timeline))") }
    func w(_ s: [(String, Double, Double)]) -> [TranscriptWord] { s.map { TranscriptWord(text: $0.0, start: $0.1, end: $0.2) } }

    /// Two 8 s speech clips: A speaks 1.5 → 5.0 s (1.5 s of silence first, 3 s after), B speaks 2.0 → 4.0 s.
    func twoClips() -> (Project, [ClipID], [MediaID: Transcript]) {
        let (p, ids) = Fx.project(mainClips: 2, seconds: 8)
        let a = p.timeline.clip(ids[0])!.mediaID!, b = p.timeline.clip(ids[1])!.mediaID!
        let tr: [MediaID: Transcript] = [
            a: Transcript(engine: "t", language: "fr", words: w([("Bonjour", 1.5, 2.0), ("à", 2.1, 2.2), ("tous.", 2.3, 2.8),
                                                                   ("On", 3.0, 3.2), ("commence.", 3.3, 5.0)])),
            b: Transcript(engine: "t", language: "fr", words: w([("Voici", 2.0, 2.5), ("le", 2.6, 2.7), ("plan.", 2.8, 4.0)])),
        ]
        return (p, ids, tr)
    }

    func cands(_ p: Project, _ tr: [MediaID: Transcript], _ o: FillerCleanup.Options = .init(), scope: Set<ClipID>? = nil) -> [FillerCleanup.Candidate] {
        FillerCleanup.candidates(words: TranscriptEditing.placedWords(transcripts: tr, timeline: p.timeline), transcripts: tr,
                                 timeline: p.timeline, options: o, scope: scope)
    }

    @Test func pausesAtClipEdgesAndAcrossTheCutAreFound() {
        let (p, _, tr) = twoClips()
        let c = cands(p, tr)
        let edges = c.map { $0.edge }
        #expect(edges.first == .leading)                       // 0 → 1.5 s before "Bonjour"
        #expect(edges.last == .trailing)                       // after "plan." to the end of B
        #expect(c.contains { $0.edge == .middle && $0.range.start.seconds > 5 && $0.range.end.seconds > 8 })   // tail of A + head of B
        let lead = c.first!
        #expect(abs(lead.range.start.seconds) < 1e-6 && abs(lead.range.end.seconds - (1.5 - 0.15)) < 1e-3)
        #expect(abs(lead.seconds - 1.5) < 1e-3)
        let trail = c.last!
        #expect(abs(trail.range.start.seconds - (12 + 0.15)) < 1e-3 && abs(trail.range.end.seconds - 16) < 1e-3)
    }

    @Test func removingTrimsLeadingAndTrailingSilence() throws {
        var (p, _, tr) = twoClips()
        try FillerCleanup.apply(cands(p, tr), in: &p)
        ok(p)
        let placed = TranscriptEditing.placedWords(transcripts: tr, timeline: p.timeline)
        #expect(placed.allSatisfy { !$0.isDeleted })
        let first = FillerCleanup.span(placed.first!, in: p.timeline)!, last = FillerCleanup.span(placed.last!, in: p.timeline)!
        #expect(abs(first.start.seconds - 0.15) < 0.01, "speech starts \(first.start.seconds)")
        #expect(abs(p.timeline.duration.seconds - last.end.seconds - 0.15) < 0.01, "ends \(p.timeline.duration.seconds) vs \(last.end.seconds)")
        // nothing left to remove
        #expect(cands(p, tr).isEmpty)
    }

    @Test func hesitationsAtTheVeryStartAndEndOfAClipGo() throws {
        var (p, ids) = Fx.project(mainClips: 1, seconds: 8)
        let m = p.timeline.clip(ids[0])!.mediaID!
        let tr = [m: Transcript(engine: "t", language: "fr", words: w([("euh", 0.0, 0.4), ("bonjour", 0.5, 1.0), ("et", 1.1, 1.3),
                                                                       ("merci", 1.4, 7.6), ("hum", 7.65, 8.0)]))]
        let c = cands(p, tr, .init(pauses: false))
        #expect(c.map(\.text) == ["euh", "hum"])
        try FillerCleanup.apply(c, in: &p)
        ok(p)
        let placed = TranscriptEditing.placedWords(transcripts: tr, timeline: p.timeline)
        #expect(placed.filter { !$0.isDeleted }.map(\.word.text) == ["bonjour", "et", "merci"])
        #expect(abs(p.timeline.duration.seconds - (8 - 0.4 - 0.35)) < 0.02)
    }

    @Test func scopeLimitsToTheSelectedClips() {
        let (p, ids, tr) = twoClips()
        let c = cands(p, tr, scope: [ids[1]])
        #expect(!c.isEmpty)
        let b = p.timeline.clip(ids[1])!.range
        #expect(c.allSatisfy { b.contains($0.range.start) && $0.range.end <= b.end })   // the cross-cut pause is clipped to B
        #expect(c.contains { $0.edge == .middle && abs($0.range.start.seconds - 8) < 1e-6 })
    }

    @Test func clipsWithoutSpeechAreNeverCut() {
        var (p, ids, tr) = twoClips()
        // a b-roll clip (no transcript) between the two speech clips
        let broll = Fx.video("broll")
        p.media.append(broll)
        var c = TimelineOps.makeClip(for: broll, at: Time(8))
        c.duration = Time(3)
        try! TimelineOps.insert(c, into: &p)
        let main = p.timeline.mainTrack!.clips
        #expect(main.count == 3 && main[1].mediaID == broll.id)
        let found = cands(p, tr)
        let r = main[1].range
        #expect(found.allSatisfy { !$0.range.overlaps(r) })
        #expect(found.filter { $0.edge == .trailing }.count == 2 && found.filter { $0.edge == .leading }.count == 2)
        _ = ids
    }

    @Test func pausesAreMeasuredOnTheTimelineAfterACut() throws {
        var (p, ids) = Fx.project(mainClips: 1, seconds: 10)
        let m = p.timeline.clip(ids[0])!.mediaID!
        let tr = [m: Transcript(engine: "t", language: "fr", words: w([("un", 0.0, 0.5), ("deux", 0.6, 1.0), ("trois", 6.0, 6.5),
                                                                       ("quatre", 6.6, 10.0)]))]
        // cut most of the 5 s silence by hand: 0.5 s remain between "deux" and "trois" on the timeline
        try TranscriptEditing.rippleDelete([TimeRange(start: Time(1.25), end: Time(5.75))], in: &p)
        let placed = TranscriptEditing.placedWords(transcripts: tr, timeline: p.timeline)
        #expect(FillerCleanup.pauses(words: placed, transcripts: tr, timeline: p.timeline, options: .init(minPause: 0.4)).count == 1)
        #expect(FillerCleanup.pauses(words: placed, transcripts: tr, timeline: p.timeline, options: .init(minPause: 1.0)).isEmpty)
    }

    // MARK: Captions follow the cuts

    /// One caption per clip from the words, optionally linked to the main clip (auto captions with linkage on).
    func withCaptions(_ p0: Project, _ tr: [MediaID: Transcript], linked: Bool) -> Project {
        var p = p0
        var segs: [CaptionSegment] = []
        for c in p.timeline.mainTrack!.clips {
            guard let t = tr[c.mediaID!] else { continue }
            let o = c.start.seconds - c.sourceStart.seconds
            let ws = t.words.map { (text: $0.text, start: $0.start + o, end: $0.end + o) }
            segs.append(CaptionSegment(text: ws.map(\.text).joined(separator: " "), start: ws.first!.start, end: ws.last!.end, words: ws))
        }
        let id = CaptionOps.addCaptionTrack(segs, to: &p)!
        p.timeline.linkage = linked
        SpeechCaptions.finish(trackID: id, language: "fr", in: &p, identifyFillers: true)
        return p
    }

    @Test(arguments: [false, true]) func captionsStayOnTheirWords(linked: Bool) throws {
        let (p0, _, tr) = twoClips()
        var p = withCaptions(p0, tr, linked: linked)
        try FillerCleanup.apply(cands(p, tr), in: &p)
        ok(p)
        let caps = SpeechCaptions.captions(in: p.timeline)
        let placed = TranscriptEditing.placedWords(transcripts: tr, timeline: p.timeline)
        #expect(caps.count == 2)
        // each caption starts on its first word, wherever the cuts moved it
        let bonjour = FillerCleanup.span(placed.first { $0.word.text == "Bonjour" }!, in: p.timeline)!
        let voici = FillerCleanup.span(placed.first { $0.word.text == "Voici" }!, in: p.timeline)!
        #expect(abs(caps[0].start.seconds - bonjour.start.seconds) < 0.02)
        #expect(abs(caps[1].start.seconds - voici.start.seconds) < 0.02, "\(caps[1].start.seconds) vs \(voici.start.seconds)")
    }

    @Test func aRemovedFillerLeavesTheCaptionText() throws {
        var (p, ids) = Fx.project(mainClips: 1, seconds: 8)
        let m = p.timeline.clip(ids[0])!.mediaID!
        let tr = [m: Transcript(engine: "t", language: "fr", words: w([("Alors", 0.0, 0.4), ("euh", 0.5, 1.0), ("on", 1.1, 1.3),
                                                                       ("y", 1.35, 1.5), ("va.", 1.55, 8.0)]))]
        p = withCaptions(p, tr, linked: true)
        let c = cands(p, tr, .init(pauses: false))
        #expect(c.map(\.text) == ["euh"])
        try FillerCleanup.apply(c, in: &p)
        ok(p)
        let cap = SpeechCaptions.captions(in: p.timeline)[0]
        #expect(CaptionOps.text(cap)?.string == "Alors on y va.")
        #expect(CaptionOps.text(cap)?.caption?.words.map(\.text) == ["Alors", "on", "y", "va."])
        // the words after the cut stay on their audio: "on" is still heard where the caption says
        let words = CaptionOps.words(of: cap)
        let on = FillerCleanup.span(TranscriptEditing.placedWords(transcripts: tr, timeline: p.timeline).first { $0.word.text == "on" }!, in: p.timeline)!
        let capOn = cap.start + (words[1].start - cap.sourceStart)
        #expect(abs(capOn.seconds - on.start.seconds) < 0.02, "\(capOn.seconds) vs \(on.start.seconds)")
    }

    // MARK: Apply to all main captions

    func captionProject(_ n: Int = 3) -> Project {
        var p = Project(name: "c")
        let segs = (0..<n).map { CaptionSegment(text: "Caption \($0)", start: Double($0) * 2, end: Double($0) * 2 + 1.5, speaker: $0 == 1 ? "2" : "1") }
        CaptionOps.addCaptionTrack(segs, to: &p)
        return p
    }

    @Test func styleEditOnOneCaptionRestylesItsTrack() {
        var p = captionProject()
        let ids = SpeechCaptions.captions(in: p.timeline).map(\.id)
        // speaker 2's caption has its own colour; the edit below only changes the font size
        if case .text(var t) = p.timeline.clip(ids[1])!.content { t.color = RGBA(1, 0, 0); p.timeline[clip: ids[1]]?.content = .text(t) }
        let before = p
        if case .text(var t) = p.timeline.clip(ids[0])!.content { t.fontSize = 0.09; t.strokeWidth = 0.2; p.timeline[clip: ids[0]]?.content = .text(t) }
        p.timeline[clip: ids[0]]?.transform.position = Vec2(0, 0.2)
        CaptionStyleSync.propagate(from: ids[0], before: before, after: &p)
        for id in ids {
            let t = CaptionOps.text(p.timeline.clip(id)!)!
            #expect(t.fontSize == 0.09 && t.strokeWidth == 0.2)
            #expect(p.timeline.clip(id)!.transform.position == Vec2(0, 0.2))
        }
        #expect(CaptionOps.text(p.timeline.clip(ids[1])!)?.color == RGBA(1, 0, 0))     // untouched property kept
        #expect(CaptionOps.text(p.timeline.clip(ids[2])!)?.string == "Caption 2")       // text never copied
    }

    @Test func editsThatAlreadyRestyleOthersAreLeftAlone() {
        var p = captionProject()
        let ids = SpeechCaptions.captions(in: p.timeline).map(\.id)
        let before = p
        for (k, id) in ids.enumerated() {
            if case .text(var t) = p.timeline.clip(id)!.content { t.fontSize = 0.05 + Double(k) * 0.01; p.timeline[clip: id]?.content = .text(t) }
        }
        let expected = p
        CaptionStyleSync.propagate(from: ids[0], before: before, after: &p)
        #expect(p == expected)
    }

    @Test func sessionHookMakesItOneUndoStepAlsoDuringGestures() throws {
        let p = captionProject()
        let ids = SpeechCaptions.captions(in: p.timeline).map(\.id)
        var s = EditSession(project: p)
        let src = ids[0]
        s.postProcess = { before, after in CaptionStyleSync.propagate(from: src, before: before, after: &after) }
        try s.perform(Edit("cmd.text") { p in
            if case .text(var t) = p.timeline.clip(src)!.content { t.bold = false; t.fontName = "Avenir"; p.timeline[clip: src]?.content = .text(t) }
        })
        #expect(ids.allSatisfy { CaptionOps.text(s.project.timeline.clip($0)!)?.fontName == "Avenir" })
        #expect(s.undoStack.count == 1)
        // slider drag: every tick replays on the base
        s.beginGesture("cmd.text")
        for v in [0.06, 0.07, 0.08] {
            s.updateGesture { p in if case .text(var t) = p.timeline.clip(src)!.content { t.fontSize = v; p.timeline[clip: src]?.content = .text(t) } }
        }
        s.endGesture()
        #expect(ids.allSatisfy { CaptionOps.text(s.project.timeline.clip($0)!)?.fontSize == 0.08 })
        #expect(s.undoStack.count == 2)
        s.undo(); s.undo()
        #expect(ids.allSatisfy { CaptionOps.text(s.project.timeline.clip($0)!)?.fontName == "" })
    }

    @Test func manyCaptionsSyncFast() {
        var p = captionProject(400)
        let ids = SpeechCaptions.captions(in: p.timeline).map(\.id)
        let before = p
        if case .text(var t) = p.timeline.clip(ids[0])!.content { t.fontSize = 0.07; p.timeline[clip: ids[0]]?.content = .text(t) }
        let t0 = Date()
        CaptionStyleSync.propagate(from: ids[0], before: before, after: &p)
        let ms = Date().timeIntervalSince(t0) * 1000
        print("metric unit_caption_style_sync_400_ms=\(ms)")
        #expect(ids.allSatisfy { CaptionOps.text(p.timeline.clip($0)!)?.fontSize == 0.07 })
        #expect(ms < 500)   // gross bound only (precise numbers: the metric line)
    }

    // MARK: Caption list ＋ / 🗑

    @Test func addAfterAndDeleteKeepTheOtherCaptionsInPlace() throws {
        var p = captionProject()
        let ids = SpeechCaptions.captions(in: p.timeline).map(\.id)
        let starts = SpeechCaptions.captions(in: p.timeline).map(\.start)
        let n = try CaptionOps.insertAfter(ids[0], text: "New", in: &p)
        ok(p)
        let caps = SpeechCaptions.captions(in: p.timeline)
        #expect(caps.count == 4 && caps[1].id == n)
        #expect(abs(caps[1].start.seconds - 1.5) < 1e-6 && caps[1].end <= caps[2].start)   // in the 0.5 s gap
        #expect(CaptionOps.text(caps[1])?.string == "New" && CaptionOps.text(caps[1])?.caption?.words.isEmpty == true)
        // no gap after the last-but-one? split in half
        let n2 = try CaptionOps.insertAfter(n, text: "Half", in: &p)
        ok(p)
        #expect(p.timeline.clip(n2) != nil)
        try CaptionOps.delete(ids[1], in: &p)
        ok(p)
        let after = SpeechCaptions.captions(in: p.timeline)
        #expect(!after.contains { $0.id == ids[1] })
        #expect(after.first { $0.id == ids[2] }?.start == starts[2])
    }
}
