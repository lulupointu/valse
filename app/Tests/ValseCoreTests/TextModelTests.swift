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
        t.neon = TextNeonStyle(color: .red, intensity: 0.5, glowSize: 0.7, thickness: 0.08, flicker: .broken)
        let back = try JSONDecoder().decode(TextContent.self, from: JSONEncoder().encode(t))
        #expect(back == t && back.neon?.flicker == .broken)
        let old = try JSONDecoder().decode(TextContent.self, from: Data(#"{"string":"Hi"}"#.utf8))
        #expect(old.neon == nil)
        let partial = try JSONDecoder().decode(TextContent.self, from: Data(#"{"string":"Hi","neon":{"flicker":"subtle"}}"#.utf8))
        #expect(partial.neon == TextNeonStyle(flicker: .subtle))
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
                                        outline: TextBubbleOutline(color: .red, width: 0.08, dash: .dotted, neon: TextBubbleOutline.neonStyle(glow: 0.5, flicker: .broken)),
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

    /// TX-NEON: flicker is a pure function of (mode, time, glyph): Off = always lit, Subtle stays bright, Broken drops
    /// some letters out completely for short bursts.
    @Test func neonFlickerIsDeterministic() {
        let times = stride(from: 0.0, to: 20, by: 1.0 / 60).map { $0 }
        for u in 0..<6 {
            #expect(times.allSatisfy { TextNeonStyle.flickerLevel(.off, t: $0, unit: u) == 1 })
            let subtle = times.map { TextNeonStyle.flickerLevel(.subtle, t: $0, unit: u) }
            #expect(subtle.allSatisfy { $0 > 0.6 && $0 <= 1 } && Set(subtle).count > 10)
            #expect(times.map { TextNeonStyle.flickerLevel(.broken, t: $0, unit: u) }
                    == times.map { TextNeonStyle.flickerLevel(.broken, t: $0, unit: u) })
        }
        let broken1 = times.map { TextNeonStyle.flickerLevel(.broken, t: $0, unit: 1) }
        let off = broken1.filter { $0 == 0 }.count
        #expect(off > 10 && off < times.count / 3, "letter 2 drops out sometimes, but is mostly lit")
        // letters differ (per-glyph flicker)
        #expect(broken1 != times.map { TextNeonStyle.flickerLevel(.broken, t: $0, unit: 4) })
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
