import Testing
import Foundation
@testable import MontageCore

/// W10 speech → captions (on the W7 caption model), fillers, WER, transcript-based editing.
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

    func captionProject(fillers: Bool = false) throws -> (Project, TrackID) {
        var (p, ids) = Fx.project(mainClips: 1, seconds: 8)
        let segs = SpeechCaptions.segments(Transcript(engine: "t", language: "fr", words: Self.words()), for: p.timeline.clip(ids[0])!)
        let id = try #require(CaptionOps.addCaptionTrack(segs, to: &p, origin: .auto, replacing: true))
        SpeechCaptions.finish(trackID: id, language: "fr", in: &p, identifyFillers: fillers)
        return (p, id)
    }

    @Test func captionTrackUsesTextModelWithWordTimings() throws {
        let (p, id) = try captionProject(fillers: true)
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
        let all = caps.flatMap { CaptionOps.text($0)?.caption?.words ?? [] }
        #expect(all.first { $0.text == "euh" }?.filler == true)
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

    // MARK: Transcript-based editing

    @Test func deletingWordsRippleCutsTheMainTrack() throws {
        var (p, ids) = Fx.project(mainClips: 1, seconds: 8)
        let mid = p.timeline.clip(ids[0])!.mediaID!
        let tr = [mid: Transcript(engine: "t", language: "fr", words: Self.words())]
        var placed = TranscriptEditing.placedWords(transcripts: tr, timeline: p.timeline)
        #expect(placed.count == Self.words().count)
        try TranscriptEditing.deleteWords(placed.filter { $0.word.text == "euh" }, in: &p)
        ok(p)
        #expect(p.timeline.mainTrack!.clips.count == 2)
        #expect(abs(p.timeline.duration.seconds - (8 - 0.2)) < 0.02)
        placed = TranscriptEditing.placedWords(transcripts: tr, timeline: p.timeline)
        #expect(placed.first { $0.word.text == "euh" }?.isDeleted == true)
        #expect(placed.first { $0.word.text == "nous" }?.isDeleted == false)
        try TranscriptEditing.restore(placed.filter(\.isDeleted), in: &p)
        ok(p)
        #expect(abs(p.timeline.duration.seconds - 8) < 0.02)
        #expect(TranscriptEditing.placedWords(transcripts: tr, timeline: p.timeline).allSatisfy { !$0.isDeleted })
    }

    @Test func pausesAreReported() {
        let (p, ids) = Fx.project(mainClips: 1, seconds: 8)
        let mid = p.timeline.clip(ids[0])!.mediaID!
        let placed = TranscriptEditing.placedWords(transcripts: [mid: Transcript(engine: "t", language: "fr", words: Self.words())], timeline: p.timeline)
        let pauses = TranscriptEditing.pauses(placed, minimum: 0.5)
        #expect(pauses.count == 1)
        #expect(abs(pauses[0].seconds - 0.9) < 1e-6)
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
