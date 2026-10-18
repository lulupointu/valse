import Foundation
import Testing
import MontageCore
import MontageEffects
import MontageEngine
import MontageTestSupport

/// W5 transition library: every registered transition renders A at 0 %, B at 100 %, something else at 50 %, and stays
/// within the real-time budget at 1080p. Plus a few full-pipeline (AVFoundation + compositor) checks.
@Suite(.serialized) struct TransitionRenderTests {
    static let w = 96, h = 54

    static func meanDiff(_ a: Bitmap, _ b: Bitmap) -> Double {
        var s = 0.0
        for i in stride(from: 0, to: a.pixels.count, by: 4) {
            for c in 0..<3 { s += abs(Double(a.pixels[i + c]) - Double(b.pixels[i + c])) }
        }
        return s / Double(a.width * a.height * 3) / 255
    }

    @Test func libraryIsLargeAndCategorised() {
        let all = BuiltinTransitions.all
        #expect(all.count >= 100)
        #expect(Set(all.map(\.groupKey)).count >= 10)
        #expect(Set(all.map(\.id)).count == all.count)
        // persisted ids from the foundation stay available
        for id in ["dissolve", "blackFade", "slideLeft", "wipeRight", "zoomIn", "circle"] {
            #expect(Registries.transitions["montage.transition.\(id)"] != nil)
        }
        #expect(all.contains { !$0.params.isEmpty })
    }

    @Test func everyTransitionCompiles() async throws {
        try await HeavyWorkGate.run {   // GPU-saturating loop: keep real-time probes (PlaybackTests) from starving
            _ = EffectPipelines.shared.validateAll()
            let failures = BuiltinTransitions.all.compactMap { d in EffectPipelines.shared.errors[d.id].map { "\(d.id): \($0.prefix(400))" } }
            #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
        }
    }

