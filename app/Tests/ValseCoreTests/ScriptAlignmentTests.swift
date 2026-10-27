import Foundation
import Testing
@testable import ValseCore

@Suite("Text alignment to speech (TX-030)")
struct ScriptAlignmentTests {
    typealias W = ScriptAlignment.TimedWord

    /// Recognized words: "bonjour à tous bienvenue dans ce tuto" at 0.5 s per word, with an error ("tou") and a
    /// missing word ("ce").
    let heard: [W] = [W("Bonjour", 0, 0.4), W("à", 0.5, 0.6), W("tou", 0.7, 1.0), W("bienvenue", 1.5, 2.0),
                      W("dans", 2.1, 2.3), W("tuto.", 3.0, 3.4)]

    @Test func alignsMatchedWordsAndInterpolatesTheRest() {
        let r = ScriptAlignment.align(script: ["Bonjour", "à", "tous,", "bienvenue", "dans", "ce", "tutoriel."], heard: heard)
        #expect(r.words.count == 7)
        #expect(r.words[0].start == 0 && r.words[3].start == 1.5)
        #expect(r.words[2].start == 0.7)                       // "tous," ≈ "tou" (edit distance)
        #expect(r.words[6].start == 3.0)                       // "tutoriel." ≈ "tuto." (prefix)
        // "ce" was not recognized: placed between "dans" (ends 2.3) and "tutoriel" (starts 3.0)
        #expect(r.words[5].start >= 2.3 && r.words[5].end <= 3.0)
        #expect(r.matchRatio > 0.8)
        #expect(r.words.map(\.text) == ["Bonjour", "à", "tous,", "bienvenue", "dans", "ce", "tutoriel."])
    }

    @Test func keepsScriptSpellingAndLineBreaksInCaptions() {
        let script = "Bonjour à tous,\nbienvenue dans ce tutoriel."
        let (segs, ratio) = ScriptAlignment.segments(script: script, heard: heard, language: "fr")
        #expect(ratio > 0.8)
        #expect(segs.count == 2)
        #expect(segs[0].text == "Bonjour à tous,")
        #expect(segs[1].text.contains("tutoriel."))
        #expect(segs[0].end <= segs[1].start)
        #expect(segs[1].words.count == 4)
    }

    @Test func unrelatedScriptHasALowMatchRatio() {
        let r = ScriptAlignment.align(script: ScriptAlignment.tokens("The quick brown fox jumps over the lazy dog"), heard: heard)
        #expect(r.matchRatio < 0.2)
        #expect(ScriptAlignment.align(script: ["a"], heard: []).words.isEmpty)
    }
}
