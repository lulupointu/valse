import Testing
import Foundation
@testable import MontageCore

/// W10 speech → captions (on the W7 caption model), fillers, WER, ripple cuts.
@Suite struct SpeechCaptionTests {
    func ok(_ p: Project) { #expect(TimelineOps.validate(p.timeline).isEmpty, "\(TimelineOps.validate(p.timeline))") }

    /// "Bonjour et bienvenue. Aujourd'hui, euh, nous allons …" with a pause after "bienvenue."
    static func words() -> [TranscriptWord] {
        let spec: [(String, Double, Double)] = [
            ("Bonjour", 0.0, 0.4), ("et", 0.45, 0.55), ("bienvenue.", 0.6, 1.1),
            ("Aujourd'hui,", 2.0, 2.5), ("euh", 2.6, 2.8), ("nous", 2.9, 3.1), ("allons", 3.15, 3.4), ("apprendre", 3.45, 3.9),
            ("à", 3.95, 4.0), ("découper", 4.05, 4.5), ("une", 4.55, 4.7), ("séquence", 4.75, 5.2), ("vidéo", 5.25, 5.6),
            ("très", 5.65, 5.8), ("simplement.", 5.85, 6.5),
        ]
        return spec.map { TranscriptWord(text: $0.0, start: $0.1, end: $0.2) }
    }

    @Test func segmentationSplitsOnSentencesPausesAndLength() {
        let segs = SpeechSegmenter.segments(Self.words(), language: "fr")
        #expect(segs.first?.text == "Bonjour et bienvenue.")
        #expect(segs.count >= 3)
        for s in segs {
            #expect(s.lines.count <= 2)
            for l in s.lines { #expect(l.count <= 28, "line too long: \(l)") }
        }
        #expect(segs.flatMap(\.words).map(\.text) == Self.words().map(\.text))
    }

    @Test func captionLayoutFollowsTheCanvas() {
        let v = Size2(1080, 1920), h = Size2(1920, 1080)
        #expect(CaptionLayout.fontSize(canvas: h) == 0.055)
        // vertical: sized from the width (≈ 65 px on 1080×1920, not 106 px)
        #expect(abs(CaptionLayout.fontSize(canvas: v) * 1920 - 64.8) < 0.5)
        #expect(CaptionLayout.position(canvas: v).y < 0.25 && CaptionLayout.position(canvas: h).y == 0.36)
        let nv = CaptionLayout.maxCharsPerLine(canvas: v), nh = CaptionLayout.maxCharsPerLine(canvas: h)
        #expect(nv >= 20 && nv <= 28 && nh <= 40 && nh > nv)
        var p = Project(name: "v", settings: ProjectSettings(canvasSize: v))
        CaptionOps.addCaptionTrack([CaptionSegment(text: "Salut", start: 0, end: 1)], to: &p)
        let c = SpeechCaptions.captions(in: p.timeline)[0]
        #expect(CaptionOps.text(c)?.fontSize == CaptionLayout.fontSize(canvas: v))
        #expect(c.transform.position == CaptionLayout.position(canvas: v))
    }

    /// Long runs are cut at punctuation / pauses, never after an article, and captions stay short (≈ 1–3 s).
    @Test func longSpeechBreaksAtNaturalPoints() {
        let spec: [(String, Double)] = [
            ("Elle", 0), ("refuse", 0.2), ("ses", 0.5), ("trente", 0.6), ("ans,", 0.9), ("et", 1.4), ("moi", 1.55),
            ("je", 1.75), ("comprends", 1.85), ("vraiment", 2.3), ("très", 2.7), ("bien", 2.9), ("la", 3.1),
            ("situation", 3.2), ("actuelle", 3.7), ("de", 4.2), ("sa", 4.3), ("sœur.", 4.4),
        ]
        let words = spec.map { TranscriptWord(text: $0.0, start: $0.1, end: $0.1 + 0.17) }
        let s = CaptionSettings(maxCharsPerLine: 20)
        let segs = SpeechSegmenter.segments(words, language: "fr", settings: s)
        #expect(segs.flatMap(\.words).map(\.text) == words.map(\.text))
        #expect(segs[0].words.last?.text == "ans,")                        // the comma + pause, not the char limit
        for seg in segs {
            #expect(seg.lines.count <= 2)
            for l in seg.lines { #expect(l.count <= 20, "\(l)") }
            #expect(seg.end - seg.start <= s.maxDuration + 0.01)
            #expect(!["de", "la", "sa", "ses", "et", "je"].contains(seg.words.last!.text), "ends on \(seg.words.last!.text)")
        }
    }

    /// No overlaps, short pauses bridged, long pauses keep a gap, captions linger a little after the last word.
    @Test func captionTimingIsSettled() {
        let segs = [CaptionSegment(text: "a", start: 0, end: 1.0), CaptionSegment(text: "b", start: 1.3, end: 2.0),
                    CaptionSegment(text: "c", start: 3.5, end: 3.7), CaptionSegment(text: "d", start: 3.65, end: 4.5)]
        let out = SpeechCaptions.settle(segs, clipEnd: 10, settings: CaptionSettings())
        #expect(out[0].end == 1.3)                                        // 0.3 s pause bridged
        #expect(abs(out[1].end - 2.2) < 1e-9)                             // 1.5 s pause: +tail only
        #expect(out[2].end <= out[3].start)                               // never overlaps
        #expect(abs(out[3].end - 4.7) < 1e-9)
    }

    @Test func wrapBalancesTwoLines() {
        let lines = SpeechSegmenter.wrap(["Pour", "couper", "un", "plan,", "placez", "la", "tête", "de", "lecture"], maxChars: 28)
        #expect(lines.count == 2)
        #expect(abs(lines[0].count - lines[1].count) < 10)
    }

    @Test func fillersAreClassifiedAndRemovable() {
        let k = FillerWords.classify(["Alors", "euh", "le", "le", "film,", "du", "coup,", "nous", "nous", "sommes"], language: "fr")
        #expect(k[1] == .hesitation)
        #expect(k[2] == .repetition && k[3] == nil)
        #expect(k[5] == .filler && k[6] == .filler)
        #expect(k[7] == nil && k[8] == nil)
        var s = CaptionSettings(); s.removeFillers = true
        let segs = SpeechSegmenter.segments(Self.words(), language: "fr", settings: s)
        #expect(!segs.map(\.text).joined(separator: " ").contains("euh"))
    }

    @Test func werCountsSubstitutionsInsertionsDeletions() {
        #expect(WordErrorRate.compute(reference: "Bonjour et bienvenue", hypothesis: "bonjour, et bienvenue !") == 0)
        #expect(abs(WordErrorRate.compute(reference: "a b c d", hypothesis: "a x c") - 0.5) < 1e-9)
        #expect(WordErrorRate.compute(reference: "aujourd'hui", hypothesis: "Aujourd’hui") == 0)
    }

    @Test func segmentsMapThroughTrimAndSpeed() throws {
        var (p, ids) = Fx.project(mainClips: 1, seconds: 8)
        try TimelineOps.trim(ids[0], edge: .head, to: Time(1), in: &p)
        try TimelineOps.setSpeed(ids[0], .constant(2), in: &p.timeline)
        let clip = p.timeline.clip(ids[0])!
        let segs = SpeechCaptions.segments(Transcript(engine: "t", language: "fr", words: Self.words()), for: clip)
        #expect(!segs.contains { $0.text.contains("Bonjour") })            // before the in-point
        // "Aujourd'hui," at media 2.0 s → timeline (2.0 − 1.0) / 2 = 0.5 s
        #expect(abs(segs[0].start - 0.5) < 0.01)
        #expect(abs(segs[0].words[0].start - 0.5) < 0.01)
        #expect(segs[0].words.count == CaptionText.tokens(segs[0].text).count)
    }

    func captionProject() throws -> (Project, TrackID) {
        var (p, ids) = Fx.project(mainClips: 1, seconds: 8)
        let segs = SpeechCaptions.segments(Transcript(engine: "t", language: "fr", words: Self.words()), for: p.timeline.clip(ids[0])!)
        let id = try #require(CaptionOps.addCaptionTrack(segs, to: &p, origin: .auto, replacing: true))
        SpeechCaptions.finish(trackID: id, in: &p)
        return (p, id)
    }

    @Test func captionTrackUsesTextModelWithWordTimings() throws {
        let (p, id) = try captionProject()
        ok(p)
        let caps = SpeechCaptions.captions(in: p.timeline)
        #expect(caps.count >= 3)
        let first = try #require(CaptionOps.text(caps[0]))
        #expect(first.string == "Bonjour et bienvenue.")
        #expect(first.caption?.origin == .auto)
        let w = CaptionOps.words(of: caps[0])
        #expect(w.map(\.text) == ["Bonjour", "et", "bienvenue."])
        #expect(abs(w[1].start.seconds - 0.45) < 0.01)
        #expect(caps.allSatisfy { $0.linkedTo == p.timeline.mainTrack!.clips[0].id })
        #expect(p.timeline.tracks.contains { $0.id == id })
    }

    @Test func translationsAndKeywords() throws {
        var (p, _) = try captionProject()
        let caps = SpeechCaptions.captions(in: p.timeline)
        SpeechCaptions.setTranslations([caps[0].id: "Hello and welcome."], display: .both, in: &p.timeline)
        let t = try #require(CaptionOps.text(p.timeline.clip(caps[0].id)!))
        #expect(t.caption?.translation == "Hello and welcome." && t.caption?.display == .both)
        let n = SpeechCaptions.markKeywords(["séquence", "Bonjour"], in: &p.timeline)
        #expect(n == 2)
        SpeechCaptions.clearTranslations(in: &p.timeline)
        #expect(CaptionOps.text(p.timeline.clip(caps[0].id)!)?.caption?.translation == nil)
    }

    // MARK: Ripple cuts (EditPilot remove silences)

    @Test func rippleCutShortensMainAndCaptionsFollow() throws {
        var (p, _) = try captionProject()
        let start = { (p: Project) in SpeechCaptions.captions(in: p.timeline).first { CaptionOps.text($0)?.string.hasPrefix("Aujourd") == true }!.start.seconds }
        let before = start(p)
        try RippleCut.rippleDelete([TimeRange(start: Time(1.2), end: Time(1.9))], in: &p)
        ok(p)
        #expect(abs(p.timeline.duration.seconds - (8 - 0.7)) < 0.02)
        #expect(abs(start(p) - (before - 0.7)) < 0.02)
        #expect(throws: EditError.self) { try RippleCut.rippleDelete([], in: &p) }
    }

    @Test func inverseTimeRemapOnCurves() throws {
        var (p, ids) = Fx.project(mainClips: 1, seconds: 8)
        try TimelineOps.setSpeed(ids[0], .curve(SpeedCurve(points: [SpeedPoint(0, 0.5), SpeedPoint(1, 2)])), in: &p.timeline)
        let c = p.timeline.clip(ids[0])!
        for s in stride(from: 0.5, to: c.sourceDuration.seconds - 0.5, by: 0.7) {
            let t = c.timelineTime(forSource: Time(s))!
            #expect(abs(c.sourceTime(at: t).seconds - s) < 0.002)
        }
    }
}
