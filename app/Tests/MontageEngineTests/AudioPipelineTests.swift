import Testing
@preconcurrency import AVFoundation
import Foundation
import MontageCore
@testable import MontageEngine
import MontageTestSupport

/// End-to-end audio: project → composition (export path) → mixdown; numerical asserts on the result.
@Suite(.serialized) struct AudioPipelineTests {
    typealias S = AudioTestSignals

    @Test func volumeAndFades() async throws {
        var p = TestProject()
        let id = try await p.addAudio(seconds: 2, hz: 440)
        p[id].audio.volume = 0.5
        p[id].audio.fadeIn = Time(0.5)
        let m = try await p.mixdown()
        #expect(abs(m.frames - 96000) < 100)
        let full = 0.3 / sqrt(2.0)
        #expect(abs(dB(m.rms(seconds: 1.0, 1.9) / (full * 0.5))) < 0.5, "level \(m.rms(seconds: 1, 1.9))")
        #expect(m.rms(seconds: 0, 0.1) < m.rms(seconds: 0.35, 0.45) * 0.5)   // fading in
    }

    @Test func keyframedVolume() async throws {
        var p = TestProject()
        let id = try await p.addAudio(seconds: 2, hz: 440)
        p[id].audio.volume = 0
        p[id].toggleKeyframe(.volume, at: .zero, tolerance: Time(0.01))
        p[id].setValue(.volume, .scalar(1), at: Time(2))
        let m = try await p.mixdown()
        let a = m.rms(seconds: 0.4, 0.6), b = m.rms(seconds: 1.4, 1.6)
        #expect(abs(b / a - 3) < 0.4, "ramp ratio \(b / a)")
    }

    @Test func liveEQIsApplied() async throws {
        var p = TestProject()
        let id = try await p.addAudio(seconds: 1, hz: 1000)
        var eq = AudioEQ(); eq.gains[5] = -12
        p[id].audio.eq = eq
        let m = try await p.mixdown()
        let g = dB(S.amplitude(at: 1000, in: m, from: 0.3, to: 0.9) / 0.3)
        #expect(abs(g + 12) < 1.5, "EQ gain \(g)")
    }

    @Test func liveChainFollowsClipsOnALane() async throws {
        var p = TestProject()
        let a = try await p.addAudio(seconds: 1, hz: 1000)
        let lane = p.project.timeline.tracks.first { $0.kind == .audio }!.id
        let b = try await p.addAudio(seconds: 1, hz: 1000, at: Time(1), target: .track(lane))
        #expect(p.project.timeline.locate(a)?.track == p.project.timeline.locate(b)?.track)
        var eq = AudioEQ(); eq.gains[5] = -12
        p[b].audio.eq = eq
        let m = try await p.mixdown()
        let g1 = dB(S.amplitude(at: 1000, in: m, from: 0.2, to: 0.8) / 0.3), g2 = dB(S.amplitude(at: 1000, in: m, from: 1.2, to: 1.8) / 0.3)
        #expect(abs(g1) < 1, "first clip \(g1)")
        #expect(abs(g2 + 12) < 1.5, "second clip \(g2)")
    }

    @Test func voiceChangerPitchIsRenderedForExport() async throws {
        var p = TestProject()
        let id = try await p.addAudio(seconds: 1.5, hz: 440)
        p[id].audio.voice = VoiceEffects.descriptor("montage.voice.chipmunk")!.makeEffect()
        let m = try await p.mixdown()
        #expect(abs(m.frames - 72000) < 100)
        let f = S.dominantFrequency(m, lo: 300, hi: 1200, from: 0.4, to: 1.1)
        #expect(abs(f - 440 * pow(2, 9.0 / 12)) < 8, "chipmunk \(f) Hz")
    }

    @Test func changePitchIndependentOfSpeed() async throws {
        var p = TestProject()
        let id = try await p.addAudio(seconds: 2, hz: 440)
        p[id].audio.pitch = 12
        try TimelineOps.setSpeed(id, .constant(2), in: &p.project.timeline)
        let m = try await p.mixdown()
        #expect(abs(Double(m.frames) / 48000 - 1) < 0.02)
        let f = S.dominantFrequency(m, lo: 300, hi: 1500, from: 0.2, to: 0.8)
        #expect(abs(f - 880) < 10, "pitch +12 at 2× → \(f)")
    }

