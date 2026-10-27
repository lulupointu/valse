import Testing
import Foundation
@testable import ValseCore

/// CAP-UX2-SPLIT: Split options re-flow a language from its CURRENT texts (owner 2026-10-27): merges and splits, the
/// user's corrections are kept word for word, word timings stay monotonic and inside the caption each word came from.
@Suite struct CaptionReflowTests {
    /// Four generated sentences, words every 0.3 s, a 1.2 s pause before the third one.
    static func generated() throws -> (Project, TrackID) {
        let sentences = [
            "so today we are going to talk about the new editor",
            "it is much faster than before and easier to use.",
            "first open the project",
            "then pick a caption and start typing your text",
        ]
        var p = Project(name: "reflow")
        var t = 0.0
        var segs: [CaptionSegment] = []
        for (i, s) in sentences.enumerated() {
            if i == 2 { t += 1.2 }
            let start = t
            var words: [(text: String, start: Double, end: Double)] = []
            for w in s.split(separator: " ") { words.append((String(w), t, t + 0.25)); t += 0.3 }
            segs.append(CaptionSegment(text: s, start: start, end: t, words: words))
        }
        let tid = try #require(CaptionOps.addCaptionTrack(segs, to: &p))
        return (p, tid)
    }

    static func clips(_ p: Project, _ tid: TrackID) -> [Clip] { p.timeline.tracks[p.timeline.trackIndex(tid)!].clips }
    static func wordSequence(_ p: Project, _ tid: TrackID) -> [String] {
        clips(p, tid).flatMap { TextTokenizer.tokens(CaptionOps.text($0)?.string ?? "") }
    }
    /// Timeline (start, end) of every word, in order.
    static func wordTimes(_ p: Project, _ tid: TrackID) -> [(Time, Time)] {
        clips(p, tid).flatMap { c in CaptionOps.words(of: c).map { (c.start + ($0.start - c.sourceStart), c.start + ($0.end - c.sourceStart)) } }
    }

    /// The user's edits: a fixed word, a deleted word, an added word, punctuation / casing, a manual split, a merge.
    static func edited() throws -> (Project, TrackID) {
        var (p, tid) = try generated()
        var ids = clips(p, tid).map(\.id)
        try CaptionOps.setText(ids[0], "So today we're going to talk about the new editor", in: &p)   // merged words + casing
        try CaptionOps.setText(ids[1], "It is MUCH faster than before, and easier to use!", in: &p)  // punctuation, casing
        try CaptionOps.setText(ids[2], "first open the Valse project", in: &p)                     // added word
        try CaptionOps.setText(ids[3], "then pick a caption and start typing", in: &p)               // deleted words
        _ = try CaptionOps.split(ids[1], at: 18, in: &p)                                              // manual split
        ids = clips(p, tid).map(\.id)
        try CaptionOps.mergeWithNext(ids[3], in: &p)                                                  // manual merge
        return (p, tid)
    }

    static let expectedWords = ("So today we're going to talk about the new editor It is MUCH faster than before, and easier to use! "
                                + "first open the Valse project then pick a caption and start typing").split(separator: " ").map(String.init)

    @Test func editsAreSetUp() throws {
        let (p, tid) = try Self.edited()
        #expect(Self.wordSequence(p, tid) == Self.expectedWords)
        #expect(Self.clips(p, tid).count == 4)
    }

    /// Every preset, in several orders: the text is the user's word for word, timings monotonic, every word inside the
    /// time span of the caption it had before the first re-split, the track valid, one undo step restores everything.
    @Test(arguments: [[0, 3, 0, 1, 2, 3], [3, 0, 3], [1, 2, 0, 2, 1], [2, 3, 1, 0]])
    func resplitKeepsTheUsersTextAndTimings(_ order: [Int]) throws {
        let (p0, tid) = try Self.edited()
        // span of the caption each word belongs to after the edits
        var spans: [(Time, Time)] = []
        for c in Self.clips(p0, tid) { for _ in TextTokenizer.tokens(CaptionOps.text(c)!.string) { spans.append((c.start, c.end)) } }
        var s = EditSession(project: p0)
        for (n, i) in order.enumerated() {
            let rule = CaptionSplitRule.presets[i]
            let before = s.project
            try s.perform(Edit("cmd.captionWrap") { q in _ = try CaptionOps.resplit(trackID: tid, rule: rule, in: &q) })
            let p = s.project
            #expect(Self.wordSequence(p, tid) == Self.expectedWords, "order \(order) step \(n)")
            #expect(TimelineOps.validate(p.timeline).isEmpty)
            let times = Self.wordTimes(p, tid)
            #expect(times.count == spans.count)
            var last = Time.zero
            for (k, (a, b)) in times.enumerated() {
                #expect(a >= last && b >= a, "monotonic word \(k)")
                #expect(a >= spans[k].0 && b <= spans[k].1, "word \(k) \(Self.expectedWords[k]) stays in its caption")
                last = b
            }
            for c in Self.clips(p, tid) {
                #expect(CaptionOps.overLimit(CaptionOps.text(c)!.string, rule: rule) == nil, "fits \(rule)")
                #expect(c.duration >= TimelineOps.minimumClipDuration)
            }
            #expect(p.timeline.tracks[p.timeline.trackIndex(tid)!].captionSplit == rule)
            s.undo()
            #expect(s.project == before)
            s.redo()
        }
    }

