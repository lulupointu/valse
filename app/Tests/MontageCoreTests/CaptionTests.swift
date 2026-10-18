import Testing
import Foundation
@testable import MontageCore

/// Caption track model, editing operations and subtitle formats.
struct CaptionTests {
    func segs() -> [CaptionSegment] {
        [CaptionSegment(text: "Hello big world", start: 1, end: 3,
                        words: [("Hello", 1, 1.5), ("big", 1.6, 2.0), ("world", 2.2, 3)]),
         CaptionSegment(text: "Second line", start: 3.5, end: 5)]
    }

    func project() -> (Project, Int) {
        var p = Project(name: "c")
        CaptionOps.addCaptionTrack(segs(), to: &p)
        return (p, CaptionOps.captionTracks(p.timeline)[0])
    }

    @Test func addTrackBuildsTimedCaptionClips() {
        let (p, ti) = project()
        let t = p.timeline.tracks[ti]
        #expect(t.kind == .text && t.clips.count == 2)
        #expect(t.clips[0].start == Time(1) && t.clips[0].duration == Time(2))
        #expect(CaptionOps.text(t.clips[0])?.caption?.words[1].start == Time(0.6))   // content time
        #expect(TimelineOps.validate(p.timeline).isEmpty)
        // replacing removes the previous auto track
        var q = p
        CaptionOps.addCaptionTrack(segs(), to: &q, replacing: true)
        #expect(CaptionOps.captionTracks(q.timeline).count == 1)
    }

    @Test func overlappingSegmentsAreClipped() {
        var p = Project(name: "c")
        CaptionOps.addCaptionTrack([CaptionSegment(text: "a", start: 0, end: 2), CaptionSegment(text: "b", start: 1.5, end: 3)], to: &p)
        let clips = p.timeline.tracks[CaptionOps.captionTracks(p.timeline)[0]].clips
        #expect(clips[1].start == Time(2) && clips[1].sourceStart == Time(0.5))
        #expect(TimelineOps.validate(p.timeline).isEmpty)
    }

    @Test func splitAtWordUsesWordTiming() throws {
        var (p, ti) = project()
        let id = p.timeline.tracks[ti].clips[0].id
        let right = try CaptionOps.split(id, at: 9, in: &p)      // "Hello big" | "world"
        let l = p.timeline.clip(id)!, r = p.timeline.clip(right)!
        #expect(CaptionOps.text(l)?.string == "Hello big" && CaptionOps.text(r)?.string == "world")
        #expect(r.start == Time(2.2))
        #expect(CaptionOps.text(r)?.caption?.words.map(\.text) == ["world"])
        // right word timings still resolve to the same timeline time
        let w = CaptionOps.words(of: r)[0]
        #expect(r.start + (w.start - r.sourceStart) == Time(2.2))
        #expect(throws: EditError.self) { try CaptionOps.split(id, at: 0, in: &p) }
        #expect(TimelineOps.validate(p.timeline).isEmpty)
    }

    @Test func mergeJoinsTextWordsAndTime() throws {
        var (p, ti) = project()
        let id = p.timeline.tracks[ti].clips[0].id
        try CaptionOps.mergeWithNext(id, in: &p)
        let c = p.timeline.clip(id)!
        #expect(p.timeline.tracks[ti].clips.count == 1)
        #expect(CaptionOps.text(c)?.string == "Hello big world Second line")
        #expect(c.end == Time(5))
        #expect(CaptionOps.words(of: c).count == 5)
        #expect(throws: EditError.self) { try CaptionOps.mergeWithNext(id, in: &p) }
    }

    @Test func nudgeClampsToNeighboursAndKeepsWordsAnchored() throws {
        var (p, ti) = project()
        let a = p.timeline.tracks[ti].clips[0].id, b = p.timeline.tracks[ti].clips[1].id
        try CaptionOps.setTimes(a, end: Time(10), in: &p)
        #expect(p.timeline.clip(a)!.end == Time(3.5))             // can't overlap the next caption
        try CaptionOps.nudge(b, start: Time(-2), in: &p)
        #expect(p.timeline.clip(b)!.start == Time(3.5))           // nor the previous one
        try CaptionOps.setTimes(a, start: Time(1.5), in: &p)
        let c = p.timeline.clip(a)!
        let w = CaptionOps.words(of: c)[1]                        // "big" stays at 1.6 s
        #expect(c.start + (w.start - c.sourceStart) == Time(1.6))
        #expect(TimelineOps.validate(p.timeline).isEmpty)
    }

