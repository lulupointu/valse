import Testing
import Foundation
@testable import MontageCore

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
        t.caption = CaptionData(words: [CaptionWord("Hello", start: 0, end: 0.5, keyword: true)], translation: "Bonjour", origin: .auto)
        t.karaoke = KaraokeStyle(mode: .reveal)
        t.template = TextTemplateInstance(templateID: "x", texts: ["a"])
        let back = try JSONDecoder().decode(TextContent.self, from: JSONEncoder().encode(t))
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
