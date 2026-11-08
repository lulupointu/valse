import Foundation
import Testing
import ValseCore
import ValseEffects
import ValseEngine
import ValseTestSupport

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
            #expect(Registries.transitions["valse.transition.\(id)"] != nil)
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
            let dissolve = try #require(Registries.transitions["valse.transition.dissolve"])
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
        let d = try #require(Registries.transitions["valse.transition.colorFade"])
        let red = Bitmap(try #require(PresetPreviewRenderer.transitionFrame(d, from: ta, to: tb, progress: 0.5, params: ["color": .color(RGBA(1, 0, 0))], width: Self.w, height: Self.h)))
        let blue = Bitmap(try #require(PresetPreviewRenderer.transitionFrame(d, from: ta, to: tb, progress: 0.5, params: ["color": .color(RGBA(0, 0, 1))], width: Self.w, height: Self.h)))
        #expect(red[0.5, 0.5].isClose(to: RGBA(1, 0, 0), tolerance: 0.02))
        #expect(blue[0.5, 0.5].isClose(to: RGBA(0, 0, 1), tolerance: 0.02))
    }

    /// TR-RETRO-REWIND (CapCut "Retro Rewind", 2 s): both clips turn grey, a white ◀◀ sits in the middle, the cut A → B
    /// is a hard switch at frame 30 of 60 (mid-pan, under the blur), and the render is deterministic per progress
    /// (preview = export). The pixel match against CapCut's export is measured offline (branch report).
    @Test func retroRewindMatchesCapCutStructure() throws {
        let w = 160, h = 90
        let (ta, tb) = try #require(PresetPreviewRenderer.sampleTextures(width: w, height: h))
        let d = try #require(Registries.transitions["valse.transition.retroRewind"])
        #expect(d.groupKey == "transition.group.glitch")
        #expect(d.params.isEmpty, "CapCut's version has no settings")
        #expect(d.defaultDuration == Time(2))
        let dissolve = try #require(Registries.transitions["valse.transition.dissolve"])
        func frame(_ t: Double, _ tr: TransitionDescriptor? = nil) throws -> Bitmap {
            Bitmap(try #require(PresetPreviewRenderer.transitionFrame(tr ?? d, from: ta, to: tb, progress: t, width: w, height: h)))
        }
        let a = try frame(0, dissolve), b = try frame(1, dissolve)
        // T = 0.5 s: full grey tone, ◀◀ at rest in the middle (inside the left triangle), corners grey and dark
        let hold = try frame(0.25)
        #expect(Self.meanDiff(hold, try frame(0.25)) == 0)
        #expect(Self.meanDiff(hold, a) > 0.05)
        let glyph = hold[0.455, 0.5]
        #expect(glyph.r > 0.9 && glyph.g > 0.9 && glyph.b > 0.9, "white ◀◀: \(glyph)")
        let corner = hold.average(x: 0.02, y: 0.7, w: 0.1, h: 0.25)
        #expect(abs(corner.r - corner.g) < 0.03 && abs(corner.g - corner.b) < 0.03, "grey tone: \(corner)")
        #expect(corner.luma < 0.5)
        // the switch to B happens mid-pan at frame 30: frames 28 / 29 are A at the same held pan, frame 30 is B
        let f28 = try frame(28.0 / 60), f29 = try frame(29.0 / 60), f30 = try frame(30.0 / 60)
        #expect(Self.meanDiff(f29, f30) > 0.03)
        #expect(Self.meanDiff(f28, f30) > Self.meanDiff(f28, f29))
        // the pan is a hold-key step: 27 and 28 show the same picture position (only the blur and dust change)
        #expect(Self.meanDiff(try frame(27.0 / 60), f28) < Self.meanDiff(f28, f30))
        // the midpoint is not a dissolve; near the end the picture is B again but the ◀◀ is gone
        #expect(Self.meanDiff(try frame(0.5), try frame(0.5, dissolve)) > 0.03)
        let late = try frame(0.985)
        #expect(Self.meanDiff(late, b) < 0.03)
        #expect(Self.meanDiff(late, a) > 0.05)
    }

    /// TR-RETRO-FF: Retro Rewind mirrored: at rest the ▶▶ is the left-right mirror of the ◀◀ (the glyph pixel mirrors),
    /// the picture still turns grey, and the cut A → B / end state match the rewind's.
    @Test func retroFastForwardMirrorsRewind() throws {
        let w = 160, h = 90
        let (ta, tb) = try #require(PresetPreviewRenderer.sampleTextures(width: w, height: h))
        let rw = try #require(Registries.transitions["valse.transition.retroRewind"])
        let ff = try #require(Registries.transitions["valse.transition.retroFastForward"])
        #expect(ff.groupKey == rw.groupKey && ff.defaultDuration == rw.defaultDuration && ff.params.isEmpty)
        func frame(_ d: TransitionDescriptor, _ t: Double) throws -> Bitmap {
            Bitmap(try #require(PresetPreviewRenderer.transitionFrame(d, from: ta, to: tb, progress: t, width: w, height: h)))
        }
        let hold = try frame(ff, 0.25)
        let glyph = hold[1 - 0.455, 0.5]
        #expect(glyph.r > 0.9 && glyph.g > 0.9 && glyph.b > 0.9, "white ▶▶: \(glyph)")
        let corner = hold.average(x: 0.02, y: 0.7, w: 0.1, h: 0.25)
        #expect(abs(corner.r - corner.g) < 0.03 && abs(corner.g - corner.b) < 0.03, "grey tone: \(corner)")
        #expect(Self.meanDiff(hold, try frame(rw, 0.25)) > 0.01, "not the rewind")
        #expect(Self.meanDiff(try frame(ff, 0.985), try frame(rw, 0.985)) < 0.03)
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
        try TimelineOps.setTransition(a, TransitionInstance(typeID: "valse.transition.dissolve", duration: 1), in: &p.project.timeline)
        #expect(TimelineOps.validate(p.project.timeline).isEmpty)
        // TR-MODEL-CAPCUT: nothing moved, window [1.5, 2.5] centred on the cut at 2
        #expect(try await p.render(at: 0.5)[0.5, 0.5].isClose(to: .red, tolerance: 0.1))
        #expect(try await p.render(at: 2)[0.5, 0.5].isClose(to: RGBA(0.5, 0, 0.5), tolerance: 0.12))
        #expect(try await p.render(at: 3)[0.5, 0.5].isClose(to: .blue, tolerance: 0.1))
        #expect(try await p.render(at: 4.5)[0.5, 0.5].isClose(to: .green, tolerance: 0.1))
    }

    // MARK: TR-MODEL-CAPCUT frame mapping (through the real composition: handles, duplicate frames, halves)

    /// Source frame of a `.frameIndex` picture (grey = frame · 4).
    static func frameIndex(_ c: RGBA) -> Int { Int((c.r * 255 / 4).rounded()) }

    /// Main track: A (`.frameIndex`, 3 s file, grey wraps every 64 frames) showing source `aSource`…+2 s, then B (solid
    /// red, 2 s); a 1 s wipe at the cut t = 2 (window [1.5, 2.5]). Returns the frame index A shows at `t` (the grey side
    /// of the wipe), nil when no grey is left.
    static func outgoingFrame(aSource: Double, overlap: Bool = true, at t: Double) async throws -> Int? {
        var p = TestProject()
        let a = try await p.addVideo(.frameIndex, seconds: 3)
        try await p.addVideo(.solid(.red), seconds: 2, at: 1000)
        let ti = try #require(p.project.timeline.mainTrackIndex)
        p.project.timeline.tracks[ti].clips[0].sourceStart = Time(aSource)
        p.project.timeline.tracks[ti].clips[0].duration = Time(2)
        TimelineOps.compactMain(&p.project.timeline)
        var tr = try #require(Registries.transitions["valse.transition.wipeLeft"]).makeInstance()
        tr.duration = Time(1)
        if !overlap { tr.isOverlap = false }
        try TimelineOps.setTransition(a, tr, in: &p.project.timeline)
        #expect(p.project.timeline.mainTrack!.clips[1].start == Time(2))
        #expect(p[a].transitionOut?.duration == Time(1))
        let img = try await p.render(at: t)
        for x in [0.04, 0.96] {
            let c = img[x, 0.5]
            if abs(c.r - c.g) < 0.06, abs(c.g - c.b) < 0.06 { return frameIndex(c) }   // grey = A, red = B
        }
        return nil
    }

    @Test func overlapPlaysTheOutgoingTailHandle() async throws {
        // A shows source 0.2…2.2 s; at t = 2.3 (past the cut) it plays its handle: source 2.5 s = frame 75 → grey of 11
        // (holding its last frame would show frame 65 → grey of 1)
        let f = try #require(try await Self.outgoingFrame(aSource: 0.2, at: 2.3))
        #expect(abs(f - 11) <= 1, "frame \(f)")
    }

    @Test func overlapWithoutHandleHoldsTheLastFrame() async throws {
        // A shows source 1…3 s (the file's end): past the cut it holds its last frame (89 → grey of 25)
        let f = try #require(try await Self.outgoingFrame(aSource: 1, at: 2.3))
        #expect(abs(f - 25) <= 1, "frame \(f)")
    }

    @Test func nonOverlapShowsOnlyTheIncomingClipAfterTheCut() async throws {
        // second half of a non-overlap wipe: B only on both shader inputs, no grey left anywhere
        #expect(try await Self.outgoingFrame(aSource: 0.2, overlap: false, at: 2.3) == nil)
        // first half: A only, and it is A's own frame at that instant (source 0.2 + 1.7 = frame 57)
        let f = try #require(try await Self.outgoingFrame(aSource: 0.2, overlap: false, at: 1.7))
        #expect(abs(f - 57) <= 1, "frame \(f)")
    }

    /// Through the real composition/compositor: a sample of categories on two video clips.
    @Test func fullPipelineMidpointsAndEnds() async throws {
        for id in ["wipeLeft", "cubeLeft", "glitch", "heart", "pageCurl"] {
            var p = TestProject()
            let a = try await p.addVideo(.solid(.red))
            try await p.addVideo(.solid(.blue), at: 5)
            try TimelineOps.setTransition(a, Registries.transitions["valse.transition.\(id)"]!.makeInstance(), in: &p.project.timeline)
            let d = p[a].transitionOut!.duration.seconds
            // TR-MODEL-CAPCUT: the window starts d/2 before the cut
            let start = p.project.timeline.mainTrack!.clips[1].start.seconds - d / 2
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
