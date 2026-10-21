@preconcurrency import AVFoundation
import Foundation
import Testing
import MontageCore
import MontageEffects
import MontageEngine
@testable import MontageAI
import MontageTestSupport

@Suite("EditPilot (AI-048)")
struct EditPilotTests {
    init() { EffectsResources.register(); AIResources.register() }

    // MARK: Rule-based planner (EN + FR)

    @Test func rulesEnglishMultiClause() {
        let a = PilotRules.plan("make it 9:16 and speed up the boring parts, then add a fade between clips")
        #expect(a.contains(.setAspect(ratio: "9:16", fill: true)))
        #expect(a.contains(.speedUpQuiet(factor: 2)))
        #expect(a.contains { if case .addTransitions(let id, _) = $0 { return id == "montage.transition.dissolve" }; return false })
        #expect(!a.contains { if case .fade = $0 { return true }; return false })
    }

    @Test func rulesFrench() {
        let a = PilotRules.plan("Coupe les silences de plus de 1,5 s et ajoute des sous-titres en français")
        #expect(a.contains(.removeSilences(minPause: 1.5)))
        #expect(a.contains(.addCaptions(language: nil, translateTo: "fr")))
        let b = PilotRules.plan("Passez la vidéo en vertical, accélérez les passages ennuyeux x3")
        #expect(b.contains(.setAspect(ratio: "9:16", fill: true)))
        #expect(b.contains(.speedUpQuiet(factor: 3)))
        let c = PilotRules.plan("Ajoutez le titre « Mon voyage » avec un fondu au début et à la fin")
        #expect(c.contains(.addTitle(text: "Mon voyage", seconds: 3)))
        #expect(c.contains(.fade(seconds: 1)))
    }

    @Test func rulesMiscellaneous() {
        #expect(PilotRules.plan("cut the silences").contains(.removeSilences(minPause: 0.8)))
        #expect(PilotRules.plan("remove the ums and uhs").contains(.removeFillers))
        #expect(PilotRules.plan("make it a 1 min video").contains(.fitDuration(seconds: 60)))
        #expect(PilotRules.plan("slow down the selected clip").contains(.setSpeed(factor: 0.5, scope: .selected)))
        #expect(PilotRules.plan("make it louder by 3 dB").contains(.volume(db: 3, scope: .all)))
        #expect(PilotRules.plan("baisse le volume").contains(.volume(db: -6, scope: .all)))
        #expect(PilotRules.plan("réduis le bruit et normalise le son").contains(.reduceNoise(scope: .all)))
        #expect(PilotRules.plan("make it square").contains(.setAspect(ratio: "1:1", fill: true)))
        #expect(PilotRules.plan("hello there").isEmpty)
        // all suggestions of the panel are understood in both languages
        let bw = PilotRules.plan("apply a black and white filter")
        #expect(bw.contains { if case .applyFilter = $0 { return true }; return false })
    }

    @Test func suggestionsAreUnderstoodInBothLanguages() {
        let keys = ["pilot.suggest.silences", "pilot.suggest.captions", "pilot.suggest.vertical", "pilot.suggest.fades",
                    "pilot.suggest.boring", "pilot.suggest.title"]
        for lang in ["en", "fr"] {
            let table = L10n.shared.strings(for: lang)
            for k in keys {
                let text = try! #require(table[k])
                #expect(!PilotRules.plan(text).isEmpty, "\(lang) \(k): \(text)")
            }
        }
    }

    // MARK: Model reply parsing

