@preconcurrency import AVFoundation
import Foundation
import Testing
@preconcurrency import Vision
import MontageCore
import MontageEngine
import MontageTestSupport

/// T1: the engine on iPhone-like media instead of synthetic test patterns (RealLikeMedia, scripts/make_fixtures.sh):
/// probe, player (playback engine), offline render / export, thumbnails, waveforms, beats — the paths where real
/// iPhone HEVC / HLG / portrait footage and speech broke while every testsrc-based test passed.
/// Owner footage can be added with `MONTAGE_REAL_FOOTAGE` (opt-in, see RealLikeMedia.ownerFootage).
@Suite(.serialized) struct RealLikeFootageTests {
    static let clip = RealLikeMedia.iPhoneHLGPortrait

    /// Mean code values of a normalized rect (x, y, w, h; top-left origin) of a ColorScience frame.
    static func region(_ f: ColorScience.Frame, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> (r: Double, g: Double, b: Double) {
        var s = (0.0, 0.0, 0.0), n = 0.0
        for yy in Int(y * Double(f.height))..<Int((y + h) * Double(f.height)) {
            for xx in Int(x * Double(f.width))..<Int((x + w) * Double(f.width)) {
                let i = (yy * f.width + xx) * 3
                s.0 += Double(f.rgb[i]); s.1 += Double(f.rgb[i + 1]); s.2 += Double(f.rgb[i + 2]); n += 1
            }
        }
        return (s.0 / n, s.1 / n, s.2 / n)
    }

    /// Upright portrait layout of the fixture: bright window top-left, skin-toned face centre, blue sweater bottom.
    static func expectUprightPortrait(_ window: (r: Double, g: Double, b: Double), face: (r: Double, g: Double, b: Double),
                                      sweater: (r: Double, g: Double, b: Double), wall: (r: Double, g: Double, b: Double),
                                      _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let luma = { (c: (r: Double, g: Double, b: Double)) in 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }
        #expect(luma(window) > luma(wall) + 0.2, "\(what): window \(window) not brighter than the wall \(wall)", sourceLocation: sourceLocation)
        #expect(face.r > face.g && face.g > face.b && face.r - face.b > 0.04, "\(what): face not skin-toned \(face)", sourceLocation: sourceLocation)
        #expect(face.r < 0.97, "\(what): face clipped \(face)", sourceLocation: sourceLocation)
        #expect(sweater.b > sweater.r + 0.05, "\(what): bottom not the blue sweater \(sweater) (rotated?)", sourceLocation: sourceLocation)
    }

    @Test func probeSeesAnIPhonePortraitHLGClip() async throws {
        let a = try await MediaProbe.probe(Self.clip)
        #expect(a.kind == .video && a.hasVideo && a.hasAudio)
        #expect(a.pixelSize == Size2(1080, 1920), "display size \(a.pixelSize)")   // coded 1920×1080 + 90° matrix
        #expect(a.sourceRotation == 90)
        #expect(a.transfer == .hlg && a.isHDR && a.isWideGamut && a.bitDepth == 10, "\(a.transferFunction ?? "-") \(a.colorPrimaries ?? "-") \(a.bitDepth ?? 0)")
        #expect(a.frameRate == .fps30)
        #expect(abs(a.duration.seconds - 4) < 0.1)
        #expect(a.techInfo?.audioSampleRate == 44100 && a.techInfo?.audioChannels == 2)
    }

    /// Player path (PlaybackEngine → AVPlayer → compositor → video output) in an SDR 9:16 project: the frame is upright,
    /// HDR tone-mapped (face neither clipped nor orange-black), and matches the offline render (export path).
    @Test(arguments: [ProjectColorSpace.sdr709, .hdrHLG]) func previewIsUprightAndToneMapped(space: ProjectColorSpace) async throws {
        let p = try await ColorSpaceLookTests.project(Self.clip, space: space)
        let f = try await ColorSpaceLookTests.previewFrame(p, at: 1)
        Self.expectUprightPortrait(Self.region(f, 0.06, 0.08, 0.25, 0.25), face: Self.region(f, 0.4, 0.5, 0.2, 0.06),
                                   sweater: Self.region(f, 0.3, 0.85, 0.4, 0.1), wall: Self.region(f, 0.7, 0.15, 0.25, 0.15), "preview \(space)")
        let e = try await ColorSpaceLookTests.exportFrame(p, at: 1)
        Self.expectUprightPortrait(Self.region(e, 0.06, 0.08, 0.25, 0.25), face: Self.region(e, 0.4, 0.5, 0.2, 0.06),
                                   sweater: Self.region(e, 0.3, 0.85, 0.4, 0.1), wall: Self.region(e, 0.7, 0.15, 0.25, 0.15), "export \(space)")
        let d = ColorScience.compare(f, e, space: space, gx: 9, gy: 16)
        #expect(d.mean < 1.5, "preview vs export \(d)")
    }

    /// A Vision face detector (what face mosaic / camera tracking / auto colour use) finds the face in the UPRIGHT
    /// rendered frame — guards both the fixture and the orientation handling.
    @Test func faceIsDetectedInTheRenderedFrame() async throws {
        var p = TestProject(canvas: Size2(540, 960))
        try await p.addMedia(Self.clip)
        let img = try await OfflineRenderer.renderFrame(p.project, at: Time(1), size: nil)
        let req = VNDetectFaceRectanglesRequest()
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async { do { try VNImageRequestHandler(cgImage: img).perform([req]); k.resume() } catch { k.resume(throwing: error) } }
        }
        let faces = req.results ?? []
        #expect(faces.count == 1, "\(faces.map(\.boundingBox))")
        if let b = faces.first?.boundingBox {   // Vision: bottom-left origin; the face is centred, upper half
            #expect(abs(b.midX - 0.5) < 0.1 && b.midY > 0.45 && b.midY < 0.75, "\(b)")
        }
    }

