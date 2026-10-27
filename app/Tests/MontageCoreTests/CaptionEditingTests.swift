import Testing
import Foundation
@testable import MontageCore

/// CAP-EDITOR-UX / CAP-LANG-TRACKS: caption editor model helpers, undo semantics of a typing burst, language tracks
/// and the migration of the old bilingual sub-line.
@Suite struct CaptionEditingTests {
    static func project(_ texts: [String], step: Double = 2) throws -> (Project, TrackID, [ClipID]) {
        var p = Project(name: "caps")
        let segs = texts.enumerated().map { i, t in CaptionSegment(text: t, start: Double(i) * step, end: Double(i) * step + step - 0.1) }
        let tid = try #require(CaptionOps.addCaptionTrack(segs, to: &p))
        let ids = p.timeline.tracks[p.timeline.trackIndex(tid)!].clips.map(\.id)
        return (p, tid, ids)
    }

    static func texts(_ p: Project, _ tid: TrackID) -> [String] {
        p.timeline.tracks[p.timeline.trackIndex(tid)!].clips.map { CaptionOps.text($0)?.string ?? "" }
    }

    @Test func firstDifferenceFindsTheChangedCharacter() {
        #expect(CaptionOps.firstDifference("Hello world", "Hello there") == 6)
        #expect(CaptionOps.firstDifference("abc", "abcdef") == 3)
        #expect(CaptionOps.firstDifference("", "x") == 0)
        #expect(CaptionOps.firstDifference("é✨a", "é✨b") == 2)   // UTF-16: é = 1, ✨ = 1
    }

    @Test func clipIndexAtTime() throws {
        let (p, tid, _) = try Self.project(["a", "b", "c"])
        let clips = p.timeline.tracks[p.timeline.trackIndex(tid)!].clips
        #expect(CaptionOps.clipIndex(at: Time(0.5), in: clips) == 0)
        #expect(CaptionOps.clipIndex(at: Time(4.2), in: clips) == 2)
        #expect(CaptionOps.clipIndex(at: Time(1.95), in: clips) == nil)   // in the gap
        #expect(CaptionOps.clipIndex(at: Time(9), in: clips) == nil)
    }

    @Test func overLimitBadge() {
        let rule = CaptionSplitRule(charsPerLine: 16, lines: 1)
        #expect(CaptionOps.overLimit("short", duration: Time(2), rule: rule) == nil)
        #expect(CaptionOps.overLimit("this line is too long", duration: Time(5), rule: rule)?.limit == 16)
        #expect(CaptionOps.overLimit("two\nlines", duration: Time(5), rule: rule) != nil)
        // > 20 characters per second
        #expect(CaptionOps.overLimit("a fairly long caption here", duration: Time(0.5), rule: nil) != nil)
        #expect(CaptionSplitRule(charsPerLine: 200, lines: 9) == CaptionSplitRule(charsPerLine: 60, lines: 3))
    }

    @Test func splitThenMergeCaretPositions() throws {
        var (p, tid, ids) = try Self.project(["Hello there world"])
        let right = try CaptionOps.split(ids[0], at: 6, in: &p)
        #expect(Self.texts(p, tid) == ["Hello", "there world"])
        #expect(CaptionOps.neighbour(of: ids[0], 1, in: p.timeline) == right)
        // ⌫ at the start of "there world": the caret lands at the join, after "Hello "
        let caret = CaptionOps.mergeCaret(previousText: "Hello", text: "there world")
        try CaptionOps.mergeWithNext(ids[0], in: &p)
        let merged = Self.texts(p, tid)[0]
        #expect(merged == "Hello there world")
        #expect((merged as NSString).substring(from: caret) == "there world")
        #expect(CaptionOps.mergeCaret(previousText: "", text: "x") == 0)
    }

    @Test func setEdgeToPlayheadIsClampedToNeighbours() throws {
        var (p, tid, ids) = try Self.project(["a", "b", "c"])
        try CaptionOps.setEdge(ids[1], start: true, to: Time(0.5), in: &p)   // before the previous caption's end
        let clips = p.timeline.tracks[p.timeline.trackIndex(tid)!].clips
        #expect(clips[1].start == clips[0].end)
        try CaptionOps.setEdge(ids[1], start: false, to: Time(3.0), in: &p)
        #expect(p.timeline.clip(ids[1])?.end == Time(3.0))
        #expect(throws: EditError.self) { try CaptionOps.setEdge(ids[1], start: true, to: Time(3.5), in: &p) }
        #expect(TimelineOps.validate(p.timeline).isEmpty)
    }

    /// A typing burst is a gesture: every keystroke updates the project live, the burst is ONE undo step, and undo
    /// brings back the text from before the burst.
    @Test func typingBurstIsOneUndoStep() throws {
        let (p, tid, ids) = try Self.project(["Hello", "World"])
        var s = EditSession(project: p)
        s.beginGesture("cmd.captionText")
        for text in ["Hello!", "Hello!!", "Hello!!!"] {
            try s.updateGesture { q in try CaptionOps.setText(ids[0], text, in: &q) }
            #expect(Self.texts(s.project, tid)[0] == text)   // live
        }
        s.endGesture()
        #expect(s.undoStack.count == 1)
        #expect(s.undoNameKey == "cmd.captionText")
        s.undo()
        #expect(Self.texts(s.project, tid) == ["Hello", "World"])
        s.redo()
        #expect(Self.texts(s.project, tid)[0] == "Hello!!!")
        // another command while a burst is open ends (commits) it first
        s.beginGesture("cmd.captionText")
        try s.updateGesture { q in try CaptionOps.setText(ids[1], "World?", in: &q) }
        try s.perform(Edit("cmd.captionSplit") { q in _ = try CaptionOps.split(ids[0], at: 5, in: &q) })
        #expect(s.undoStack.map(\.nameKey) == ["cmd.captionText", "cmd.captionText", "cmd.captionSplit"])
    }

