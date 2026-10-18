import Testing
import Foundation
import AVFoundation
import MontageCore
import MontageEngine
import MontageTestSupport

/// Speed curves / reverse / freeze / smooth slow-mo through the real compositor (W6/W9).
/// `.frameIndex` media: grey level = (frame · 4) % 256, so one source frame = 4 levels.
@Suite(.serialized) struct TimeRemapTests {
    static func level(_ img: Bitmap) -> Double { img.average(x: 0.3, y: 0.3, w: 0.4, h: 0.4).r * 255 }
    static func expectedLevel(frame: Int) -> Double { Double((frame * 4) % 256) }

    @Test func speedCurveIsFrameAccurate() async throws {
        var p = TestProject()
        let id = try await p.addVideo(.frameIndex, seconds: 2)
        let curve = SpeedCurve(points: [SpeedPoint(0, 0.4), SpeedPoint(0.5, 3), SpeedPoint(1, 0.6)])
        try TimelineOps.setSpeed(id, .curve(curve), in: &p.project.timeline)
        let clip = p[id]
        let fd = FrameRate.fps30.frameDuration
        var worst = 0.0
        for k in stride(from: 1, to: Int(clip.duration / fd) - 1, by: 3) {
            let t = fd * Double(k)
            let s = clip.sourceTime(at: t)
            let frame = Int((s.seconds * 30 + 1e-6).rounded(.down))
            let got = Self.level(try await p.render(at: t.seconds))
            worst = max(worst, abs(got - Self.expectedLevel(frame: frame)))
        }
        // < half a source frame (2 levels) everywhere; the old 32-chord approximation was off by several frames
        #expect(worst < 2.0, "worst error \(worst) levels")
    }

    @Test func reversedClipPlaysBackwardsFrameExact() async throws {
        var p = TestProject()
        let id = try await p.addVideo(.frameIndex, seconds: 2)
        try TimelineOps.setReversed(id, true, in: &p.project.timeline)
        // render goes through the export path: the reversed render is produced (or reused) first
        for k in [0, 15, 40, 59] {
            let got = Self.level(try await p.render(at: Double(k) / 30))
            #expect(abs(got - Self.expectedLevel(frame: 59 - k)) < 2.0, "k=\(k) got \(got)")
        }
    }

    @Test func reversedTrimmedClipUsesMirroredInPoint() async throws {
        var p = TestProject()
        let id = try await p.addVideo(.frameIndex, seconds: 2)
        try TimelineOps.trim(id, edge: .head, to: 0.5, in: &p.project)     // source [0.5, 2.0)
        try TimelineOps.trim(id, edge: .tail, to: 1.0, in: &p.project)     // source [0.5, 1.5)
        try TimelineOps.setReversed(id, true, in: &p.project.timeline)
        // first frame shows the last source frame of the range (frame 44), then counts down
        #expect(abs(Self.level(try await p.render(at: 0)) - Self.expectedLevel(frame: 44)) < 2.0)
        #expect(abs(Self.level(try await p.render(at: 10.0 / 30)) - Self.expectedLevel(frame: 34)) < 2.0)
    }

    @Test func reversedAudioIsSampleReversed() async throws {
        let url = try await TestMedia.video(.solid(RGBA(0.5, 0.5, 0.5)), seconds: 1, audioHz: 330)
        let asset = try await MediaProbe.probe(url)
        let rev = try await ReverseManager.shared.ensure(asset)
        let a = try await AudioPCM.read(url), b = try await AudioPCM.read(rev)
        #expect(abs(a.count - b.count) < 48 * 2)
        // a window in the middle of the original matches the mirrored window of the reversed file
        let n = min(a.count, b.count) / 2
        var err = 0.0, ref = 0.0
        for i in (n - 2000)..<(n + 2000) {
            err += abs(Double(a[i]) - Double(b[b.count - 1 - i])); ref += abs(Double(a[i]))
        }
        #expect(err < ref * 0.05, "err \(err) ref \(ref)")
    }

