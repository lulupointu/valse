import Testing
import Foundation
@preconcurrency import AVFoundation
@testable import MontageCore
@testable import MontageEngine
import MontageTestSupport

/// SP-009 frame-rate up-conversion, SP-010 time-lapse speeds.
@Suite struct FinisherSpeedRenderTests {
    @Test func smoothPlaybackInterpolatesBelowProjectRate() async throws {
        var p = TestProject()
        let id = try await p.addVideo(.alternate(.black, .white), seconds: 1)   // 30 fps source
        p.project.settings.frameRate = .fps60
        #expect(FrameUpconversion.candidates(p.project) == [id])
        // t = 17/60 s → source frame 8.5 at 1× (black, next white)
        let t = 17.0 / 60
        #expect(TimeRemapTests.level(try await p.render(at: t)) < 10)
        p[id].smoothSlowMo = .frameBlending
        let v = TimeRemapTests.level(try await p.render(at: t))
        #expect(abs(v - 127.5) < 14, "v \(v)")
        // same rate as the project: nothing to interpolate, nothing changes
        p.project.settings.frameRate = .fps30
        #expect(FrameUpconversion.candidates(p.project).isEmpty)
        #expect(!FrameUpconversion.needsInterpolation(rate: 1, sourceRate: .fps30, projectRate: .fps30))
        #expect(FrameUpconversion.needsInterpolation(rate: 0.5, sourceRate: .fps60, projectRate: .fps30))
    }

    @Test func timeLapseSpeedsShowTheRightFrames() async throws {
        var p = TestProject()
        let id = try await p.addVideo(.frameIndex, seconds: 10)
        try TimelineOps.setSpeed(id, .constant(50), in: &p.project.timeline)
        #expect(abs(p[id].duration.seconds - 0.2) < 0.001)
        // output 0.1 s → source 5 s = frame 150
        let v = TimeRemapTests.level(try await p.render(at: 0.1))
        #expect(abs(v - TimeRemapTests.expectedLevel(frame: 150)) < 3, "v \(v)")
        try TimelineOps.setSpeed(id, .constant(100), in: &p.project.timeline)
        #expect(abs(p[id].duration.seconds - 0.1) < 0.001)
    }
}

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