    /// 16 → 42 merges: the longer option gives fewer, longer captions; 42 → 16 splits again; each option does something.
    @Test func longerRuleMergesShorterRuleSplits() throws {
        var (p, tid) = try Self.edited()
        try CaptionOps.resplit(trackID: tid, rule: CaptionSplitRule.presets[0], in: &p)
        let n16 = Self.clips(p, tid).count
        try CaptionOps.resplit(trackID: tid, rule: CaptionSplitRule.presets[3], in: &p)
        let n42 = Self.clips(p, tid).count
        #expect(n42 < n16)
        #expect(Self.clips(p, tid).map { CaptionOps.text($0)!.string.count }.max()! > 16)
        try CaptionOps.resplit(trackID: tid, rule: CaptionSplitRule.presets[0], in: &p)
        #expect(Self.clips(p, tid).count == n16)
        // the sentence end and the 1.2 s pause always cut: no caption holds "use!" and "first"
        for c in Self.clips(p, tid) { #expect(!CaptionOps.text(c)!.string.contains("use! first")) }
        try CaptionOps.resplit(trackID: tid, rule: CaptionSplitRule.presets[3], in: &p)
        for c in Self.clips(p, tid) {
            let t = CaptionOps.text(c)!.string.replacingOccurrences(of: "\n", with: " ")
            #expect(!t.contains("use! first"))
        }
    }

    /// Re-flowing twice with the same rule changes nothing (ids, texts and times are stable).
    @Test func reflowIsIdempotent() throws {
        for rule in CaptionSplitRule.presets {
            var (p, tid) = try Self.edited()
            CaptionOps.reflow(trackIndex: p.timeline.trackIndex(tid)!, rule: rule, in: &p)
            let once = p
            CaptionOps.reflow(trackIndex: p.timeline.trackIndex(tid)!, rule: rule, in: &p)
            #expect(Self.clips(p, tid).map { CaptionOps.text($0)!.string } == Self.clips(once, tid).map { CaptionOps.text($0)!.string })
            #expect(Self.clips(p, tid).map(\.start) == Self.clips(once, tid).map(\.start))
            #expect(Self.clips(p, tid).map(\.end) == Self.clips(once, tid).map(\.end))
        }
    }

    /// Styles of a word go with it into its new caption; the first caption keeps its id.
    @Test func runsFollowTheirWords() throws {
        var (p, tid) = try Self.generated()
        let first = Self.clips(p, tid)[0].id
        var c = Self.clips(p, tid)[1]
        var t = try #require(CaptionOps.text(c))
        let r = (t.string as NSString).range(of: "faster")
        t.runs = [TextRun(TextSpan(r.location, r.length), TextRunStyle(bold: true))]
        c.content = .text(t)
        p.timeline[clip: c.id] = c
        try CaptionOps.resplit(trackID: tid, rule: CaptionSplitRule.presets[0], in: &p)
        #expect(Self.clips(p, tid)[0].id == first)
        let holder = try #require(Self.clips(p, tid).first { CaptionOps.text($0)!.string.contains("faster") })
        let ht = try #require(CaptionOps.text(holder))
        let loc = (ht.string as NSString).range(of: "faster")
        #expect(ht.runs == [TextRun(TextSpan(loc.location, loc.length), TextRunStyle(bold: true))])
    }

    /// Edited words: matching words keep their stored timing, a changed one is interpolated between its neighbours.
    @Test func retimeAnchorsMatchingWords() {
        let old = [CaptionWord("the", start: Time(0), end: Time(0.2)), CaptionWord("quick", start: Time(0.3), end: Time(0.5)),
                   CaptionWord("fox", start: Time(1.0), end: Time(1.2))]
        let w = CaptionOps.retimeWords(["The", "very", "quick", "brown", "fox!"], old: old, lo: Time(0), hi: Time(2))
        #expect(w.map(\.text) == ["The", "very", "quick", "brown", "fox!"])
        #expect(w[0].start == Time(0) && w[2].start == Time(0.3) && w[4].start == Time(1.0))
        #expect(w[1].start >= Time(0.2) && w[1].end <= Time(0.3))
        #expect(w[3].start >= Time(0.5) && w[3].end <= Time(1.0))
    }
}