    @Test func endpointsMatchClipsAndMidpointDiffers() async throws {
        try await HeavyWorkGate.run {   // GPU-saturating loop: keep real-time probes (PlaybackTests) from starving
            let (ta, tb) = try #require(PresetPreviewRenderer.sampleTextures(width: Self.w, height: Self.h))
            let dissolve = try #require(Registries.transitions["montage.transition.dissolve"])
            let refA = Bitmap(try #require(PresetPreviewRenderer.transitionFrame(dissolve, from: ta, to: tb, progress: 0, width: Self.w, height: Self.h)))
            let refB = Bitmap(try #require(PresetPreviewRenderer.transitionFrame(dissolve, from: ta, to: tb, progress: 1, width: Self.w, height: Self.h)))
            #expect(Self.meanDiff(refA, refB) > 0.1)
            var problems: [String] = []
            for d in BuiltinTransitions.all {
                let frames = PresetPreviewRenderer.transitionFrames(d, from: ta, to: tb, progresses: [0, 0.5, 1], width: Self.w, height: Self.h)
                guard let f0 = frames[0], let f5 = frames[1], let f1 = frames[2] else { problems.append("\(d.id): no render"); continue }
                let b0 = Bitmap(f0), b5 = Bitmap(f5), b1 = Bitmap(f1)
                let d0 = Self.meanDiff(b0, refA), d1 = Self.meanDiff(b1, refB)
                let mA = Self.meanDiff(b5, refA), mB = Self.meanDiff(b5, refB)
                if d0 > 0.004 { problems.append("\(d.id): 0% differs from A by \(d0)") }
                if d1 > 0.004 { problems.append("\(d.id): 100% differs from B by \(d1)") }
                if mA < 0.02 || mB < 0.02 { problems.append("\(d.id): 50% too close to an endpoint (A \(mA), B \(mB))") }
            }
            #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
        }
    }

    @Test func parametersChangeTheResult() throws {
        let (ta, tb) = try #require(PresetPreviewRenderer.sampleTextures(width: Self.w, height: Self.h))
        let d = try #require(Registries.transitions["montage.transition.colorFade"])
        let red = Bitmap(try #require(PresetPreviewRenderer.transitionFrame(d, from: ta, to: tb, progress: 0.5, params: ["color": .color(RGBA(1, 0, 0))], width: Self.w, height: Self.h)))
        let blue = Bitmap(try #require(PresetPreviewRenderer.transitionFrame(d, from: ta, to: tb, progress: 0.5, params: ["color": .color(RGBA(0, 0, 1))], width: Self.w, height: Self.h)))
        #expect(red[0.5, 0.5].isClose(to: RGBA(1, 0, 0), tolerance: 0.02))
        #expect(blue[0.5, 0.5].isClose(to: RGBA(0, 0, 1), tolerance: 0.02))
    }

    /// Real time at 1080p: each transition pass well under a frame (M1 Pro numbers; the Air is ~2× slower).
    @Test func everyTransitionIsRealTimeAt1080p() async throws {
        try await HeavyWorkGate.run {   // GPU-saturating loop: keep real-time probes (PlaybackTests) from starving
            let (ta, tb) = try #require(PresetPreviewRenderer.sampleTextures(width: 1920, height: 1080))
            var slow: [String] = []
            for d in BuiltinTransitions.all {
                _ = PresetPreviewRenderer.transitionGPUTime(d, from: ta, to: tb, progress: 0.5, width: 1920, height: 1080, repeats: 1)
                guard let ms = PresetPreviewRenderer.transitionGPUTime(d, from: ta, to: tb, progress: 0.5, width: 1920, height: 1080) else { continue }
                if ms > 8 { slow.append("\(d.id): \(String(format: "%.2f", ms)) ms") }
            }
            #expect(slow.isEmpty, "\(slow.joined(separator: "\n"))")
        }
    }

    /// PiP (TR-004): a dissolve between two adjacent clips of an overlay track, over a main-track clip.
    @Test func overlayTrackTransitionRenders() async throws {
        var p = TestProject()
        try await p.addVideo(.solid(.green), seconds: 6)
        let a = try await p.addVideo(.solid(.red), seconds: 2, target: .newTrack)
        let tid = p.project.timeline.tracks[p.project.timeline.locate(a)!.track].id
        try await p.addVideo(.solid(.blue), seconds: 2, at: 2, target: .track(tid))
        try TimelineOps.setTransition(a, TransitionInstance(typeID: "montage.transition.dissolve", duration: 1), in: &p.project.timeline)
        #expect(TimelineOps.validate(p.project.timeline).isEmpty)
        #expect(try await p.render(at: 0.5)[0.5, 0.5].isClose(to: .red, tolerance: 0.1))
        #expect(try await p.render(at: 1.5)[0.5, 0.5].isClose(to: RGBA(0.5, 0, 0.5), tolerance: 0.12))
        #expect(try await p.render(at: 2.5)[0.5, 0.5].isClose(to: .blue, tolerance: 0.1))
        #expect(try await p.render(at: 3.5)[0.5, 0.5].isClose(to: .green, tolerance: 0.1))
    }

    /// Through the real composition/compositor: a sample of categories on two video clips.
    @Test func fullPipelineMidpointsAndEnds() async throws {
        for id in ["wipeLeft", "cubeLeft", "glitch", "heart", "pageCurl"] {
            var p = TestProject()
            let a = try await p.addVideo(.solid(.red))
            try await p.addVideo(.solid(.blue), at: 5)
            try TimelineOps.setTransition(a, Registries.transitions["montage.transition.\(id)"]!.makeInstance(), in: &p.project.timeline)
            let d = p[a].transitionOut!.duration.seconds
            let start = p.project.timeline.mainTrack!.clips[1].start.seconds
            let early = try await p.render(at: start + 0.01)
            let mid = try await p.render(at: start + d / 2)
            #expect(early.average(x: 0.4, y: 0.4, w: 0.2, h: 0.2).r > 0.7, "\(id) starts on A")
            let m = mid.average(x: 0, y: 0, w: 1, h: 1)
            #expect(m.r > 0.05 || m.b > 0.05, "\(id) mid frame not black")
            #expect(!(m.isClose(to: .red, tolerance: 0.05)) && !(m.isClose(to: .blue, tolerance: 0.05)), "\(id) mid is a mix")
            #expect(try await p.render(at: start + d + 0.05)[0.5, 0.5].isClose(to: .blue, tolerance: 0.1), "\(id) ends on B")
        }
    }
}