    @Test func resplitStoresTheRule() throws {
        var (p, tid, _) = try Self.project(["one two three four five six seven eight nine ten"], step: 6)
        let rule = CaptionSplitRule(charsPerLine: 16, lines: 1)
        let n = try CaptionOps.resplit(trackID: tid, rule: rule, in: &p)
        #expect(n > 1)
        #expect(p.timeline.tracks[p.timeline.trackIndex(tid)!].captionSplit == rule)
        #expect(Self.texts(p, tid).allSatisfy { $0.count <= 16 })
        #expect(TimelineOps.validate(p.timeline).isEmpty)
    }

    @Test func deleteAllRemovesTheLanguage() throws {
        var (p, tid, _) = try Self.project(["a", "b"])
        try CaptionOps.deleteAll(trackID: tid, in: &p)
        #expect(CaptionOps.captionTracks(p.timeline).isEmpty)
    }

    @Test func addLanguageCopiesTimingAndStartsHidden() throws {
        var (p, tid, ids) = try Self.project(["Bonjour", "Salut"])
        let en = try CaptionLanguageTracks.addLanguage(from: tid, language: "EN", texts: [ids[0]: "Hello"], hidden: true,
                                                       stacked: true, in: &p)
        let src = p.timeline.tracks[p.timeline.trackIndex(tid)!], t = p.timeline.tracks[p.timeline.trackIndex(en)!]
        #expect(t.captionLanguage == "en")
        #expect(t.isHidden)
        #expect(t.clips.map(\.start) == src.clips.map(\.start))
        #expect(t.clips.map(\.duration) == src.clips.map(\.duration))
        #expect(Self.texts(p, en) == ["Hello", ""])
        #expect(Set(t.clips.map(\.id)).isDisjoint(with: Set(ids)))
        #expect(t.clips[0].transform.position.y < src.clips[0].transform.position.y)   // stacked above
        #expect(CaptionOps.captionTracks(p.timeline).count == 2)
        #expect(TimelineOps.validate(p.timeline).isEmpty)
    }

    /// Opening an old bilingual project: the sub-line becomes a second, visible language track; the originals lose it.
    @Test func bilingualSubLineMigratesToALanguageTrack() throws {
        var (p, tid, ids) = try Self.project(["Bonjour tout le monde", "Merci"])
        SpeechCaptions.setTranslations([ids[0]: "Hello everyone", ids[1]: "Thanks"], display: .both, in: &p.timeline)
        let changed = CaptionLanguageTracks.migrate(&p) { s in s.contains("Hello") ? "en" : "fr" }
        #expect(changed)
        let tracks = CaptionOps.captionTracks(p.timeline).map { p.timeline.tracks[$0] }
        #expect(tracks.count == 2)
        #expect(Set(tracks.compactMap(\.captionLanguage)) == ["fr", "en"])
        #expect(tracks.allSatisfy { !$0.isHidden })
        let en = try #require(tracks.first { $0.captionLanguage == "en" })
        #expect(en.clips.map { CaptionOps.text($0)?.string } == ["Hello everyone", "Thanks"])
        let fr = try #require(tracks.first { $0.captionLanguage == "fr" })
        #expect(fr.clips.allSatisfy { CaptionOps.text($0)?.caption?.translation == nil })
        #expect(fr.id == tid)
        // idempotent
        #expect(!CaptionLanguageTracks.migrate(&p) { _ in "fr" })
    }

    @Test func translationOnlyHidesTheOriginal() throws {
        var (p, tid, ids) = try Self.project(["Bonjour"])
        SpeechCaptions.setTranslations([ids[0]: "Hello"], display: .translationOnly, in: &p.timeline)
        CaptionLanguageTracks.migrate(&p) { s in s.contains("Hello") ? "en" : "fr" }
        #expect(p.timeline.tracks[p.timeline.trackIndex(tid)!].isHidden)
        #expect(CaptionOps.captionTracks(p.timeline).filter { !p.timeline.tracks[$0].isHidden }.count == 1)
    }

    @Test func languageTrackFieldsRoundTrip() throws {
        var (p, tid, _) = try Self.project(["a"])
        let ti = p.timeline.trackIndex(tid)!
        p.timeline.tracks[ti].captionLanguage = "pt-BR"
        p.timeline.tracks[ti].captionSplit = CaptionSplitRule(charsPerLine: 24, lines: 1)
        let data = try JSONEncoder().encode(p)
        let q = try JSONDecoder().decode(Project.self, from: data)
        #expect(q.timeline.tracks[ti].captionLanguage == "pt-BR")
        #expect(q.timeline.tracks[ti].captionSplit?.charsPerLine == 24)
        #expect(CaptionLanguageTracks.normalized("pt_BR") == "pt-BR")
        #expect(CaptionLanguageTracks.normalized("FR") == "fr")
        #expect(CaptionLanguageTracks.normalized("") == nil)
    }
}
