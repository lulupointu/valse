import Testing
import Foundation
@preconcurrency import AVFoundation
@testable import ValseAI
import ValseCore
import ValseEngine
import ValseTestSupport

/// Home ▸ Long video to shorts (AI-031) end to end: a ~1 min synthetic talking video (system TTS dialogue twice over a
/// moving-box video) → whisper transcript → highlights → 9:16 projects with reframe keyframes and captions.
/// Needs whisper.cpp + a whisper model (skipped otherwise).
@Suite(.serialized) struct LongToShortsTests {
    static func talkingVideo() async throws -> URL? {
        guard let conv = try await SpeakerDiarizationTests.conversation() else { return nil }
        let dir = FileManager.default.temporaryDirectory
        let video = dir.appendingPathComponent("valse-shorts-src-video.mp4")
        try await SyntheticMedia.writeVideo(to: video, size: CGSize(width: 320, height: 180), seconds: 80, fps: 10,
                                            pattern: .movingBox(RGBA(0.1, 0.1, 0.1), RGBA(0.9, 0.6, 0.2)))
        let comp = AVMutableComposition()
        let va = AVURLAsset(url: video), aa = AVURLAsset(url: conv.url)
        guard let vt = try await va.loadTracks(withMediaType: .video).first, let at = try await aa.loadTracks(withMediaType: .audio).first,
              let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        let vd = try await va.load(.duration), ad = try await aa.load(.duration)
        var t = CMTime.zero
        while (t + ad).seconds <= vd.seconds {
            try ca.insertTimeRange(CMTimeRange(start: .zero, duration: ad), of: at, at: t)
            t = t + ad
        }
        try cv.insertTimeRange(CMTimeRange(start: .zero, duration: t), of: vt, at: .zero)
        let out = dir.appendingPathComponent("valse-shorts-talk.mov")
        try? FileManager.default.removeItem(at: out)
        guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetMediumQuality) else { return nil }
        try await ex.export(to: out, as: .mov)
        return out
    }

    @Test func longTalkBecomesVerticalCaptionedShorts() async throws {
        guard WhisperRuntime.isAvailable else { print("skip: whisper not installed"); return }
        try await HeavyWorkGate.run {
            guard let url = try await Self.talkingVideo() else { print("skip: no two system voices"); return }
            let asset = try await MediaProbe.probe(url)
            #expect(ShortsPlanner.validate(asset) == nil, "duration \(asset.duration.seconds)")
            var o = LongToShorts.Options()
            o.useLLM = false
            o.duration = .auto
            let ps = try await LongToShorts.run(asset, options: o)
            #expect(!ps.isEmpty)
            for p in ps {
                #expect(p.settings.aspectPreset == "9:16")
                let c = try #require(p.timeline.mainTrack?.clips.first)
                #expect(ShortsDuration.auto.range.lowerBound - 0.5 <= c.duration.seconds && c.duration.seconds <= ShortsDuration.auto.range.upperBound + 0.5)
                #expect(!SpeechCaptions.captions(in: p.timeline).isEmpty)
                #expect(c.reframe != nil || c.keyframes[ParamKey.position.raw] != nil || c.transform.scale.x > 1)
                #expect(TimelineOps.validate(p.timeline).isEmpty)
            }
        }
    }
}
