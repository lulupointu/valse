import Testing
import Foundation
import ValseCore
@testable import ValseEngine
import ValseTestSupport

/// BUG-CLIP-EDGE-CLICK: an audible click at a cut between two clips. Measured on the offline mixdown (the export path)
/// as the largest sample-to-sample jump.
@MainActor @Suite(.serialized) struct ClipEdgeClickTests {
    /// Largest |x[i] - x[i-1]| of channel `ch` and where (seconds from the start of `b`).
    static func maxJump(_ b: AudioBuffer, channel ch: Int = 0, from: Double = 0, to: Double? = nil) -> (jump: Float, at: Double) {
        let sr = b.sampleRate
        let endSec: Double = to ?? Double(b.frames) / sr
        let lo: Int = max(1, Int(from * sr)), hi: Int = min(b.frames, Int(endSec * sr))
        var best: (Float, Double) = (0, 0)
        guard lo < hi else { return best }
        for i in lo..<hi {
            let d = abs(b[ch, i] - b[ch, i - 1])
            if d > best.0 { best = (d, Double(i) / sr) }
        }
        return best
    }

    /// A 440 Hz clip that stops on a non-zero sample (split at 1.0003 s, the right half deleted, no fades): without the
    /// automatic edge ramp the mix steps from the sine's level to 0 in one sample (up to 0.3).
    @Test func clipEndOnANonZeroSampleHasNoStep() async throws {
        var p = TestProject(frameRate: .fps30)
        let id = try await p.addAudio(seconds: 3, hz: 440)
        let right = try TimelineOps.split(id, at: Time(1.00031), in: &p.project.timeline)
        try TimelineOps.delete([right], in: &p.project.timeline)
        let mix = try await p.mixdown(seconds: 2)
        let j = Self.maxJump(mix, from: 0.9, to: 1.1)
        print("CLICK clip end max jump", j.jump, "at", j.at)
        #expect(j.jump < 0.03)
    }

    /// The same at a clip START (left half deleted): the mix must not step from 0 to the sine's level.
    @Test func clipStartOnANonZeroSampleHasNoStep() async throws {
        var p = TestProject(frameRate: .fps30)
        let id = try await p.addAudio(seconds: 3, hz: 440)
        _ = try TimelineOps.split(id, at: Time(1.00031), in: &p.project.timeline)
        try TimelineOps.delete([id], in: &p.project.timeline)
        let mix = try await p.mixdown(seconds: 2)
        let j = Self.maxJump(mix, from: 0.9, to: 1.1)
        print("CLICK clip start max jump", j.jump, "at", j.at)
        #expect(j.jump < 0.03)
    }

    /// A plain split (two clips that continue each other) stays sample-identical: the edge ramps skip a seamless cut.
    @Test func seamlessSplitKeepsFullLevel() async throws {
        var p = TestProject(frameRate: .fps30)
        let id = try await p.addAudio(seconds: 3, hz: 440)
        _ = try TimelineOps.split(id, at: Time(1.00031), in: &p.project.timeline)
        let mix = try await p.mixdown(seconds: 2)
        let a = AudioTestSignals.amplitude(at: 440, in: mix, from: 0.99, to: 1.01)
        #expect(a > 0.28, "amplitude dips to \(a) at a seamless split")
        #expect(Self.maxJump(mix, from: 0.9, to: 1.1).jump < 0.03)
    }

    /// The owner's project (skipped when absent). Prints the biggest jumps around 56 s.
    @Test func ownerProject() async throws {
        let path = ProcessInfo.processInfo.environment["VALSE_CLICK_PROJECT"] ?? ""
        guard !path.isEmpty else { return }
        let p = try ProjectPackage.load(from: URL(fileURLWithPath: path))
        let from = 55.5, len = 2.5
        let mix = try await AudioMixdown.render(p, range: TimeRange(start: Time(from), duration: Time(len)))
        var jumps: [(Float, Double)] = []
        let sr = mix.sampleRate
        for ch in 0..<2 {
            for i in 1..<mix.frames { jumps.append((abs(mix[ch, i] - mix[ch, i - 1]), from + Double(i) / sr)) }
        }
        jumps.sort { $0.0 > $1.0 }
        for j in jumps.prefix(12) { print("CLICK owner jump", j.0, "at", j.1) }
        for edge in [56.394603, 56.573264, 56.614931, 56.506] {
            let j = Self.maxJump(mix, from: edge - from - 0.003, to: edge - from + 0.003)
            let base = Self.maxJump(mix, from: edge - from - 0.103, to: edge - from - 0.003)
            print("CLICK owner edge", edge, "jump", j.jump, "at", j.at + from, "preceding 100ms max", base.jump)
        }
        if let c = p.timeline.allClips.first(where: { abs($0.start.seconds - 56.573264) < 0.001 }),
           let a = p.media.first(where: { $0.id == c.mediaID }) {
            let s0 = c.sourceStart.seconds
            let src = try await AudioFileIO.read(a.url, range: TimeRange(start: Time(s0), duration: Time(2.0)))
            let j = Self.maxJump(src, from: 0.0, to: 1.9)
            print("CLICK source clip C max jump", j.jump, "at timeline", 56.573264 + j.at, "src frames", src.frames)
            let k = Self.maxJump(src, from: 0.5, to: 0.6)
            print("CLICK source jump 0.5-0.6 s into C", k.jump, "mix there", Self.maxJump(mix, from: 56.573264 + 0.5 - from, to: 56.573264 + 0.6 - from).jump)
        }
        var peak: Float = 0
        for i in 0..<mix.frames { peak = max(peak, abs(mix[0, i])) }
        print("CLICK owner peak", peak)
    }
}