    @Test func findAndReplace() {
        var (p, ti) = project()
        #expect(CaptionOps.find("LINE", in: p.timeline.tracks[ti]).count == 1)
        #expect(CaptionOps.find("o", in: p.timeline.tracks[ti]).count == 3)
        let n = CaptionOps.replaceAll("world", with: "planet", trackIndex: ti, in: &p)
        #expect(n == 1)
        let c = p.timeline.tracks[ti].clips[0]
        #expect(CaptionOps.text(c)?.string == "Hello big planet")
        #expect(CaptionOps.text(c)?.caption?.words.last?.text == "planet")
        #expect(CaptionOps.text(c)?.caption?.words.last?.start == Time(1.2))   // timing kept (same word count)
    }

    @Test func applyLookToAllCopiesStyleNotText() {
        var (p, ti) = project()
        let id = p.timeline.tracks[ti].clips[0].id
        var c = p.timeline.clip(id)!
        if case .text(var t) = c.content { t.color = .red; t.karaoke = KaraokeStyle(); c.content = .text(t) }
        c.transform.position = Vec2(0, -0.3)
        p.timeline[clip: id] = c
        CaptionOps.applyLookToAll(from: id, in: &p)
        let other = p.timeline.tracks[ti].clips[1]
        #expect(CaptionOps.text(other)?.color == .red && CaptionOps.text(other)?.karaoke != nil)
        #expect(CaptionOps.text(other)?.string == "Second line" && other.transform.position == Vec2(0, -0.3))
    }

    @Test func wrapSplitsLongCaptions() {
        var p = Project(name: "w")
        let words = (0..<12).map { ("word\($0)", Double($0), Double($0) + 0.8) }
        CaptionOps.addCaptionTrack([CaptionSegment(text: words.map(\.0).joined(separator: " "), start: 0, end: 12,
                                                   words: words.map { (text: $0.0, start: $0.1, end: $0.2) })], to: &p)
        let ti = CaptionOps.captionTracks(p.timeline)[0]
        CaptionOps.wrap(trackIndex: ti, maxCharsPerLine: 13, maxLines: 2, in: &p)
        let clips = p.timeline.tracks[ti].clips
        // 12 words of 5-6 chars, 2 per line (≤ 13) → 6 lines → 3 captions of 2 lines
        #expect(clips.count == 3)
        #expect(CaptionOps.text(clips[0])?.string == "word0 word1\nword2 word3")
        #expect(clips[1].start == Time(4))
        #expect(TimelineOps.validate(p.timeline).isEmpty)
    }

    @Test func scriptToCaptionsTimesBackToBack() {
        let segs = CaptionOps.scriptSegments("First sentence here. Second one!\nThird", start: 2, totalDuration: 9)
        #expect(segs.map(\.text) == ["First sentence here.", "Second one!", "Third"])
        #expect(segs.first?.start == 2 && abs((segs.last?.end ?? 0) - 11) < 1e-9)
        #expect(zip(segs, segs.dropFirst()).allSatisfy { abs($0.end - $1.start) < 1e-9 })
    }

    @Test func keywordHighlighterFlagsContentWords() {
        var p = Project(name: "k")
        CaptionOps.addCaptionTrack([CaptionSegment(text: "we visited the gorgeous Lisbon", start: 0, end: 2),
                                    CaptionSegment(text: "and it was", start: 2, end: 3)], to: &p)
        let ti = CaptionOps.captionTracks(p.timeline)[0]
        let n = CaptionOps.highlightKeywords(trackIndex: ti, in: &p)
        #expect(n == 1)
        let w = CaptionOps.text(p.timeline.tracks[ti].clips[0])!.caption!.words
        #expect(w.first { $0.isKeyword }?.text == "Lisbon")
        CaptionOps.clearKeywords(trackIndex: ti, in: &p)
        #expect(!CaptionOps.text(p.timeline.tracks[ti].clips[0])!.caption!.words.contains { $0.isKeyword })
    }

    @Test func segmentsExportBilingual() {
        var (p, ti) = project()
        var c = p.timeline.tracks[ti].clips[0]
        if case .text(var t) = c.content { t.caption?.translation = "Bonjour"; t.caption?.display = .both; c.content = .text(t) }
        p.timeline.tracks[ti].clips[0] = c
        let s = CaptionOps.segments(of: p.timeline.tracks[ti])
        #expect(s[0].text == "Hello big world\nBonjour" && s[0].words.count == 3 && s[0].words[1].start == 1.6)
    }

    // MARK: Formats

