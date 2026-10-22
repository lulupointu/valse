import Testing
import Foundation
@testable import MontageCore
@testable import MontageEngine
import MontageEffects
import MontageTestSupport

/// Text finisher rows: counters (TX-039), separated template parts (TX-032).
@Suite struct TextFinishRenderTests {

    @Test func counterFormatsNumbersTimersAndDates() {
        let n = TextCounter(from: 0, to: 12_500, decimals: 0, suffix: " €", easeOut: false, countFraction: 1)
        #expect(n.string(at: Time(0), duration: Time(4), language: "en") == "0 €")
        #expect(n.string(at: Time(4), duration: Time(4), language: "en") == "12,500 €")
        #expect(n.string(at: Time(2), duration: Time(4), language: "en") == "6,250 €")
        #expect(n.string(at: Time(4), duration: Time(4), language: "fr") == "12\u{202F}500 €")
        #expect(n.string(at: Time(9), duration: Time(4), language: "en") == "12,500 €")   // holds past the end
        let d = TextCounter(from: 0, to: 1, decimals: 2, easeOut: false, countFraction: 0.5)
        #expect(d.string(at: Time(1), duration: Time(4), language: "fr") == "0,50")
        #expect(d.string(at: Time(2), duration: Time(4), language: "en") == "1.00")
        let timer = TextCounter.defaults(.timer)
        #expect(timer.string(at: Time(0), duration: Time(10)) == "0:10")
        #expect(timer.string(at: Time(10), duration: Time(10)) == "0:00")
        #expect(TextCounter(kind: .timer, from: 3725, to: 0).format(3725, language: "en") == "1:02:05")
        var date = TextCounter(kind: .date, from: TextCounter.day(2026, 10, 19), to: TextCounter.day(2026, 10, 19))
        #expect(date.string(at: Time(0), duration: Time(2), language: "en") == "19/10/2026")
        date.dateFormat = .ymd
        #expect(date.string(at: Time(0), duration: Time(2), language: "en") == "2026-10-19")
        date.dateFormat = .long
        #expect(date.string(at: Time(0), duration: Time(2), language: "fr") == "19 octobre 2026")
        // ease-out is ahead of linear mid-way, both land on the end value
        let e = TextCounter(from: 0, to: 100, easeOut: true, countFraction: 1)
        #expect(e.value(progress: e.progress(at: Time(1), duration: Time(2))) > 50)
        #expect(e.value(progress: e.progress(at: Time(2), duration: Time(2))) == 100)
    }