    @Test func parsesToolCallsAndValidates() throws {
        let reply = """
        Sure! ```json
        [{"tool": "set_aspect", "ratio": "9/16", "fill": true},
         {"tool": "remove_silences", "min_pause": "0,6"},
         {"tool": "add_transitions", "transition": "fade to black", "duration": 12},
         {"tool": "delete_everything"},
         {"tool": "set_speed", "factor": 50, "scope": "selected"},
         {"name": "add_captions", "arguments": {"language": null, "translate_to": "French"}}]
        ```
        """
        let a = try #require(PilotCallParser.parse(reply))
        #expect(a == [.setAspect(ratio: "9:16", fill: true), .removeSilences(minPause: 0.6),
                      .addTransitions(typeID: "montage.transition.blackFade", duration: 3),
                      .setSpeed(factor: 10, scope: .selected), .addCaptions(language: nil, translateTo: "fr")])
        #expect(PilotCallParser.parse("I can't do that.") == nil)
        #expect(PilotCallParser.parse("[]") == [])
    }

    @Test func catalogResolvesNamesInBothLanguages() {
        #expect(PilotCatalog.transitionID("Dissolve") == "montage.transition.dissolve")
        #expect(PilotCatalog.transitionID("fondu") == "montage.transition.dissolve")
        #expect(PilotCatalog.effectID("black and white", filter: true) != nil)
    }

    @Test func executionOrderIsCanonical() {
        let o = EditPilotExecutor.ordered([.addCaptions(language: nil, translateTo: nil), .setAspect(ratio: "9:16", fill: true), .removeSilences(minPause: 1)])
        #expect(o == [.removeSilences(minPause: 1), .setAspect(ratio: "9:16", fill: true), .addCaptions(language: nil, translateTo: nil)])
    }

    // MARK: Ops on projects

    func threeClips() async throws -> TestProject {
        var p = TestProject(canvas: Size2(1920, 1080))
        for c in [RGBA.red, .green, .blue] { try await p.addVideo(.movingBox(.white, c), seconds: 4, size: CGSize(width: 320, height: 180)) }
        return p
    }

    @Test func aspectFillTransitionsFadeTitle() async throws {
        var p = try await threeClips().project
        let ctx = PilotContext()
        #expect(try PilotOps.apply(.setAspect(ratio: "9:16", fill: true), to: &p, context: ctx) != nil)
        #expect(p.settings.canvasSize == Size2(1080, 1920))
        let main = p.timeline.mainTrack!.clips
        // 16:9 source in a 9:16 frame: cover = (1920/180) / (1080/320) = 3.16
        #expect(abs(main[0].transform.scale.x - (1920.0 / 180) / (1080.0 / 320)) < 0.01)
        #expect(try PilotOps.apply(.addTransitions(typeID: "montage.transition.dissolve", duration: 0.5), to: &p, context: ctx) != nil)
        #expect(p.timeline.mainTrack!.clips.dropLast().allSatisfy { $0.transitionOut?.typeID == "montage.transition.dissolve" })
        #expect(try PilotOps.apply(.fade(seconds: 1), to: &p, context: ctx) != nil)
        #expect(p.timeline.mainTrack!.clips.first!.animations.inAnim?.typeID == "montage.anim.in.fade")
        #expect(p.timeline.mainTrack!.clips.last!.animations.outAnim?.typeID == "montage.anim.out.fade")
        #expect(try PilotOps.apply(.addTitle(text: "Hello", seconds: 3), to: &p, context: ctx) != nil)
        #expect(p.timeline.allClips.contains { if case .text(let t) = $0.content { return t.string == "Hello" }; return false })
        #expect(TimelineOps.validate(p.timeline).isEmpty)
    }

    @Test func removeSilencesCutsTheSilentMediaRanges() async throws {
        var p = try await threeClips().project
        let first = p.timeline.mainTrack!.clips[0]
        // speech 0–1.5 s, silence 1.5–3 s, speech 3–4 s (50 ms steps)
        let levels: [Float] = (0..<80).map { i in (30..<60).contains(i) ? -70 : -18 }
        var ctx = PilotContext()
        ctx.activity[first.mediaID!] = ActivityProfile(levels: levels, motion: [])
        let before = p.timeline.duration.seconds
        let r = try PilotOps.apply(.removeSilences(minPause: 0.8), to: &p, context: ctx)
        #expect(r != nil)
        let cut = before - p.timeline.duration.seconds
        #expect(abs(cut - (1.5 - 0.24)) < 0.06)   // 1.5 s silence minus the 0.12 s breath kept on both sides
        #expect(p.timeline.mainTrack!.clips.count == 4)
        #expect(TimelineOps.validate(p.timeline).isEmpty)
    }

    @Test func speedUpQuietSpeedsOnlyTheBoringRun() async throws {
        var p = try await threeClips().project
        let first = p.timeline.mainTrack!.clips[0]
        let levels: [Float] = (0..<80).map { i in (20..<60).contains(i) ? -70 : -18 }   // quiet 1–3 s
        let motion: [Float] = (0..<16).map { i in (4..<12).contains(i) ? 0.001 : 0.08 }  // still 1–3 s
        var ctx = PilotContext()
        ctx.activity[first.mediaID!] = ActivityProfile(levels: levels, motion: motion)
        let before = p.timeline.duration.seconds
        _ = try PilotOps.apply(.speedUpQuiet(factor: 2), to: &p, context: ctx)
        let clips = p.timeline.mainTrack!.clips
        #expect(clips.count == 5)
        #expect(clips[1].speed == .constant(2))
        #expect(abs((before - p.timeline.duration.seconds) - 1.0) < 0.05)   // 2 s at 2× saves 1 s
        #expect(TimelineOps.validate(p.timeline).isEmpty)
    }

    @Test func fitDurationAndVolume() async throws {
        var p = try await threeClips().project
        _ = try PilotOps.apply(.fitDuration(seconds: 6), to: &p, context: PilotContext())
        #expect(abs(p.timeline.duration.seconds - 6) < 0.1)
        _ = try PilotOps.apply(.volume(db: -6, scope: .all), to: &p, context: PilotContext())
        // synthetic videos have no audio: nothing to change, no crash
        #expect(TimelineOps.validate(p.timeline).isEmpty)
    }

    @Test func executorRunsAPlanAndDiffs() async throws {
        let p = try await threeClips().project
        let ex = try await EditPilotExecutor.run([.addTransitions(typeID: "montage.transition.dissolve", duration: 0.5),
                                                  .setAspect(ratio: "1:1", fill: false)], project: p)
        #expect(ex.changed)
        #expect(ex.results.count == 2 && ex.results.allSatisfy(\.changed))
        let rows = PilotDiff.rows(ex.before, ex.after).map(\.key)
        #expect(rows.contains("pilot.diff.ratio") && rows.contains("pilot.diff.transitions") && rows.contains("pilot.diff.duration"))
    }

    // MARK: Activity analysis (real decode)

    @Test func analyzerFindsSilenceInAudio() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-gaps-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let sr = 16000.0
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        var f: AVAudioFile? = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let n = Int(sr * 5)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        for i in 0..<n {
            let t = Double(i) / sr
            let on = t < 2 || t >= 3.5
            buf.floatChannelData![0][i] = on ? Float(0.3 * sin(2 * .pi * 220 * t) * (0.6 + 0.4 * sin(2 * .pi * 3 * t))) : 0.0005 * Float(sin(Double(i)))
        }
        try f!.write(from: buf)
        f = nil   // closes the file (header written)
        let levels = try await ActivityAnalyzer.levels(url: url)
        let prof = ActivityProfile(levels: levels, motion: [])
        let s = prof.silences(minimum: 0.8)
        #expect(s.count == 1)
        if let r = s.first {
            #expect(abs(r.start.seconds - 2.12) < 0.08)
            #expect(abs(r.end.seconds - 3.38) < 0.08)
        }
    }
}

