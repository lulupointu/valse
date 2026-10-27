@preconcurrency import AVFoundation
import Testing
import ValseCore
@testable import ValseEngine
import ValseTestSupport

/// PB-DROP: preview clip volumes are applied by the lane taps, not by audio-mix ramps (AVPlayer's mixer drops some ramp
/// events when the output device runs at another sample rate: lanes went silent at cuts on the built-in speakers).
@Suite struct LaneGainTests {
    /// Runs `frames` frames of 1.0 through `p` at composition time `t` (nil = no timestamp), played at `rate`; returns
    /// channel 0.
    static func run(_ p: LaneProcessor, at t: Double?, frames: Int, rate: Double = 1) -> [Float] {
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { for b in list { b.mData?.deallocate() }; free(list.unsafeMutablePointer) }
        for c in 0..<2 {
            let d = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            d.initialize(repeating: 1, count: frames)
            // (field by field: ValseEngine's own `AudioBuffer` shadows CoreAudio's)
            list[c].mNumberChannels = 1
            list[c].mDataByteSize = UInt32(frames * 4)
            list[c].mData = UnsafeMutableRawPointer(d)
        }
        p.process(list, frames: frames, time: t.map { CMTime(seconds: $0, preferredTimescale: 48000) } ?? .invalid,
                  duration: CMTime(seconds: Double(frames) / 48000 * rate, preferredTimescale: 48000))
        let out = list[0].mData!.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: out, count: frames))
    }

    @Test func tapAppliesTheRampsAndSilenceOutsideThem() {
        let ramps = [GainRamp(start: Time(0.5), end: Time(1), from: 2, to: 2),
                     GainRamp(start: Time(1), end: Time(2), from: 0, to: 1)]
        let p = LaneProcessor(clips: [], state: AudioMixState(), gains: ramps)
        p.prepare(sampleRate: 48000, channels: 2, maxFrames: 4800)
        // 0.45 → 0.55 s: silence before the first clip, then its gain
        let a = Self.run(p, at: 0.45, frames: 4800)
        #expect(a[100] == 0)
        #expect(a[2400 + 10] == 2)
        // across the cut at 1 s: the second clip's fade-in starts from 0
        let b = Self.run(p, at: 0.95, frames: 4800)
        #expect(b[100] == 2)
        #expect(abs(b[2400 + 480] - 0.01) < 0.002)
        // no timestamp: keeps the gain the last buffer ended with (≈ 0.05 at 1.05 s)
        let c = Self.run(p, at: nil, frames: 480)
        #expect(abs(c[0] - 0.05) < 0.002 && c[0] == c[479])
        // forward jump (seek): mid fade, then past the end of every ramp
        #expect(abs(Self.run(p, at: 1.5, frames: 480)[0] - 0.5) < 0.002)
        #expect(Self.run(p, at: 2.5, frames: 480).allSatisfy { $0 == 0 })
        // backwards (seek) past an earlier ramp: the first clip's gain again
        #expect(Self.run(p, at: 0.6, frames: 480)[10] == 2)
    }

    /// At 2× (J/K/L), a post-effects tap buffer covers twice its frame count of composition time: a cut inside it lands
    /// at half the frames.
    @Test func rateTwoBufferCoversTwiceTheTime() {
        let ramps = [GainRamp(start: Time(0), end: Time(1), from: 1, to: 1), GainRamp(start: Time(1), end: Time(2), from: 0.5, to: 0.5)]
        let p = LaneProcessor(clips: [], state: AudioMixState(), gains: ramps)
        p.prepare(sampleRate: 48000, channels: 2, maxFrames: 4800)
        // 0.95 → 1.05 s in 2400 frames: the cut at 1 s is frame 1200
        let a = Self.run(p, at: 0.95, frames: 2400, rate: 2)
        #expect(a[1190] == 1)
        #expect(a[1210] == 0.5)
    }

    @Test func volumesAreInTheTapsNotInTheMix() async throws {
        var p = TestProject()
        let id = try await p.addAudio(seconds: 1)
        p[id].audio.volume = 0.5
        p[id].audio.fadeIn = Time(0.2)
        /// Mix volume of each input mid-clip (nil = no volume set there).
        func mixVolumes(_ built: BuiltComposition) -> [Float?] {
            (built.audioMix?.inputParameters ?? []).map { prm in
                var a: Float = 0, b: Float = 0
                var r = CMTimeRange()
                guard prm.getVolumeRamp(for: CMTime(seconds: 0.5, preferredTimescale: 600), startVolume: &a, endVolume: &b, timeRange: &r) else { return nil }
                return a == b ? a : -1
            }
        }
        for purpose in [RenderPurpose.preview, .export] {
            let built = try await CompositionBuilder.build(project: p.project, purpose: purpose)
            #expect(built.audioMix?.inputParameters.allSatisfy { $0.audioTapProcessor != nil } == true)
            // a constant 1 (the tap applies 0.5 + the fade)
            #expect(mixVolumes(built) == [1], "\(purpose)")
        }
        // taps off (frozen-clock recovery): the mix carries the volumes again
        let noTaps = try await CompositionBuilder.build(project: p.project, purpose: .preview, audioTaps: false)
        #expect(mixVolumes(noTaps) == [0.5])
    }

    /// Gains above 1 (project 1023: 2.69) are applied in full by the export mixdown (same taps as the preview).
    @Test func exportAppliesGainsAboveOne() async throws {
        var p = TestProject()
        let id = try await p.addAudio(seconds: 1, hz: 440)
        p[id].audio.volume = 2.5
        let mix = try await p.mixdown(seconds: 1)
        let a = AudioTestSignals.amplitude(at: 440, in: mix, from: 0.3, to: 0.7)
        #expect(abs(a / 0.3 - 2.5) < 0.1, "amplitude \(a)")
    }

    /// The preview mixdown (through the taps) keeps the clip volume.
    @Test func previewGainMatchesTheClipVolume() {
        var c = Clip(content: .solid(RGBA(1, 1, 1)), start: Time(1), duration: Time(2))
        c.audio.volume = 0.25
        let (ramps, end) = CompositionBuilder.volumeRamps(c)
        #expect(end == Time(3))
        let p = LaneProcessor(clips: [c], state: AudioMixState(), gains: ramps)
        p.prepare(sampleRate: 48000, channels: 2, maxFrames: 480)
        #expect(abs(Self.run(p, at: 2, frames: 480)[10] - 0.25) < 1e-4)
        #expect(Self.run(p, at: 3.2, frames: 480)[10] == 0)
    }
}