    @Test func counterAndSeparatedLayersRoundTrip() throws {
        var t = TextContent(string: "x")
        t.counter = TextCounter(kind: .timer, from: 5, to: 0)
        t.template = TextTemplateInstance(templateID: "montage.template.lowerThird", texts: ["b"], layers: [1, 3], language: "fr")
        let back = try JSONDecoder().decode(TextContent.self, from: JSONEncoder().encode(t))
        #expect(back == t)
        // old files (no counter / layers) decode to nil
        let old = try JSONDecoder().decode(TextTemplateInstance.self, from: Data(#"{"templateID":"a","texts":[]}"#.utf8))
        #expect(old.layers == nil && old.showsLayer(7))
    }

    @Test func counterTextChangesOverTheClip() async throws {
        var p = TestProject(background: .black)
        let id = try p.addText("0") { $0.fontSize = 0.25; $0.color = .white; $0.counter = TextCounter(from: 0, to: 8888, easeOut: false, countFraction: 1) }
        p[id].duration = Time(2)
        let lit: (Bitmap) -> Int = { b in var n = 0; for y in stride(from: 0, to: b.height, by: 2) { for x in stride(from: 0, to: b.width, by: 2) where b.pixel(x, y).luma > 0.5 { n += 1 } }; return n }
        let start = lit(try await p.render(at: 0))
        let end = lit(try await p.render(at: 1.99))
        #expect(start > 20)
        #expect(end > start * 3)   // "0" → "8,888"-ish: many more lit pixels
        let desc = FrameEvaluator.evaluate(p.project, at: Time(1))
        guard case .layer(let l) = desc.items.last, case .text(let tc) = l.source else { Issue.record("no text layer"); return }
        // the count spans the clip up to its last frame (OB-01): 1 s of (2 s − 1 frame)
        let k = TextCounter(from: 0, to: 8888, easeOut: false, countFraction: 1)
        let fd = p.project.settings.frameRate.frameDuration
        #expect(tc.string == k.string(at: Time(1), duration: Time(2), frameDuration: fd, language: "en")
                || tc.string == k.string(at: Time(1), duration: Time(2), frameDuration: fd, language: "fr"))
        let lastFrame = FrameEvaluator.evaluate(p.project, at: Time(2) - fd)
        guard case .layer(let ll) = lastFrame.items.last, case .text(let ltc) = ll.source else { Issue.record("no text layer"); return }
        #expect(ltc.string == "8,888" || ltc.string == "8\u{202F}888")
    }

    /// OB-01: a 0 → 100 counter shows 100 on the clip's last frame (it stopped at 99: the last frame is one frame before
    /// the clip end, and values round toward the start).
    @Test func counterReachesTheEndValueOnTheLastFrame() {
        for fps in [FrameRate.fps24, .fps30, .fps60] {
            let fd = fps.frameDuration
            for ease in [true, false] {
                for fraction in [0.8, 1.0] {
                    let k = TextCounter(from: 0, to: 100, easeOut: ease, countFraction: fraction)
                    for dur in [Time(1), Time(4), Time(7.5)] {
                        let last = dur - fd
                        #expect(k.string(at: last, duration: dur, frameDuration: fd, language: "en") == "100",
                                "fps \(fps.fps) ease \(ease) fraction \(fraction) duration \(dur.seconds)")
                        #expect(k.string(at: .zero, duration: dur, frameDuration: fd, language: "en") == "0")
                    }
                    // one frame earlier is not yet the end value when counting over the whole clip
                    if fraction == 1, !ease {
                        let before = k.string(at: Time(4) - fd - fd, duration: Time(4), frameDuration: fd, language: "en")
                        #expect(["98", "99"].contains(before), "fps \(fps.fps): \(before)")
                    }
                }
            }
        }
        // countdowns land on their end value too
        let timer = TextCounter.defaults(.timer)
        #expect(timer.string(at: Time(10) - FrameRate.fps30.frameDuration, duration: Time(10),
                             frameDuration: FrameRate.fps30.frameDuration, language: "en") == "0:00")
    }

    @Test func separatedTemplatePartsRenderLikeTheTemplate() async throws {
        let d = Registries.textTemplates["montage.template.lowerThird"]!
        var p = TestProject(canvas: Size2(640, 360), background: .black)
        let c = Clip(content: .text(d.makeContent()), start: 0, duration: d.defaultDuration)
        try TimelineOps.insert(c, into: &p.project, target: .newTrack)
        let whole = try await p.render(at: 2)
        // separate: one clip per layer, each showing only its layer (shape → text → shape → text)
        var q = p
        for li in d.layers.indices {
            var part = c
            if li > 0 { part.id = ClipID() }
            guard case .text(var t) = part.content else { return }
            t.template?.layers = [li]
            part.content = .text(t)
            if li == 0 { q.project.timeline[clip: c.id] = part } else { try TimelineOps.insert(part, into: &q.project, target: .newTrack) }
        }
        let parts = try await q.render(at: 2)
        if let dir = ProcessInfo.processInfo.environment["MONTAGE_SNAPSHOT_DIR"] {
            whole.writePNG(URL(fileURLWithPath: dir).appendingPathComponent("template-whole.png"))
            parts.writePNG(URL(fileURLWithPath: dir).appendingPathComponent("template-parts.png"))
        }
        var diff = 0.0, lit = 0
        for y in stride(from: 0, to: whole.height, by: 3) {
            for x in stride(from: 0, to: whole.width, by: 3) {
                let a = whole.pixel(x, y), b = parts.pixel(x, y)
                diff += abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)
                if a.luma > 0.1 { lit += 1 }
            }
        }
        #expect(lit > 200)
        #expect(diff / Double(max(lit, 1)) < 0.15)
        // a single part shows only its own layer
        var single = p
        guard case .text(var t) = c.content else { return }
        t.template?.layers = [1]   // white name text only, no accent bar
        single.project.timeline[clip: c.id]!.content = .text(t)
        let img = try await single.render(at: 2)
        var accent = 0
        for y in stride(from: 0, to: img.height, by: 3) { for x in stride(from: 0, to: img.width, by: 3) {
            let px = img.pixel(x, y); if px.b > 0.6 && px.r < 0.5 { accent += 1 }
        } }
        #expect(accent == 0)
    }
}
