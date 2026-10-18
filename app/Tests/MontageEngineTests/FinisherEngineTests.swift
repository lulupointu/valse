import Testing
import Foundation
@preconcurrency import AVFoundation
@testable import MontageCore
@testable import MontageEngine

/// Finisher rows: TL-032 / AU-023 scrub audio grains, AU-040 notification sounds, AU-024 device lists.
@Suite struct FinisherAudioTests {
    static func toneProject() async throws -> Project {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fin-scrub-tone.m4a")
        if !FileManager.default.fileExists(atPath: url.path) { try await SyntheticMedia.writeAudio(to: url, seconds: 3, hz: 440) }
        var p = Project()
        let (assets, _) = await MediaProbe.probeAll([url])
        p.media = assets
        try TimelineOps.insert(TimelineOps.makeClip(for: assets[0], at: .zero), into: &p)
        return p
    }

    @Test func scrubGrainDecodesAudibleClips() async throws {
        var p = try await Self.toneProject()
        let src = ScrubAudio.sources(in: p, at: Time(1))
        #expect(src.count == 1)
        #expect(abs(src[0].sourceTime.seconds - 1) < 0.001)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let buf = try #require(ScrubAudio.mix(src, format: fmt))
        #expect(buf.frameLength == AVAudioFrameCount(ScrubAudio.grain * 44_100))
        var peak: Float = 0
        for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(buf.floatChannelData![0][i])) }
        #expect(peak > 0.05)
        // muted / solo-silenced tracks and gaps give no grain
        let ti = p.timeline.tracks.firstIndex { !$0.clips.isEmpty }!
        p.timeline.tracks[ti].isMuted = true
        #expect(ScrubAudio.sources(in: p, at: Time(1)).isEmpty)
        p.timeline.tracks[ti].isMuted = false
        p.timeline.tracks.append(Track(kind: .audio))
        p.timeline.tracks[p.timeline.tracks.count - 1].isSolo = true
        #expect(ScrubAudio.sources(in: p, at: Time(1)).isEmpty)
        #expect(ScrubAudio.sources(in: try await Self.toneProject(), at: Time(10)).isEmpty)
    }

    @Test func notificationChimesAreValidWav() throws {
        for k in [NotificationSounds.Kind.success, .failure] {
            let d = try #require(NotificationSounds.wav(k))
            #expect(String(decoding: d.prefix(4), as: UTF8.self) == "RIFF")
            let p = try AVAudioPlayer(data: d)
            #expect(p.duration > 0.3 && p.duration < 0.6)
        }
    }

    @Test func deviceListsHaveUniqueUIDs() {
        let outs = AudioDevices.outputs()
        #expect(Set(outs.map(\.uid)).count == outs.count)
        #expect(AudioDevices.id(forUID: "no-such-device", in: outs) == nil)
        #expect(AudioDevices.id(forUID: nil, in: outs) == nil)
    }
}
