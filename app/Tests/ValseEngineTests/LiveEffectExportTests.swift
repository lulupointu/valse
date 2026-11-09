import Testing
import Foundation
import ValseCore
@testable import ValseEngine
import ValseTestSupport

/// BUG-ECHO-EXPORT-SILENT: export (AudioMixdown = the export audio path) of a clip whose live chain holds a time-based
/// effect (echo, chorus, reverb, tremolo) must sound like the same chain run offline on the source: same energy, same
/// timing (the burst and its echoes / tail where the offline render puts them). AVAssetReaderAudioMixOutput skips ahead
/// when the first tap callback is slow: a 2 s echo line cleared element by element on the first buffer made the
/// export of micEcho jump from 0 to 2.2 s (silent mix).
@Suite(.serialized) struct LiveEffectExportTests {
    /// A 20 ms noise burst at 0.5 s in 2 s of silence (deterministic).
    static func source(channels: Int) -> AudioBuffer {
        var rng = XorShift()
        var s = [Float](repeating: 0, count: 96000)
        for i in 24000..<24960 { s[i] = rng.next() * 0.4 }
        return AudioBuffer(Array(repeating: s, count: channels), sampleRate: 48000)
    }

    /// RMS envelope, 2 ms windows.
    static func envelope(_ x: [Float], window w: Int = 96) -> [Double] {
        stride(from: 0, to: x.count - w + 1, by: w).map { a in
            (x[a..<(a + w)].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(w)).squareRoot()
        }
    }

    static func energy(_ x: [Float]) -> Double { x.reduce(0.0) { $0 + Double($1) * Double($1) } }

    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let n = min(a.count, b.count)
        var ab = 0.0, aa = 0.0, bb = 0.0
        for i in 0..<n { ab += a[i] * b[i]; aa += a[i] * a[i]; bb += b[i] * b[i] }
        return aa > 0 && bb > 0 ? ab / (aa * bb).squareRoot() : 0
    }

    /// Voice effects whose live chains are time-based (echo / chorus / reverb / tremolo), alone or combined.
    static let voices = ["micEcho", "echo", "superReverb", "tremble", "underwater", "paAnnouncer", "studioMic"]

    @Test(arguments: voices, [1, 2])
    func exportMatchesOfflineChain(_ voice: String, _ channels: Int) async throws {
        let src = Self.source(channels: channels)
        var p = TestProject(frameRate: .fps30)
        let id = try await p.addAudio(src)
        let dry = try await AudioMixdown.render(p.project).channel(0)
        p[id].audio.voice = VoiceEffects.descriptor("valse.voice.\(voice)")!.makeEffect()
        let plan = ClipAudioPlan.make(p[id])
        #expect(plan.render.isIdentity, "\(voice): live-only effect expected")
        let wet = try await AudioMixdown.render(p.project).channel(0)

        // offline reference: the same chain on the source, in tap-sized blocks
        let ref = src.copy()
        LiveChain(plan.live, sampleRate: 48000).process(ref, chunk: 512)
        let refDry = src.channel(0), refWet = ref.channel(0)

        let tag = "\(voice) \(channels == 1 ? "mono" : "stereo")"
        #expect(Self.energy(dry) > 0, "\(tag): dry export silent")
        // energy: the export's wet / dry ratio is the offline chain's (the export's channel mapping cancels out)
        let ratio = 10 * log10(max(Self.energy(wet), 1e-12) / Self.energy(dry))
        let expected = 10 * log10(Self.energy(refWet) / Self.energy(refDry))
        #expect(abs(ratio - expected) < 1.5, "\(tag): wet/dry \(ratio) dB, offline \(expected) dB")
        // timing: the envelopes line up (burst, echoes, tails)
        let e = Self.envelope(wet), r = Self.envelope(refWet)
        let c = Self.correlation(e, r)
        #expect(c > 0.95, "\(tag): envelope correlation \(c)")
        let peak = e.indices.max { e[$0] < e[$1] } ?? -1, refPeak = r.indices.max { r[$0] < r[$1] } ?? -2
        #expect(abs(peak - refPeak) <= 1, "\(tag): loudest 2 ms at \(Double(peak) * 0.002) s, offline \(Double(refPeak) * 0.002) s")
    }

    /// Clip speed 2: the export is not silent and the micEcho repeat (0.16 s, applied at output rate) follows the burst.
    @Test(arguments: [1, 2])
    func echoAtSpeed2(_ channels: Int) async throws {
        var p = TestProject(frameRate: .fps30)
        let id = try await p.addAudio(Self.source(channels: channels))
        p[id].audio.voice = VoiceEffects.descriptor("valse.voice.micEcho")!.makeEffect()
        try TimelineOps.setSpeed(id, .constant(2), in: &p.project.timeline)
        let out = try await AudioMixdown.render(p.project).channel(0)
        let e = Self.envelope(out)
        let burst = try #require(e.indices.max { e[$0] < e[$1] })
        #expect(e[burst] > 0.01, "silent export at speed 2")
        #expect(abs(Double(burst) * 0.002 - 0.25) < 0.03, "burst at \(Double(burst) * 0.002) s (source 0.5 s at 2×)")
        let after = (burst + 40)..<min(e.count, burst + 150)   // 80…300 ms after the burst
        let echo = try #require(after.max { e[$0] < e[$1] })
        #expect(abs(Double(echo - burst) * 0.002 - 0.16) < 0.01, "echo \(Double(echo - burst) * 2) ms after the burst")
        #expect(e[echo] > e[burst] * 0.1, "echo level \(e[echo] / e[burst])")
    }
}