    @Test func srtRoundTrip() throws {
        let text = CaptionFiles.serialize(segs(), format: .srt)
        #expect(text.hasPrefix("1\n00:00:01,000 --> 00:00:03,000\nHello big world\n"))
        let back = try CaptionFiles.parse(text, format: .srt)
        #expect(back.map(\.text) == ["Hello big world", "Second line"] && back[1].start == 3.5 && back[1].end == 5)
    }

    @Test func srtParserIsTolerant() throws {
        let s = "\u{FEFF}1\r\n00:00:01.5 --> 00:00:02,25\r\n<i>Hi</i> {\\an8}there\r\nline 2\r\n\r\n\r\n00:00:03,000 --> 00:00:04,000\r\nno index\r\n"
        let segs = try CaptionFiles.parse(s, format: .srt)
        #expect(segs.count == 2 && segs[0].text == "Hi there\nline 2" && segs[0].start == 1.5 && segs[0].end == 2.25)
        #expect(throws: CaptionFormatError.empty) { try CaptionFiles.parse("garbage", format: .srt) }
    }

    @Test func vttRoundTripWithWordTimings() throws {
        let text = CaptionFiles.serialize(segs(), format: .vtt)
        #expect(text.hasPrefix("WEBVTT"))
        #expect(text.contains("Hello <00:00:01.600>big <00:00:02.200>world"))
        let back = try CaptionFiles.parse(text, format: .vtt)
        #expect(back[0].text == "Hello big world")
        #expect(back[0].words.map(\.text) == ["Hello", "big", "world"])
        #expect(back[0].words[1].start == 1.6 && back[0].words[2].start == 2.2)
    }

    @Test func assRoundTripWithKaraoke() throws {
        var style = CaptionOps.defaultStyle(); style.color = RGBA(1, 0, 0)
        let text = CaptionFiles.serialize(segs(), format: .ass, style: style)
        #expect(text.contains("[Events]") && text.contains("&H000000FF"))     // red in AABBGGRR
        #expect(text.contains("Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,"))
        let back = try CaptionFiles.parse(text, format: .ass)
        #expect(back.map(\.text) == ["Hello big world", "Second line"])
        #expect(back[0].words.map(\.text) == ["Hello", "big", "world"])
        #expect(abs(back[0].words[1].start - 1.6) < 0.011 && abs(back[0].words[2].start - 2.2) < 0.011)
    }

    @Test func assParsesCommasNewlinesAndTags() throws {
        let s = """
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:02.50,Default,,0,0,0,,{\\b1}Hello, you\\Nthere
        """
        let segs = try CaptionFiles.parse(s, format: .ass)
        #expect(segs.first?.text == "Hello, you\nthere" && segs.first?.end == 2.5)
    }

    @Test func lrcRoundTripAndEnhanced() throws {
        let s = "[ar:x]\n[00:01.00]First line\n[00:03.50][00:10.00]Repeat\n[00:05.00]<00:05.00>Word <00:05.40>by <00:05.90>word\n"
        let segs = try CaptionFiles.parse(s, format: .lrc)
        #expect(segs.map(\.text) == ["First line", "Repeat", "Word by word", "Repeat"])
        #expect(segs[0].end == 3.5 && segs[2].words.map(\.start) == [5.0, 5.4, 5.9])
        let back = try CaptionFiles.parse(CaptionFiles.serialize(segs, format: .lrc), format: .lrc)
        #expect(back.map(\.text) == segs.map(\.text) && back[2].words.count == 3)
    }

    @Test func formatDetection() {
        #expect(CaptionFormat.detect(fileExtension: "SRT", content: "") == .srt)
        #expect(CaptionFormat.detect(fileExtension: "", content: "WEBVTT\n") == .vtt)
        #expect(CaptionFormat.detect(fileExtension: "x", content: "[Script Info]") == .ass)
        #expect(CaptionFormat.detect(fileExtension: "x", content: "[00:01.00]a") == .lrc)
        #expect(CaptionFormat.detect(fileExtension: "x", content: "nothing") == nil)
    }

    @Test func evaluatorShiftsWordsToClipLocalTime() throws {
        var (p, ti) = project()
        let id = p.timeline.tracks[ti].clips[0].id
        try CaptionOps.setTimes(id, start: Time(1.5), in: &p)       // sourceStart becomes 0.5
        let f = FrameEvaluator.evaluate(p, at: Time(2))
        guard case .layer(let l) = f.items.last, case .text(let t) = l.source else { Issue.record("no text layer"); return }
        #expect(t.caption?.words[1].start == Time(0.1))              // "big" at 1.6 s = 0.1 s after the clip start
    }
}