@Suite("Dictate (TX-034) and quit shutdown")
struct DictationAndShutdownTests {
    @Test func dictatedTextJoinsTheField() {
        #expect(DictationText.merge(base: "", dictated: " hello world") == "hello world")
        #expect(DictationText.merge(base: "Cut", dictated: "the silences") == "Cut the silences")
        #expect(DictationText.merge(base: "Cut ", dictated: "the silences") == "Cut the silences")
        #expect(DictationText.merge(base: "Line\n", dictated: "two") == "Line\ntwo")
        #expect(DictationText.merge(base: "keep", dictated: "  ") == "keep")
    }

    final class Flag: @unchecked Sendable {
        let lock = NSLock()
        private var v = false
        var value: Bool { lock.withLock { v } }
        func set() { lock.withLock { v = true } }
    }

    /// Quitting mid-job: shutdown cancels and waits until the job body has really returned (the LaMa-on-quit crash).
    @Test func shutdownWaitsForRunningJobsAndRefusesNewOnes() async {
        let q = JobQueue(maxConcurrent: 2)
        let started = Flag(), finished = Flag()
        let id = await q.enqueue(titleKey: "t") { _ in
            started.set()
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
            usleep(200_000)   // an uninterruptible inference step finishing
            finished.set()
        }
        while !started.value { try? await Task.sleep(nanoseconds: 5_000_000) }
        let ok = await q.shutdown(timeout: 30)   // hang bound: returns as soon as the job body has returned
        #expect(ok)
        #expect(finished.value)
        #expect(await q.wait(id) == .cancelled)
        let late = await q.enqueue(titleKey: "late") { _ in Issue.record("must not run after shutdown") }
        #expect(await q.wait(late) == .cancelled)
    }

    /// AI QA: the local model planned "Rends la vidéo carrée pour Instagram" as 9:16; the request's own ratio word wins.
    @Test func modelAspectIsReconciledWithTheRequest() {
        let llm: [PilotAction] = [.setAspect(ratio: "9:16", fill: true), .highlightKeywords]
        #expect(PilotRules.reconcile(llm, request: "Rends la vidéo carrée pour Instagram") == [.setAspect(ratio: "1:1", fill: true), .highlightKeywords])
        #expect(PilotRules.reconcile(llm, request: "Make it 16:9 for YouTube").first == .setAspect(ratio: "16:9", fill: true))
        #expect(PilotRules.reconcile(llm, request: "Une version pour Instagram") == llm, "no explicit ratio: the model decides")
    }
}
