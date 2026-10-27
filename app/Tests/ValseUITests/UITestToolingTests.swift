import Testing
import Foundation
@testable import ValseUI

/// The UI-test tooling itself: assertion paths, image diff, key parsing.
@MainActor
struct UITestToolingTests {
    let state: [String: Any] = [
        "playhead": 2.5,
        "main": ["clips": [["start": 0.0, "duration": 6.0], ["start": 6.0, "duration": 5.0]]],
        "ui": ["language": "fr", "menu": ["Fichier", "Édition"]],
        "selection": [String](),
    ]

    @Test func paths() {
        #expect(JSONPath.get(state, "main.clips.count") as? Int == 2)
        #expect(JSONPath.get(state, "main.clips.-1.start") as? Double == 6.0)
        #expect(JSONPath.get(state, "main.clips.last.duration") as? Double == 5.0)
        #expect(JSONPath.get(state, "ui.nope") == nil)
        #expect(JSONPath.get(state, "selection.count") as? Int == 0)
    }

    @Test func expectations() {
        #expect(JSONPath.check(state, ["path": "playhead", "approx": 2.5]) == nil)
        #expect(JSONPath.check(state, ["path": "main.clips.count", "equals": 2]) == nil)
        #expect(JSONPath.check(state, ["path": "main.clips.count", "equals": 3]) != nil)
        #expect(JSONPath.check(state, ["path": "ui.menu", "contains": "Fichier"]) == nil)
        #expect(JSONPath.check(state, ["path": "main.clips.0.duration", "gt": 5, "lt": 7]) == nil)
        #expect(JSONPath.check(state, ["path": "ui.language", "notEquals": "en"]) == nil)
        #expect(JSONPath.check(state, ["path": "ui.toast", "exists": false]) == nil)
        #expect(JSONPath.check(state, ["path": "x", "bogus": 1]) != nil)
    }

    @Test func imageDiff() {
        let w = 10, h = 10
        let a = ImageDiff.Pixels(width: w, height: h, data: [UInt8](repeating: 128, count: w * h * 4))
        var b = a
        #expect(ImageDiff().compare(a, b).0.passed)
        b.data[0] = 255  // one pixel = 1 %
        let strict = ImageDiff(threshold: 16, tolerance: 0.005).compare(a, b).0
        #expect(!strict.passed && strict.differingPixels == 1)
        #expect(ImageDiff(threshold: 16, tolerance: 0.02).compare(a, b).0.passed)
        #expect(ImageDiff(threshold: 200, tolerance: 0).compare(a, b).0.passed)
        let c = ImageDiff.Pixels(width: 5, height: 5, data: [UInt8](repeating: 0, count: 100))
        #expect(ImageDiff().compare(a, c).0.sizeMismatch)
    }

    @Test func keys() {
        let k = SyntheticEvents.parseKey("cmd+shift+z")!
        #expect(k.code == 6 && k.mods.contains(.command) && k.mods.contains(.shift))
        #expect(SyntheticEvents.parseKey("space")!.code == 49)
        #expect(SyntheticEvents.parseKey("cmd++")!.charsIgnoringMods == "+")
        #expect(SyntheticEvents.parseKey("left")!.mods.contains(.function))
        #expect(SyntheticEvents.parseKey("nope") == nil)
    }
}
