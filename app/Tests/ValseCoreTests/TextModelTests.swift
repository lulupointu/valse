import Testing
import Foundation
@testable import ValseCore

/// Text model: backward-compatible decoding, rich-text runs editing, tokenizer.
struct TextModelTests {
    @Test func oldTextJSONDecodesWithDefaults() throws {
        // A text clip as written before the rich text model existed.
        let json = """
        {"string":"Hi","fontName":"","fontSize":0.06,"color":{"r":1,"g":1,"b":1,"a":1},"alignment":"center","bold":true,
         "italic":false,"strokeColor":{"r":0,"g":0,"b":0,"a":1},"strokeWidth":0.1,"backgroundColor":{"r":0,"g":0,"b":0,"a":0},
         "shadowColor":{"r":0,"g":0,"b":0,"a":0},"lineSpacing":0,"letterSpacing":0}
        """
        let t = try JSONDecoder().decode(TextContent.self, from: Data(json.utf8))
        #expect(t.string == "Hi" && t.bold && t.strokeWidth == 0.1)
        #expect(t.textCase == .none && t.runs.isEmpty && t.caption == nil && t.curve == 0 && t.background == TextBackgroundStyle())
    }

    @Test func fullTextRoundTrips() throws {
        var t = TextContent(string: "Hello world")
        t.underline = true; t.textCase = .upper; t.orientation = .vertical
        t.extraStrokes = [TextStrokeLayer(color: .red, width: 0.2)]
        t.glow = TextGlowStyle(color: .blue); t.fill = .gradient(TextGradient([.red, .blue], angle: 30))
        t.path = TextPathShape(.wave, amount: 0.3); t.boxWidth = 0.5; t.bubbleID = "b"
        t.applyStyle(TextRunStyle(color: .green, bold: true), to: TextSpan(0, 5))
        t.caption = CaptionData(words: [CaptionWord("Hello", start: 0, end: 0.5, filler: true)], translation: "Bonjour", origin: .auto)
        t.karaoke = KaraokeStyle(mode: .reveal)
        t.template = TextTemplateInstance(templateID: "x", texts: ["a"])
        let back = try JSONDecoder().decode(TextContent.self, from: JSONEncoder().encode(t))
        #expect(back == t)
    }