    /// Timeline / media-bin thumbnails of portrait footage are portrait and upright.
    @Test func thumbnailIsUprightPortrait() async throws {
        let a = try await MediaProbe.probe(Self.clip)
        let img = try #require(await ThumbnailCache.shared.thumbnail(a, at: Time(1), height: 192))
        #expect(img.height > img.width, "\(img.width)×\(img.height)")
        let bmp = Bitmap(img)
        let sweater = bmp.average(x: 0.3, y: 0.85, w: 0.4, h: 0.1), window = bmp.average(x: 0.06, y: 0.08, w: 0.25, h: 0.25)
        #expect(sweater.b > sweater.r + 0.05, "bottom \(sweater)")
        #expect(window.luma > 0.6, "top-left window \(window)")
    }

    /// Concurrent requests for the same thumbnail all get it (a caller arriving while it was being made used to get nil,
    /// and a media card that got nil kept its placeholder for good: a card rebuilt mid-request, e.g. a language switch).
    @Test func concurrentRequestsForOneThumbnailAllGetIt() async throws {
        let a = try await MediaProbe.probe(Self.clip)
        let t = Time(2.6)   // a time no other test asks for (not cached in memory yet)
        let got = await withTaskGroup(of: Bool.self) { g in
            for _ in 0..<4 { g.addTask { await ThumbnailCache.shared.thumbnail(a, at: t, height: 77) != nil } }
            return await g.reduce(into: [Bool]()) { $0.append($1) }
        }
        #expect(got == [true, true, true, true], "\(got)")
    }

    /// Speech waveform: loud words, a real pause (~3.4 – 4.5 s) close to silence.
    @Test func speechWaveformShowsThePause() async throws {
        let w = try await WaveformCache.compute(RealLikeMedia.speech)
        let speech = w.peak(from: 0.5, to: 3.0), pause = w.peak(from: 3.6, to: 4.4), after = w.peak(from: 4.8, to: 8.5)
        #expect(speech > 0.2 && after > 0.2, "speech peaks \(speech) \(after)")
        #expect(pause < 0.05 * speech, "pause peak \(pause) vs speech \(speech)")
        // the clip's own audio (speech then room tone) also decodes: AAC 44.1 kHz from a QuickTime HEVC file
        let v = try await WaveformCache.compute(Self.clip)
        #expect(v.peak(from: 0.5, to: 3.0) > 0.2 && v.peak(from: 3.6, to: 3.95) < 0.05)
    }

    /// Music: 120 BPM, beats on the kicks (multiples of 0.5 s).
    @Test func musicBeatsAre120BPM() async throws {
        let r = try await AudioAnalysis.beats(url: RealLikeMedia.music)
        #expect(abs(r.bpm - 120) < 3, "bpm \(r.bpm)")
        let inner = r.beats.filter { $0 > 1 && $0 < 7 }
        #expect(inner.count >= 10, "\(r.beats)")
        #expect(inner.allSatisfy { abs($0.remainder(dividingBy: 0.5)) < 0.04 }, "\(inner)")
    }

    /// Opt-in owner footage (MONTAGE_REAL_FOOTAGE): the same upright / tone-map invariants hold on every clip given.
    @Test func ownerFootageProbesAndPlays() async throws {
        for (url, t) in RealLikeMedia.ownerFootage {
            let a = try await MediaProbe.probe(url)
            #expect(a.pixelSize.width > 0 && a.pixelSize.height > 0)
            let p = try await ColorSpaceLookTests.project(url, space: .sdr709)
            let f = try await ColorSpaceLookTests.previewFrame(p, at: t)
            let c = Self.region(f, 0, 0, 1, 1)
            #expect(c.r < 0.95 && c.g < 0.95 && c.b < 0.95 && c.r + c.g + c.b > 0.05, "\(url.lastPathComponent) mean \(c)")
        }
    }
}
