import Testing
import Foundation
import CoreGraphics
@preconcurrency import AVFoundation
@testable import MontageAI
import MontageCore
import MontageEngine
import MontageTestSupport

/// Reduce image noise / Remove flickers / Enhance quality (CL-017/018/019, AI-021/022/023) on generated media.
@Suite(.serialized) struct VideoEnhanceTests {
    static let w = 320, h = 180, frames = 45

    /// Grey scene + per-frame noise (±24) + a walking white box; odd frames 25 % brighter when `flicker`.
    static func noisyVideo(flicker: Bool) async throws -> URL {
        let url = TestMedia.directory.appendingPathComponent("noisy-\(flicker ? "flicker" : "steady")-v1.mov")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
                                                                            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 20_000_000]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input)
        writer.startWriting(); writer.startSession(atSourceTime: .zero)
        var rng = SplitMix64(seed: 3)
        for f in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var pbOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pbOut)
            let pb = pbOut!
            CVPixelBufferLockBaseAddress(pb, [])
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRow(pb)
            let gain = flicker && f % 2 == 1 ? 1.25 : 1.0
            let bx = 20 + f * 5
            for y in 0..<h { for x in 0..<w {
                let inBox = x >= bx && x < bx + 40 && y >= 70 && y < 110
                let n = flicker ? 0 : Int(rng.next() % 49) - 24
                let v = UInt8(min(max(Double((inBox ? 230 : 110) + n) * gain, 0), 255))
                let p = base + y * bpr + x * 4
                p[0] = v; p[1] = v; p[2] = v; p[3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    /// Luma frames of a video (8-bit grey via image generator).
    static func lumaFrames(_ url: URL, count: Int) async throws -> [Bitmap] {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        var out: [Bitmap] = []
        for f in 0..<count { out.append(Bitmap(try await g.image(at: CMTime(value: CMTimeValue(f) , timescale: 30)).image)) }
        return out
    }

    /// Std-dev of luma in the static top band.
    static func noise(_ b: Bitmap) -> Double {
        var s = 0.0, s2 = 0.0, n = 0.0
        for y in stride(from: 5, to: b.height * 3 / 10, by: 1) { for x in stride(from: 5, to: b.width - 5, by: 1) {
            let v = b.pixel(x, y).luma; s += v; s2 += v * v; n += 1
        } }
        let m = s / n
        return (max(0, s2 / n - m * m)).squareRoot()
    }

    @Test func denoiseCutsStaticNoiseAndKeepsMotion() async throws {
        try await HeavyWorkGate.run {
            let url = try await Self.noisyVideo(flicker: false)
            let a = try await MediaProbe.probe(url)
            let e = VideoEnhancement(original: a.id, denoise: .normal)
            try? FileManager.default.removeItem(at: VideoEnhancer.outputURL(a, e))
            let out = try await VideoEnhancer.process(a, e)
            let before = try await Self.lumaFrames(url, count: 30), after = try await Self.lumaFrames(out, count: 30)
            let nb = before[20...].map(Self.noise).reduce(0, +) / 10, na = after[20...].map(Self.noise).reduce(0, +) / 10
            print("metric video_denoise_noise_before=\(nb) after=\(na)")
            #expect(na < nb * 0.6, "noise \(nb) → \(na)")
            // the box moved on: frame 25 has it at x = 145…185 (no ghost of frame 20 at x = 120…160 left edge)
            let f = after[25]
            #expect(f[165.0 / 320, 0.5].luma > 0.7, "box kept")
            #expect(f[125.0 / 320, 0.5].luma < 0.6, "no trail")
            let probe = try await MediaProbe.probe(out)
            #expect(abs(probe.duration.seconds - a.duration.seconds) < 0.05 && probe.pixelSize == a.pixelSize)
        }
    }

    /// AI QA (project 1018, iPhone HLG): the denoised / enhanced copy kept the HLG signal but lost its colour tags, so it
    /// was read back as BT.709 and looked grey and washed out. The output now carries the source's tags (HEVC Main10).
    @Test func enhancedCopyKeepsHLGColourTags() async throws {
        try await HeavyWorkGate.run {
            let url = TestMedia.directory.appendingPathComponent("enhance-hlg-src.mov")
            if !FileManager.default.fileExists(atPath: url.path) {
                let tmp = TestMedia.directory.appendingPathComponent("tmp-\(UUID().uuidString).mov")
                let (w, h) = (320, 180)
                let writer = try AVAssetWriter(outputURL: tmp, fileType: .mov)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h,
                    AVVideoColorPropertiesKey: ColorTags(.hdrHLG).properties,
                    AVVideoCompressionPropertiesKey: [AVVideoProfileLevelKey: "HEVC_Main10_AutoLevel"]])
                input.expectsMediaDataInRealTime = false
                let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                    kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
                writer.add(input)
                #expect(writer.startWriting()); writer.startSession(atSourceTime: .zero)
                for f in 0..<15 {
                    while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
                    var pbOut: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, ad.pixelBufferPool!, &pbOut)
                    let pb = try #require(pbOut)
                    CVPixelBufferLockBaseAddress(pb, [])
                    for (plane, v) in [(0, UInt16(600 << 6)), (1, UInt16(512 << 6))] {
                        let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane)!.assumingMemoryBound(to: UInt16.self)
                        let n = CVPixelBufferGetBytesPerRowOfPlane(pb, plane) / 2 * CVPixelBufferGetHeightOfPlane(pb, plane)
                        for i in 0..<n { base[i] = v }
                    }
                    CVPixelBufferUnlockBaseAddress(pb, [])
                    #expect(ad.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 30)))
                }
                input.markAsFinished(); await writer.finishWriting()
                try FileManager.default.moveItem(at: tmp, to: url)
            }
            let a = try await MediaProbe.probe(url)
            #expect(a.transfer == .hlg)
            let e = VideoEnhancement(original: a.id, denoise: .normal)
            try? FileManager.default.removeItem(at: VideoEnhancer.outputURL(a, e))
            let out = try await VideoEnhancer.process(a, e)
            let b = try await MediaProbe.probe(out)
            #expect(b.transfer == .hlg && b.isWideGamut, "enhanced copy tagged HLG / BT.2020")
            #expect((b.bitDepth ?? 0) >= 10)
        }
    }

    @Test func deflickerFlattensFrameBrightness() async throws {
        try await HeavyWorkGate.run {
            let url = try await Self.noisyVideo(flicker: true)
            let a = try await MediaProbe.probe(url)
            let e = VideoEnhancement(original: a.id, deflicker: .flashlight, deflickerLevel: .normal)
            try? FileManager.default.removeItem(at: VideoEnhancer.outputURL(a, e))
            let out = try await VideoEnhancer.process(a, e)
            func spread(_ fs: [Bitmap]) -> Double {
                let m = fs.map { $0.average(x: 0, y: 0, w: 1, h: 0.3).luma }
                return zip(m.dropFirst(), m).map { abs($0 - $1) }.reduce(0, +) / Double(m.count - 1)
            }
            let sb = spread(try await Self.lumaFrames(url, count: 30)), sa = spread(try await Self.lumaFrames(out, count: 30))
            print("metric deflicker_step_before=\(sb) after=\(sa)")
            #expect(sa < sb * 0.3, "\(sb) → \(sa)")
        }
    }

    @Test func enhanceQualityDoublesTheResolutionAndJobSwapsMedia() async throws {
        try await HeavyWorkGate.run {
            let url = try await Self.noisyVideo(flicker: false)
            var p = TestProject()
            let id = try await p.addMedia(url)
            let a = p.project.media[0]
            guard VideoEnhancer.canUpscale(a) else { print("skip: no low-latency super resolution on this Mac"); return }
            let e = VideoEnhancement(original: a.id, upscale: .hd)
            let cmd = try await VideoEnhanceJob.run(project: p.project, clipID: id, enhancement: e)
            try cmd.apply(to: &p.project)
            let clip = p[id]
            let now = try #require(clip.mediaID.flatMap(p.project.asset))
            #expect(now.pixelSize == Size2(640, 360) && clip.enhance == e)
            #expect(try await p.render(at: 0.2).average(x: 0, y: 0, w: 1, h: 0.2).luma > 0.3)
            // restoring the original
            let undo = try await VideoEnhanceJob.run(project: p.project, clipID: id, enhancement: VideoEnhancement(original: a.id))
            try undo.apply(to: &p.project)
            #expect(p[id].mediaID == a.id && p[id].enhance == nil)
        }
    }

    @Test func upscaledSizes() {
        #expect(VideoEnhancer.upscaledSize(.hd, width: 1280, height: 720) == (2560, 1440))
        #expect(VideoEnhancer.upscaledSize(.uhd, width: 1920, height: 1080) == (3840, 2160))
        #expect(VideoEnhancer.upscaledSize(.uhd, width: 640, height: 360) == (2560, 1440))   // ×4 max
        #expect(VideoEnhancer.upscaledSize(.uhd, width: 1280, height: 720) == (3840, 2160))
    }

    /// AI2: sources above 960 px (and UHD) go through VideoToolbox's full ML super resolution (×4 + downscale).
    @Test func enhanceQualityAbove960pxAndUHD() async throws {
        try await HeavyWorkGate.run {
            let url = try await TestMedia.video(.movingBox(.white, .red), seconds: 0.5, size: CGSize(width: 1280, height: 720))
            var p = TestProject(canvas: Size2(1280, 720))
            let id = try await p.addMedia(url)
            let a = p.project.media[0]
            guard VideoEnhancer.fullScalerSupports(1280, 720) else { print("skip: no full super resolution on this Mac"); return }
            #expect(VideoEnhancer.canUpscale(a))
            let cmd = try await VideoEnhanceJob.run(project: p.project, clipID: id, enhancement: VideoEnhancement(original: a.id, upscale: .uhd))
            try cmd.apply(to: &p.project)
            let now = try #require(p[id].mediaID.flatMap(p.project.asset))
            #expect(now.pixelSize == Size2(3840, 2160))
            #expect(abs(now.duration.seconds - 0.5) < 0.1)
            // the white background stays white, the red box stays red
            let img = try await p.render(at: 0.25)
            #expect(img.average(x: 0, y: 0, w: 1, h: 0.15).luma > 0.85)
        }
    }
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