    /// TX-NEON: the neon style round-trips; files without it (or with only some of its fields) still open.
    @Test func neonRoundTripsAndOldFilesOpen() throws {
        var t = TextContent(string: "Open")
        #expect(t.neon == nil)
        t.neon = TextNeonStyle(color: .red, intensity: 0.5, glowSize: 0.7, thickness: 0.08, flicker: .oneLetter)
        let back = try JSONDecoder().decode(TextContent.self, from: JSONEncoder().encode(t))
        #expect(back == t && back.neon?.flicker == .oneLetter)
        let old = try JSONDecoder().decode(TextContent.self, from: Data(#"{"string":"Hi"}"#.utf8))
        #expect(old.neon == nil)
        let partial = try JSONDecoder().decode(TextContent.self, from: Data(#"{"string":"Hi","neon":{"flicker":"subtle"}}"#.utf8))
        #expect(partial.neon == TextNeonStyle(flicker: .wholeText))
        // the encoded JSON has no neon key while off (old builds read new files unchanged)
        let json = String(decoding: try JSONEncoder().encode(TextContent(string: "x")), as: UTF8.self)
        #expect(!json.contains("neon"))
    }

    /// TX-BUBBLE2: v1 files (bubbleID + bubbleColor) open with no bubbleStyle; a full style round-trips; partial
    /// styles decode with defaults; an older app reading a new file still finds bubbleID / bubbleColor.
    @Test func bubbleStyleIsBackwardAndForwardCompatible() throws {
        let v1 = try JSONDecoder().decode(TextContent.self, from: Data(#"{"string":"Hi","bubbleID":"valse.bubble.speechWhite","bubbleColor":{"r":1,"g":0,"b":0,"a":1}}"#.utf8))
        #expect(v1.bubbleStyle == nil && v1.bubbleID == "valse.bubble.speechWhite" && v1.bubbleColor == RGBA(1, 0, 0, 1))
        var t = TextContent(string: "Hi")
        t.bubbleID = "valse.bubble.neonPinkPill"
        t.bubbleStyle = TextBubbleStyle(family: .cloud, cornerRadius: 0.4, spikes: 18, depth: 0.32, bumps: 13, jitter: 0.5, fold: 0.4,
                                        barHeight: 0.3, tail: TextBubbleTail(side: .topRight, kind: .dots, length: 1.2, width: 0.5, lean: 0.3, position: 0.25),
                                        padding: Vec2(0.3, 0.2), fill: RGBA(0, 0, 0, 0.5),
                                        outline: TextBubbleOutline(color: .red, width: 0.08, dash: .dotted, neon: TextBubbleOutline.neonStyle(glow: 0.5, flicker: .oneLetter)),
                                        shadow: TextBubbleShadow(color: .blue, kind: .hard), containsText: true)
        let data = try JSONEncoder().encode(t)
        let back = try JSONDecoder().decode(TextContent.self, from: data)
        #expect(back == t)
        // older app: knows bubbleID / bubbleColor only, ignores bubbleStyle
        struct V1Text: Decodable { var string: String; var bubbleID: String?; var bubbleColor: RGBA? }
        let old = try JSONDecoder().decode(V1Text.self, from: data)
        #expect(old.bubbleID == "valse.bubble.neonPinkPill" && old.bubbleColor == nil)
        // partial style → defaults
        let partial = try JSONDecoder().decode(TextContent.self, from: Data(#"{"string":"Hi","bubbleStyle":{"family":"oval","tail":{"side":"left"}}}"#.utf8))
        #expect(partial.bubbleStyle?.family == .oval && partial.bubbleStyle?.tail == TextBubbleTail(side: .left)
                && partial.bubbleStyle?.padding == Vec2(0.45, 0.3) && partial.bubbleStyle?.outline == nil)
        // no bubbleStyle key while unset
        #expect(!String(decoding: try JSONEncoder().encode(TextContent(string: "x")), as: UTF8.self).contains("bubbleStyle"))
        // caption style sync copies the field
        #expect(CaptionStyleSync.Diff.knownKeys.contains("bubbleStyle"))
        var a = TextContent(string: "a"), b = TextContent(string: "b")
        b.bubbleStyle = TextBubbleStyle(family: .burst, fill: .white)
        CaptionStyleSync.Diff(TextContent(string: "a"), b).apply(to: &a)
        #expect(a.bubbleStyle == b.bubbleStyle && a.string == "a")
    }

    @Test func bubbleEdgeAndFamilyHelpers() {
        var s = TextBubbleStyle(family: .burst, fill: .white)
        #expect(s.edge == .spiky)
        s.setEdge(.wild); #expect(s.edge == .wild && s.spikes == 18 && s.jitter > 0)
        s.setEdge(.calm); #expect(s.edge == .calm && s.spikes == 10 && s.jitter == 0)
        s.tail = TextBubbleTail(side: .bottom)
        s.setFamily(.banner); #expect(s.tail == nil)
        s.setFamily(.oval); #expect(s.containsText)
        s.scalePadding(to: 2, base: Vec2(0.4, 0.2)); #expect(s.padding == Vec2(0.8, 0.4))
    }

    /// TX-NEON: flicker is a pure function of (mode, time, unit, seed). Off = always lit; Whole text = one level for
    /// every unit, steady most of the time with rare stutters; One letter = exactly one unit ever dims.
    @Test func neonFlickerIsDeterministic() {
        let times = stride(from: 0.0, to: 120, by: 1.0 / 60).map { $0 }
        let seed = TextNeonStyle.flickerSeed("NEON BAR")
        let faulty = TextNeonStyle.faultyUnit(in: "NEON BAR")
        for u in 0..<7 {
            #expect(times.allSatisfy { TextNeonStyle.flickerLevel(.off, t: $0, unit: u, faultyUnit: faulty) == 1 })
            // same inputs → same output (preview = export)
            #expect(times.map { TextNeonStyle.flickerLevel(.oneLetter, t: $0, unit: u, faultyUnit: faulty, seed: seed) }
                    == times.map { TextNeonStyle.flickerLevel(.oneLetter, t: $0, unit: u, faultyUnit: faulty, seed: seed) })
        }
        // Whole text: every unit shares one level
        let whole = times.map { TextNeonStyle.flickerLevel(.wholeText, t: $0, unit: 0, faultyUnit: faulty, seed: seed) }
        for u in 1..<7 {
            #expect(times.map { TextNeonStyle.flickerLevel(.wholeText, t: $0, unit: u, faultyUnit: faulty, seed: seed) } == whole)
        }
        #expect(whole.prefix(60).allSatisfy { $0 == 1 }, "no event in the first second")
        let wholeDim = whole.filter { $0 < 1 }.count
        #expect(wholeDim > 0 && Double(wholeDim) / Double(whole.count) < 0.15, "mostly steady, with some stutters")
        #expect(whole.allSatisfy { $0 >= 0 && $0 <= 1 })
        // One letter: only the faulty unit ever dims; it dims more often than the whole sign
        #expect(faulty == 4, "NEON BAR: the letter ~60 % through (B), spaces skipped")
        for u in 0..<7 where u != faulty {
            #expect(times.allSatisfy { TextNeonStyle.flickerLevel(.oneLetter, t: $0, unit: u, faultyUnit: faulty, seed: seed) == 1 })
        }
        let bad = times.map { TextNeonStyle.flickerLevel(.oneLetter, t: $0, unit: 4, faultyUnit: faulty, seed: seed) }
        let badDim = bad.filter { $0 < 1 }.count
        #expect(badDim > wholeDim && Double(badDim) / Double(bad.count) < 0.4)
        // it sometimes stays dead ≥ 0.6 s
        #expect(longestRun(bad, fps: 60) { $0 < 0.2 } >= 0.55)
        // another text flickers on its own schedule
        #expect(times.map { TextNeonStyle.flickerLevel(.wholeText, t: $0, seed: TextNeonStyle.flickerSeed("OPEN")) } != whole)
    }

    /// TX-NEON: no dropout (level below half) is shorter than 2 frames at 30 fps, so no frame rate drops a whole
    /// dropout or shows it as a 1-frame strobe; the level ramps (decay / relight), it is not binary.
    @Test func neonFlickerDropoutsLastTwoFrames() {
        let dt = 0.001
        let times = stride(from: 0.0, to: 120, by: dt).map { $0 }
        for (mode, text) in [(TextNeonFlicker.wholeText, "OPEN"), (.oneLetter, "OPEN"), (.wholeText, "NEON BAR"), (.oneLetter, "NEON BAR")] {
            let l = times.map { TextNeonStyle.flickerLevel(mode, t: $0, faulty: true, seed: TextNeonStyle.flickerSeed(text)) }
            var run = 0, runs: [Int] = []
            for v in l { if v < 0.5 { run += 1 } else if run > 0 { runs.append(run); run = 0 } }
            #expect(runs.count > 20, "\(mode) \(text): dropouts happen")
            #expect(runs.allSatisfy { Double($0) * dt >= 2.0 / 30 }, "\(mode) \(text): shortest \(runs.min() ?? 0) ms")
            #expect(Set(l.map { ($0 * 20).rounded() }).count > 10, "continuous ramps, not on/off")
        }
    }

    /// Longest stretch (seconds) where `pred` holds in a curve sampled at `fps`.
    func longestRun(_ l: [Double], fps: Double, _ pred: (Double) -> Bool) -> Double {
        var best = 0, cur = 0
        for v in l { cur = pred(v) ? cur + 1 : 0; best = max(best, cur) }
        return Double(best) / fps
    }

    /// TX-NEON: the flicker modes keep their pre-rework raw values (old projects open with the same mode).
    @Test func neonFlickerRawValuesAreBackCompatible() throws {
        #expect(TextNeonFlicker.wholeText.rawValue == "subtle" && TextNeonFlicker.oneLetter.rawValue == "broken")
        let a = try JSONDecoder().decode(TextNeonStyle.self, from: Data(#"{"flicker":"subtle"}"#.utf8))
        let b = try JSONDecoder().decode(TextNeonStyle.self, from: Data(#"{"flicker":"broken"}"#.utf8))
        #expect(a.flicker == .wholeText && b.flicker == .oneLetter)
        #expect(TextNeonStyle.faultyUnit(in: "OPEN") == 2 && TextNeonStyle.faultyUnit(in: "!!") == nil
                && TextNeonStyle.faultyUnit(in: "A, B") == 2)
    }

    /// FB-04: Spoken word off keeps its style (inactive, persisted); on restores it, defaults the first time.
    @Test func spokenWordToggleRemembersItsStyle() throws {
        var t = TextContent(string: "Hello")
        t.setSpokenWord(false)
        #expect(t.karaoke == nil && t.inactiveKaraoke == nil)
        t.setSpokenWord(true)
        #expect(t.karaoke == KaraokeStyle() && t.inactiveKaraoke == nil)
        let custom = KaraokeStyle(mode: .fillSpoken, highlightColor: .red, highlightScale: 1.4, unspokenOpacity: 0.3, bounce: 0.2)
        t.karaoke = custom
        t.setSpokenWord(false)
        #expect(t.karaoke == nil && t.inactiveKaraoke == custom && t.spokenWordStyle == custom)
        let back = try JSONDecoder().decode(TextContent.self, from: JSONEncoder().encode(t))
        #expect(back.inactiveKaraoke == custom && back.karaoke == nil)
        t.setSpokenWord(false)   // already off: unchanged
        #expect(t.inactiveKaraoke == custom)
        t.setSpokenWord(true)
        #expect(t.karaoke == custom && t.inactiveKaraoke == nil)
    }

    /// FB-03: "Highlight keywords" is gone; projects saved with keyword flags / keyword styling still open (keys ignored).
    @Test func legacyKeywordFieldsAreIgnored() throws {
        var t = TextContent(string: "Hello")
        t.caption = CaptionData(words: [CaptionWord("Hello", start: 0, end: 0.5)], origin: .auto)
        t.karaoke = KaraokeStyle(mode: .fillSpoken)
        var j = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(t)) as? [String: Any])
        var cap = try #require(j["caption"] as? [String: Any]), words = try #require(cap["words"] as? [[String: Any]])
        words[0]["keyword"] = true; cap["words"] = words; j["caption"] = cap
        var k = try #require(j["karaoke"] as? [String: Any])
        k["keywordColor"] = ["r": 1, "g": 0, "b": 0, "a": 1]; k["keywordScale"] = 1.25; j["karaoke"] = k
        let back = try JSONDecoder().decode(TextContent.self, from: JSONSerialization.data(withJSONObject: j))
        #expect(back == t)
    }

    @Test func typingKeepsRunsOnTheirCharacters() {
        var t = TextContent(string: "Hello world")
        t.applyStyle(TextRunStyle(color: .red), to: TextSpan(6, 5))      // "world" red
        t.setString("Hey, hello world")                                      // insert before
        #expect(t.runs.count == 1 && t.runs[0].range == TextSpan(11, 5))
        t.setString("Hey, hello world!!")                                    // typing at the run end extends it
        #expect(t.runs[0].range == TextSpan(11, 7))
        t.setString("Hey, hello")                                            // delete the styled part
        #expect(t.runs.isEmpty)
    }

    @Test func applyStyleSplitsAndMergesRuns() {
        var t = TextContent(string: "abcdefghij")
        t.applyStyle(TextRunStyle(color: .red), to: TextSpan(2, 6))
        t.applyStyle(TextRunStyle(bold: true), to: TextSpan(4, 4))
        #expect(t.runs.map(\.range) == [TextSpan(2, 2), TextSpan(4, 4)])
        #expect(t.runStyle(at: 5).color == .red && t.runStyle(at: 5).bold == true)
        #expect(t.runStyle(at: 3).bold == false)                 // inherits the clip-wide value
        #expect(t.commonStyle(in: TextSpan(2, 6)).color == .red)
        #expect(t.commonStyle(in: TextSpan(2, 6)).bold == nil)  // mixed
        // whole-text edits go to the base style and clear the override
        t.applyStyle(TextRunStyle(color: .blue), to: TextSpan(0, 10))
        #expect(t.color == .blue && t.runs.allSatisfy { $0.style.color == nil })
    }

    @Test func caseTransforms() {
        var t = TextContent(string: "hello World")
        t.textCase = .upper; #expect(t.displayString == "HELLO WORLD")
        t.textCase = .title; #expect(t.displayString == "Hello World")
        t.textCase = .lower; #expect(t.displayString == "hello world")
    }

    @Test func tokenizerHandlesSpacesAndCJK() {
        #expect(TextTokenizer.tokens("  one two\nthree ") == ["one", "two", "three"])
        #expect(TextTokenizer.tokens("你好世界") == ["你", "好", "世", "界"])
        #expect(TextTokenizer.words(in: "é ü").map(\.location) == [0, 2])
    }

    @Test func adoptLookKeepsTextAndCaption() {
        var a = TextContent(string: "mine"); a.caption = CaptionData(words: [CaptionWord("mine", start: 0, end: 1)])
        var b = TextContent(string: "theirs"); b.color = .red; b.strokeWidth = 0.1
        a.adoptLook(of: b)
        #expect(a.string == "mine" && a.color == .red && a.strokeWidth == 0.1 && a.caption?.words.count == 1)
        #expect(a.sameLook(as: b))
    }
}