    @Test(arguments: [true, false]) func speedKeepsOrChangesPitch(_ keep: Bool) async throws {
        do {
            var p = TestProject()
            let id = try await p.addAudio(seconds: 2, hz: 440)
            try TimelineOps.setSpeed(id, .constant(2), in: &p.project.timeline)
            p[id].audio.preservePitch = keep
            let m = try await p.mixdown()
            #expect(abs(Double(m.frames) / 48000 - 1) < 0.02, "duration \(Double(m.frames) / 48000)")
            let f = S.dominantFrequency(m, lo: 300, hi: 1200, from: 0.2, to: 0.8)
            #expect(abs(f - (keep ? 440 : 880)) < 8, "keep=\(keep) → \(f) Hz")
        }
    }

    @Test func speedCurveDurationAndPitch() async throws {
        var p = TestProject()
        let id = try await p.addAudio(seconds: 3, hz: 440)
        let curve = SpeedCurve(points: [SpeedPoint(0, 0.5), SpeedPoint(0.5, 2), SpeedPoint(1, 0.5)])
        try TimelineOps.setSpeed(id, .curve(curve), in: &p.project.timeline)
        let expected = 3 / curve.integral(to: 1)
        #expect(abs(p[id].duration.seconds - expected) < 0.01)
        let m = try await p.mixdown()
        #expect(abs(Double(m.frames) / 48000 - expected) < 0.03)
        #expect(abs(S.dominantFrequency(m, lo: 300, hi: 700, from: 0.5, to: expected - 0.5) - 440) < 10)
    }

    @Test func loudnessNormalization() async throws {
        var p = TestProject()
        let id = try await p.addAudio(seconds: 3, hz: 1000)
        let a = p.project.asset(p[id].mediaID!)!
        let measured = try await AudioAnalysis.loudness(url: a.url, range: p[id].sourceRange)
        p[id].audio.loudness = LoudnessNormalization(targetLUFS: -14, measuredLUFS: measured, measuredRange: p[id].sourceRange)
        let m = try await p.mixdown()
        let out = AudioAnalysis.loudness(m)
        #expect(abs(out - (-14)) < 0.6, "measured \(measured) → \(out)")
    }

    @Test func duckingLowersMusicUnderVoice() async throws {
        var p = TestProject()
        let music = try await p.addAudio(seconds: 3, hz: 440)
        p[music].audio.ducking = AudioDucking(amountDB: -12)
        let voice = AudioBuffer(seconds: 3, channels: 2) { _, t in t >= 1 && t < 2 ? Float(0.3 * sin(2 * .pi * 1000 * t)) : 0 }
        _ = try await p.addAudio(voice, target: .newTrack)
        let m = try await p.mixdown()
        let before = S.amplitude(at: 440, in: m, from: 0.2, to: 0.8), during = S.amplitude(at: 440, in: m, from: 1.3, to: 1.8)
        let after = S.amplitude(at: 440, in: m, from: 2.6, to: 2.95)
        #expect(abs(dB(during / before) + 12) < 1.5, "ducked by \(dB(during / before))")
        #expect(abs(dB(after / before)) < 1.5)
    }

    @Test func noiseReductionThroughPipeline() async throws {
        var p = TestProject()
        let x = S.mix(S.noise(seconds: 2, amplitude: 0.03), AudioBuffer(seconds: 2, channels: 2) { _, t in t > 1 ? Float(0.3 * sin(2 * .pi * 700 * t)) : 0 })
        let id = try await p.addAudio(x)
        p[id].audio.noiseReduction = 1
        let m = try await p.mixdown()
        #expect(dB(m.rms(seconds: 0.4, 0.9) / x.rms(seconds: 0.4, 0.9)) < -12)
        #expect(abs(dB(S.amplitude(at: 700, in: m, from: 1.3, to: 1.9) / 0.3)) < 2)
        // rendered once, cached
        let spec = ClipAudioPlan.make(p[id]).render
        #expect(AudioRenderCache.shared.readyURL(for: p.project.asset(p[id].mediaID!)!, spec: spec) != nil)
    }

