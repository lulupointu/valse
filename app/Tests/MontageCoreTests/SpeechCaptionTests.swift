import Testing
import Foundation
@testable import MontageCore

/// W10 caption model + pure caption/transcript edits (MontageCore/Captions).
@Suite struct CaptionTests {
    func ok(_ p: Project) { #expect(TimelineOps.validate(p.timeline).isEmpty, "\(TimelineOps.validate(p.timeline))") }

    /// "Bonjour et bienvenue. Aujourd'hui nous allons … " with a long pause after "bienvenue."
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
        let segs = CaptionSegmenter.segments(Self.words(), language: "fr")
        #expect(segs.first?.text == "Bonjour et bienvenue.")
        #expect(segs.count >= 3)
        for s in segs {
            #expect(s.lines.count <= 2)
            for l in s.lines { #expect(l.count <= 28, "line too long: \(l)") }
        }
        // every word appears once, in order
        #expect(segs.flatMap(\.words).map(\.text) == Self.words().map(\.text))
    }

    @Test func wrapBalancesTwoLines() {
        let lines = CaptionSegmenter.wrap(["Pour", "couper", "un", "plan,", "placez", "la", "tête", "de", "lecture"], maxChars: 28)
        #expect(lines.count == 2)
        #expect(abs(lines[0].count - lines[1].count) < 10)
    }

    @Test func fillersAreClassifiedAndRemovable() {
        let k = FillerWords.classify(["Alors", "euh", "le", "le", "film,", "du", "coup,", "nous", "nous", "sommes"], language: "fr")
        #expect(k[1] == .hesitation)
        #expect(k[2] == .repetition && k[3] == nil)
        #expect(k[5] == .filler && k[6] == .filler)
        #expect(k[7] == nil && k[8] == nil)      // "nous nous" is legitimate
        var s = CaptionSettings(); s.removeFillers = true
        let segs = CaptionSegmenter.segments(Self.words(), language: "fr", settings: s)
        #expect(!segs.map(\.text).joined(separator: " ").contains("euh"))
    }

    @Test func werCountsSubstitutionsInsertionsDeletions() {
        #expect(WordErrorRate.compute(reference: "Bonjour et bienvenue", hypothesis: "bonjour, et bienvenue !") == 0)
        #expect(abs(WordErrorRate.compute(reference: "a b c d", hypothesis: "a x c") - 0.5) < 1e-9)
        #expect(WordErrorRate.compute(reference: "aujourd'hui", hypothesis: "Aujourd’hui") == 0)
    }

    @Test func captionsMapThroughTrimAndSpeed() throws {
        var (p, ids) = Fx.project(mainClips: 1, seconds: 8)
        // trim the head by 1 s of media and play at 2×
        try TimelineOps.trim(ids[0], edge: .head, to: Time(1), in: &p)
        try TimelineOps.setSpeed(ids[0], .constant(2), in: &p.timeline)
        let clip = p.timeline.clip(ids[0])!
        #expect(clip.sourceStart == Time(1))
        let t = Transcript(engine: "test", language: "fr", words: Self.words())
        let caps = CaptionOps.makeCaptions(t, for: clip, linked: true)
        #expect(!caps.isEmpty)
        // "Bonjour et bienvenue." (media 0–1.1 s) is before the in-point → dropped
        #expect(!caps.contains { if case .text(let x) = $0.content { return x.string.contains("Bonjour") }; return false })
        let first = caps[0]
        // "Aujourd'hui," at media 2.0 s → timeline (2.0 − 1.0) / 2 = 0.5 s
        #expect(abs(first.start.seconds - 0.5) < 0.01)
        #expect(first.caption?.words.first.map { abs($0.start.seconds) < 0.01 } == true)
        #expect(first.linkedTo == ids[0])
        try CaptionOps.insert(caps, into: &p, replaceExisting: true)
        ok(p)
        #expect(p.timeline.tracks.contains { $0.isCaptionTrack })
    }

    func captionProject() throws -> (Project, [ClipID]) {
        var (p, ids) = Fx.project(mainClips: 1, seconds: 8)
        let caps = CaptionOps.makeCaptions(Transcript(engine: "t", language: "fr", words: Self.words()), for: p.timeline.clip(ids[0])!, linked: true)
        try CaptionOps.insert(caps, into: &p, replaceExisting: true)
        return (p, CaptionOps.captions(in: p.timeline).map(\.id))
    }

    @Test func regenerateReplacesExistingCaptions() throws {
        var (p, caps) = try captionProject()
        let again = CaptionOps.makeCaptions(Transcript(engine: "t", language: "fr", words: Self.words()), for: p.timeline.mainTrack!.clips[0], linked: true)
        try CaptionOps.insert(again, into: &p, replaceExisting: true)
        #expect(CaptionOps.captions(in: p.timeline).count == caps.count)
        #expect(p.timeline.tracks.filter(\.isCaptionTrack).count == 1)
        try CaptionOps.insert(again, into: &p, replaceExisting: false)   // keep: a second track
        #expect(p.timeline.tracks.filter(\.isCaptionTrack).count == 2)
        caps = []
        ok(p)
    }

    @Test func setTextResyncsWords() throws {
        var (p, caps) = try captionProject()
        let id = caps[0]
        try CaptionOps.setText(id, "Bonjour à tous et bienvenue.", in: &p.timeline)
        let c = p.timeline.clip(id)!
        #expect(CaptionOps.mainText(c) == "Bonjour à tous et bienvenue.")
        #expect(c.caption!.words.map(\.text) == ["Bonjour", "à", "tous", "et", "bienvenue."])
        let w = c.caption!.words
        for i in w.indices.dropLast() { #expect(w[i].end <= w[i + 1].start + Time(ticks: 2)) }
    }

    @Test func splitAndMergeCaptions() throws {
        var (p, caps) = try captionProject()
        let id = caps[0]
        let main = CaptionOps.mainText(p.timeline.clip(id)!)          // "Bonjour et bienvenue."
        let off = main.distance(from: main.startIndex, to: main.range(of: "et")!.lowerBound)
        let right = try CaptionOps.split(id, atCharacter: off, in: &p.timeline)
        #expect(CaptionOps.mainText(p.timeline.clip(id)!) == "Bonjour")
        #expect(CaptionOps.mainText(p.timeline.clip(right)!) == "et bienvenue.")
        // the right half starts at "et" (0.45 s)
        #expect(abs(p.timeline.clip(right)!.start.seconds - 0.45) < 0.01)
        #expect(p.timeline.clip(right)!.caption!.words.first!.start == .zero)
        ok(p)
        try CaptionOps.mergeWithNext(id, in: &p.timeline)
        #expect(CaptionOps.mainText(p.timeline.clip(id)!) == "Bonjour et bienvenue.")
        #expect(p.timeline.clip(right) == nil)
        #expect(p.timeline.clip(id)!.caption!.words.count == 3)
        ok(p)
    }

    @Test func timelineSplitPartitionsCaptionWords() throws {
        var (p, caps) = try captionProject()
        let id = caps[0]
        let r = try TimelineOps.split(id, at: Time(0.42), in: &p.timeline)
        guard case .text(let lt) = p.timeline.clip(id)!.content, case .text(let rt) = p.timeline.clip(r)!.content else { Issue.record("not text"); return }
        #expect(lt.string == "Bonjour")
        #expect(rt.string == "et bienvenue.")
        #expect(p.timeline.clip(r)!.caption!.words[0].start < Time(0.1))
    }

    @Test func findReplaceAndSearch() throws {
        var (p, _) = try captionProject()
        #expect(CaptionOps.search("SÉQUENCE", in: p.timeline).count == 1)
        let n = CaptionOps.replaceAll("vidéo", with: "film", in: &p.timeline)
        #expect(n == 1)
        #expect(CaptionOps.captions(in: p.timeline).contains { CaptionOps.mainText($0).contains("film") })
    }

    @Test func translationsAndDisplayModes() throws {
        var (p, caps) = try captionProject()
        CaptionOps.setTranslations([caps[0]: "Hello and welcome."], language: "en", display: .bilingual, in: &p.timeline)
        var c = p.timeline.clip(caps[0])!
        guard case .text(let t) = c.content else { return }
        #expect(t.string == "Bonjour et bienvenue.\nHello and welcome.")
        #expect(CaptionOps.mainText(c) == "Bonjour et bienvenue.")
        CaptionOps.setDisplay(.translationOnly, in: &p.timeline)
        c = p.timeline.clip(caps[0])!
        if case .text(let t2) = c.content { #expect(t2.string == "Hello and welcome.") }
        #expect(CaptionOps.mainText(c) == "Bonjour et bienvenue.")
        // editing the main text keeps the translation display
        try CaptionOps.setText(caps[0], "Salut.", in: &p.timeline)
        c = p.timeline.clip(caps[0])!
        #expect(CaptionOps.mainText(c) == "Salut.")
        CaptionOps.clearTranslations(in: &p.timeline)
        if case .text(let t3) = p.timeline.clip(caps[0])!.content { #expect(t3.string == "Salut.") }
    }

    @Test func applyStyleToAllCaptions() throws {
        var (p, caps) = try captionProject()
        try p.timeline[clip: caps[0]].map { c in
            var c = c
            if case .text(var t) = c.content { t.color = .red; t.fontSize = 0.08; c.content = .text(t) }
            c.transform.position = Vec2(0, -0.3)
            p.timeline[clip: caps[0]] = c
        }
        try CaptionOps.applyStyleToAll(from: caps[0], in: &p.timeline)
        for id in caps {
            let c = p.timeline.clip(id)!
            guard case .text(let t) = c.content else { continue }
            #expect(t.color == .red && t.fontSize == 0.08)
            #expect(c.transform.position == Vec2(0, -0.3))
        }
        #expect(Set(CaptionOps.captions(in: p.timeline).map(CaptionOps.mainText)).count == caps.count)  // texts kept
    }

    @Test func srtVttTxtExport() throws {
        let (p, _) = try captionProject()
        let srt = CaptionExport.export(p.timeline, format: .srt)
        #expect(srt.hasPrefix("1\n00:00:00,000 --> 00:00:01,100\nBonjour et bienvenue.\n"))
        let vtt = CaptionExport.export(p.timeline, format: .vtt)
        #expect(vtt.hasPrefix("WEBVTT\n\n00:00:00.000 --> "))
        #expect(CaptionExport.export(p.timeline, format: .txt).split(separator: "\n").count == CaptionOps.captions(in: p.timeline).count)
    }

    @Test func captionsPersistRoundTrip() throws {
        let (p, caps) = try captionProject()
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Project.self, from: data)
        #expect(back.timeline.clip(caps[0])?.caption == p.timeline.clip(caps[0])?.caption)
    }

    // MARK: Transcript-based editing

    @Test func deletingWordsRippleCutsTheMainTrack() throws {
        var (p, ids) = Fx.project(mainClips: 1, seconds: 8)
        let mid = p.timeline.clip(ids[0])!.mediaID!
        let tr = [mid: Transcript(engine: "t", language: "fr", words: Self.words())]
        var placed = TranscriptEditing.placedWords(transcripts: tr, timeline: p.timeline)
        #expect(placed.count == Self.words().count)
        // delete "euh" (2.6–2.8)
        let euh = placed.filter { $0.word.text == "euh" }
        try TranscriptEditing.deleteWords(euh, in: &p)
        ok(p)
        let main = p.timeline.mainTrack!.clips
        #expect(main.count == 2)
        #expect(abs(p.timeline.duration.seconds - (8 - 0.2)) < 0.02)
        placed = TranscriptEditing.placedWords(transcripts: tr, timeline: p.timeline)
        #expect(placed.first { $0.word.text == "euh" }?.isDeleted == true)
        #expect(placed.first { $0.word.text == "nous" }?.isDeleted == false)
        // restore puts the media back
        try TranscriptEditing.restore(placed.filter(\.isDeleted), in: &p)
        ok(p)
        #expect(abs(p.timeline.duration.seconds - 8) < 0.02)
        placed = TranscriptEditing.placedWords(transcripts: tr, timeline: p.timeline)
        #expect(placed.allSatisfy { !$0.isDeleted })
    }

    @Test func pausesAreReported() {
        var (p, ids) = Fx.project(mainClips: 1, seconds: 8)
        let mid = p.timeline.clip(ids[0])!.mediaID!
        let placed = TranscriptEditing.placedWords(transcripts: [mid: Transcript(engine: "t", language: "fr", words: Self.words())], timeline: p.timeline)
        let pauses = TranscriptEditing.pauses(placed, minimum: 0.5)
        #expect(pauses.count == 1)
        #expect(abs(pauses[0].seconds - 0.9) < 1e-6)
        p = Project()
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