    @Test func reverseMirrorsKeyframes() throws {
        var c = Clip(content: .media(MediaID()), start: 0, duration: 4)
        c.keyframes[ParamKey.opacity.raw] = KeyframeTrack([Keyframe(time: 1, value: .scalar(0)), Keyframe(time: 4, value: .scalar(1))])
        var tl = Timeline()
        tl.tracks[tl.mainTrackIndex!].clips = [c]
        try TimelineOps.setReversed(c.id, true, in: &tl)
        let k = tl.clip(c.id)!.keyframes[ParamKey.opacity.raw]!.keyframes
        #expect(k.map(\.time) == [Time(0), Time(3)])
    }

    @Test func freezeFrameInsertsStillAndRipples() async throws {
        var p = TestProject()
        let id = try await p.addVideo(.frameIndex, seconds: 2)
        let asset = p.project.media[0]
        let still = try await FrameGrabber.freezeStill(of: asset, at: p[id].sourceTime(at: 1.0),
                                                       into: TestMedia.directory.appendingPathComponent("freeze"), name: "Freeze")
        let fid = try TimelineOps.insertFreeze(of: id, at: 1.0, still: still, in: &p.project)
        #expect(TimelineOps.validate(p.project.timeline).isEmpty)
        #expect(p.project.duration == Time(5))
        #expect(p[fid].start == Time(1) && p[fid].duration == Time(3))
        #expect(p[fid].freezeOf?.sourceTime == Time(1))
        for t in [1.2, 3.9] {
            let lv = Self.level(try await p.render(at: t)); #expect(abs(lv - Self.expectedLevel(frame: 30)) < 2.0, "t=\(t) lv=\(lv)")
        }
        // the right half continues after the freeze
        #expect(abs(Self.level(try await p.render(at: 4.5)) - Self.expectedLevel(frame: 45)) < 2.0)
    }

    @Test func smoothSlowMoBlendsNeighbourFrames() async throws {
        var p = TestProject()
        let id = try await p.addVideo(.alternate(.black, .white), seconds: 1)
        try TimelineOps.setSpeed(id, .constant(0.25), in: &p.project.timeline)
        // t = 34/30 s → source 0.2833 s = frame 8.5 (black, next white)
        let t = 34.0 / 30
        let hard = Self.level(try await p.render(at: t))
        p[id].smoothSlowMo = .frameBlending
        let smooth = Self.level(try await p.render(at: t))
        #expect(hard < 10)
        #expect(abs(smooth - 127.5) < 12, "smooth \(smooth)")
        // weight follows the fractional position: frame 8.25 → 25 % white
        let q = Self.level(try await p.render(at: 33.0 / 30))
        #expect(abs(q - 0.25 * 255) < 12, "q \(q)")
    }

    @Test func motionBlurAccumulatesPreviousFrames() async throws {
        var p = TestProject()
        let id = try await p.addVideo(.alternate(.black, .white), seconds: 1)
        p[id].motionBlur = MotionBlur(amount: 1, samples: 2)
        let v = Self.level(try await p.render(at: 10.0 / 30))     // frame 10 black + frame 9 white
        #expect(abs(v - 127.5) < 12, "v \(v)")
    }
}

/// Decodes the first audio track to interleaved 16-bit stereo PCM (test helper).
enum AudioPCM {
    static func read(_ url: URL) async throws -> [Int16] {
        let asset = AVURLAsset(url: url)
        guard let t = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let r = try AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: t, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false])
        r.add(o)
        r.startReading()
        var out: [Int16] = []
        while let sb = o.copyNextSampleBuffer() {
            guard let b = CMSampleBufferGetDataBuffer(sb) else { continue }
            var tmp = [Int16](repeating: 0, count: CMBlockBufferGetDataLength(b) / 2)
            tmp.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(b, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            out += tmp
        }
        return out
    }
}