    @Test func previewCompositionHasLaneTaps() async throws {
        var p = TestProject()
        try await p.addVideo(.solid(.red), seconds: 1, audioHz: 440)
        try await p.addAudio(seconds: 1)
        let built = try await CompositionBuilder.build(project: p.project, purpose: .preview)
        let params = built.audioMix?.inputParameters ?? []
        #expect(params.count == 2)
        #expect(params.allSatisfy { $0.audioTapProcessor != nil })
    }

    @Test func liveEditDoesNotChangeStructureKey() async throws {
        var p = TestProject()
        let id = try await p.addAudio(seconds: 1)
        let k0 = CompositionBuilder.structureKey(p.project) { MediaSourceChoice(video: $0.url, audio: $0.url) }
        var eq = AudioEQ(); eq.gains[3] = 6
        p[id].audio.eq = eq
        p[id].audio.channels = .mono
        let k1 = CompositionBuilder.structureKey(p.project) { MediaSourceChoice(video: $0.url, audio: $0.url) }
        #expect(k0 == k1)
        p[id].audio.volume = 0.5
        #expect(CompositionBuilder.structureKey(p.project) { MediaSourceChoice(video: $0.url, audio: $0.url) } != k1)
    }

    /// A/V sync: a white flash and an audio click at the same media time stay together through position + speed + export.
    @Test func avSyncSurvivesSpeedAndExport() async throws {
        let dir = TestMedia.directory
        let video = dir.appendingPathComponent("flash-30.mp4")
        if !FileManager.default.fileExists(atPath: video.path) {
            try await SyntheticMedia.writeVideo(to: video, size: CGSize(width: 160, height: 90), seconds: 3, fps: 30, codec: .h264, audioHz: nil) { f, _ in
                f >= 45 && f < 48 ? (255, 255, 255) : (0, 0, 0)    // flash at 1.5 s
            }
        }
        let click = AudioBuffer(seconds: 3, channels: 2) { _, t in t >= 1.5 && t < 1.53 ? Float(0.5 * sin(2 * .pi * 1000 * t)) : 0 }
        var p = TestProject(canvas: Size2(160, 90))
        let v = try await p.addMedia(video)
        let a = try await p.addAudio(click)
        p[a].linkedTo = v
        for id in [v, a] { try TimelineOps.setSpeed(id, .constant(1.5), in: &p.project.timeline) }
        // flash/click at media 1.5 s → timeline 1.0 s
        var s = ExportSettings(); s.resolution = .p480; s.frameRate = .fps30
        let r = try await p.export(settings: s)
        // video: first bright frame
        let asset = AVURLAsset(url: r.url)
        let reader = try AVAssetReader(asset: asset)
        let vt = try await asset.loadTracks(withMediaType: .video).first!
        let vo = AVAssetReaderTrackOutput(track: vt, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(vo)
        // blocking read loop: off the cooperative pool (montage-gotchas)
        let flash: Double? = try await OffPool.run { _ in
            reader.startReading()
            defer { reader.cancelReading() }
            while let sb = vo.copyNextSampleBuffer() {
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
                let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
                let mid = base + CVPixelBufferGetHeight(pb) / 2 * CVPixelBufferGetBytesPerRow(pb) + CVPixelBufferGetWidth(pb) / 2 * 4
                if mid[1] > 128 { return CMSampleBufferGetPresentationTimeStamp(sb).seconds }
            }
            return nil
        }
        let audio = try await AudioFileIO.read(r.url)
        let onset = S.onset(audio, threshold: 0.1)
        #expect(flash != nil && onset != nil)
        if let flash, let onset {
            #expect(abs(flash - 1.0) < 0.034, "flash at \(flash)")
            #expect(abs(onset - flash) < 0.034, "audio \(onset) vs video \(flash)")
        }
    }
}
