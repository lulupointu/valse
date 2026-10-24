@preconcurrency import AVFoundation
import Testing
import MontageCore
@testable import MontageEngine
import MontageTestSupport

/// PB-DROP: preview clip volumes are applied by the lane taps, not by audio-mix ramps (AVPlayer's mixer drops some ramp
/// events when the output device runs at another sample rate: lanes went silent at cuts on the built-in speakers).
@Suite struct LaneGainTests {
    /// Runs `frames` frames of 1.0 through `p` at composition time `t` (nil = no timestamp); returns channel 0.
    static func run(_ p: LaneProcessor, at t: Double?, frames: Int) -> [Float] {
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { for b in list { b.mData?.deallocate() }; free(list.unsafeMutablePointer) }
        for c in 0..<2 {
            let d = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            d.initialize(repeating: 1, count: frames)
            // (field by field: MontageEngine's own `AudioBuffer` shadows CoreAudio's)
            list[c].mNumberChannels = 1
            list[c].mDataByteSize = UInt32(frames * 4)
            list[c].mData = UnsafeMutableRawPointer(d)
        }
        p.process(list, frames: frames, time: t.map { CMTime(seconds: $0, preferredTimescale: 48000) } ?? .invalid)
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
        // no timestamp: continues from where the last buffer ended (1.05 s)
        let c = Self.run(p, at: nil, frames: 480)
        #expect(abs(c[0] - 0.05) < 0.002)
        // backwards (seek): mid fade, then past the end of every ramp
        #expect(abs(Self.run(p, at: 1.5, frames: 480)[0] - 0.5) < 0.002)
        #expect(Self.run(p, at: 2.5, frames: 480).allSatisfy { $0 == 0 })
    }

    @Test func previewVolumesAreInTheTapsExportVolumesInTheMix() async throws {
        var p = TestProject()
        let id = try await p.addAudio(seconds: 1)
        p[id].audio.volume = 0.5
        p[id].audio.fadeIn = Time(0.2)
        func ramps(_ built: BuiltComposition) -> Int {
            var n = 0
            for prm in built.audioMix?.inputParameters ?? [] {
                var a: Float = 0, b: Float = 0
                var r = CMTimeRange()
                var cursor = CMTime.zero
                while prm.getVolumeRamp(for: cursor, startVolume: &a, endVolume: &b, timeRange: &r), r.duration > .zero, r.duration.isNumeric {
                    n += 1; cursor = r.end
                }
            }
            return n
        }
        let preview = try await CompositionBuilder.build(project: p.project, purpose: .preview)
        #expect(preview.audioMix?.inputParameters.allSatisfy { $0.audioTapProcessor != nil } == true)
        #expect(ramps(preview) == 0)
        let export = try await CompositionBuilder.build(project: p.project, purpose: .export)
        #expect(ramps(export) > 0)
        // taps off (frozen-clock recovery): the mix carries the volumes again
        let noTaps = try await CompositionBuilder.build(project: p.project, purpose: .preview, audioTaps: false)
        #expect(ramps(noTaps) > 0)
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
