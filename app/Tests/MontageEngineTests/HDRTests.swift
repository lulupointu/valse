@preconcurrency import AVFoundation
import Testing
import Foundation
import CoreVideo
import Metal
import MontageCore
import MontageEngine
import MontageTestSupport

/// HDR / 10-bit pipeline: HLG source probing and conversion, HDR projects exported as HEVC Main10 Rec.2020 HLG/PQ.
@Suite(.serialized) struct HDRTests {
    /// 10-bit HEVC HLG/BT.2020 file whose every pixel has luma code `y10` (0…1023, video range) and neutral chroma.
    static func hlgVideo(y10: Int, seconds: Double = 1) async throws -> URL {
        let url = TestMedia.directory.appendingPathComponent("hlg-\(y10)-\(seconds).mov")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let tmp = TestMedia.directory.appendingPathComponent("tmp-\(UUID().uuidString).mov")
        let w = 320, h = 180, fps: Int32 = 30
        let writer = try AVAssetWriter(outputURL: tmp, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoColorPropertiesKey: ColorTags(.hdrHLG).properties,
            AVVideoCompressionPropertiesKey: [AVVideoProfileLevelKey: "HEVC_Main10_AutoLevel", AVVideoAverageBitRateKey: 4_000_000]])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let frames = Int(seconds * Double(fps))
        for f in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var pbOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pbOut)
            let pb = pbOut!
            CVPixelBufferLockBaseAddress(pb, [])
            for (plane, value) in [(0, UInt16(y10 << 6)), (1, UInt16(512 << 6))] {
                let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane)!
                let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
                for y in 0..<CVPixelBufferGetHeightOfPlane(pb, plane) {
                    (base + y * bpr).assumingMemoryBound(to: UInt16.self)
                        .update(repeating: value, count: CVPixelBufferGetWidthOfPlane(pb, plane) * (plane == 0 ? 1 : 2))
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        try? FileManager.default.moveItem(at: tmp, to: url)
        return url
    }

    /// Mean 10-bit luma code of the first frame (decoded natively to x420, no colour conversion).
    static func lumaCode(_ url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
        reader.add(out)
        reader.startReading()
        guard let sb = out.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) else { return -1 }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        var sum = 0.0, n = 0.0
        for y in stride(from: h / 4, to: 3 * h / 4, by: 4) {
            let row = (base + y * bpr).assumingMemoryBound(to: UInt16.self)
            for x in stride(from: w / 4, to: 3 * w / 4, by: 4) { sum += Double(row[x] >> 6); n += 1 }
        }
        reader.cancelReading()
        return sum / n
    }

    static func code10(_ v: Double) -> Double { 64 + v * 876 }

    @Test func probeReadsHLGTags() async throws {
        let a = try await MediaProbe.probe(try await Self.hlgVideo(y10: 721))
        #expect(a.transfer == .hlg)
        #expect(a.isWideGamut)
        #expect(a.isHDR)
        #expect((a.bitDepth ?? 0) >= 10)
    }

    @Test func hlgSourceIsToneMappedInSDRProject() async throws {
        var p = TestProject()
        try await p.addMedia(try await Self.hlgVideo(y10: Int(Self.code10(0.75))))  // HLG reference white
        let c = try await p.render(at: 0.5).average(x: 0.4, y: 0.4, w: 0.2, h: 0.2)
        // Apple renders HLG 75 % as ≈ 0.61 SDR (the old soft-knee mapped it to 0.97: blown out)
        #expect(c.luma > 0.55 && c.luma < 0.72, "\(c)")
        #expect(abs(c.r - c.b) < 0.05)
    }

    @Test func hdrProjectExportsHEVCMain10HLG() async throws {
        var p = TestProject(canvas: Size2(640, 360))
        p.project.settings.colorSpace = .hdrHLG
        try await p.addVideo(.solid(.white), seconds: 1)
        var s = ExportSettings(); s.resolution = .p480   // H.264 requested → HEVC Main10
        let r = try await p.export(seconds: 0.5, settings: s)
        #expect(r.probe.videoCodec == "hevc")
        if MediaInfo.ffprobePath != nil {
            #expect(r.probe.pixelFormat == "yuv420p10le")
            #expect(r.probe.colorTransfer == "arib-std-b67")
            #expect(r.probe.colorPrimaries == "bt2020")
        }
        // SDR white = 203-nit reference white = HLG code 0.75.
        let y = try await Self.lumaCode(r.url)
        #expect(abs(y - Self.code10(0.75)) < 20, "luma code \(y)")
    }

    @Test func hlgSourcePassesThroughHLGProject() async throws {
        var p = TestProject(canvas: Size2(320, 180))
        p.project.settings.colorSpace = .hdrHLG
        try await p.addMedia(try await Self.hlgVideo(y10: 600))
        var s = ExportSettings(); s.resolution = .p480; s.codec = .hevc
        let r = try await p.export(seconds: 0.5, settings: s)
        let y = try await Self.lumaCode(r.url)
        #expect(abs(y - 600) < 12, "luma code \(y)")
    }

    @Test func pqProjectTagsAndProResHDR() async throws {
        var p = TestProject(canvas: Size2(320, 180))
        p.project.settings.colorSpace = .hdrPQ
        try await p.addVideo(.solid(RGBA(0.5, 0.5, 0.5)), seconds: 1)
        var s = ExportSettings(); s.resolution = .p480; s.codec = .hevc
        let r = try await p.export(seconds: 0.5, settings: s)
        if MediaInfo.ffprobePath != nil { #expect(r.probe.colorTransfer == "smpte2084") }
        let expected = Self.code10(ColorMath.convert([0.5, 0.5, 0.5], from: .sdr, wide: false, to: .pq, wide: true)[1])
        let y = try await Self.lumaCode(r.url)
        #expect(abs(y - expected) < 20, "luma code \(y) expected \(expected)")
        if let ff = MediaInfo.ffprobePath {
            // HDR10 static metadata on the first frame
            let side = try Self.shell(ff, ["-v", "error", "-select_streams", "v:0", "-read_intervals", "%+#1", "-show_frames",
                                            "-show_entries", "frame=side_data_list", "-of", "json", r.url.path])
            #expect(side.contains("Mastering display metadata") && side.contains("\"max_luminance\": \"10000000/10000\""), "\(side)")
            #expect(side.contains("Content light level metadata") && side.contains("\"max_content\": 1000"))
        }
        s.codec = .proRes422
        let pr = try await p.export(seconds: 0.5, settings: s)
        #expect(pr.probe.videoCodec == "prores")
        if MediaInfo.ffprobePath != nil { #expect(pr.probe.colorTransfer == "smpte2084" && pr.probe.colorPrimaries == "bt2020") }
    }

    @Test func sdrExportKeepsRec709Tags() async throws {
        guard MediaInfo.ffprobePath != nil else { return }
        var p = TestProject(canvas: Size2(320, 180))
        try await p.addVideo(.solid(.red), seconds: 1)
        var s = ExportSettings(); s.resolution = .p480
        let r = try await p.export(seconds: 0.5, settings: s)
        #expect(r.probe.videoCodec == "h264" && r.probe.pixelFormat == "yuv420p")
        #expect(r.probe.colorTransfer == "bt709" && r.probe.colorPrimaries == "bt709")
    }

    // MARK: HDR footage in SDR / HDR projects (owner report: blown highlights + orange skin, washed-out HDR preview)

    /// Encoded R'G'B' patches (4 × 3 grid): greys 25/50/75/100 %, two skin tones, saturated red / green (outside
    /// BT.709), greys 62/85 %, blue, warm highlight.
    static let patches: [[Double]] = [
        [0.25, 0.25, 0.25], [0.50, 0.50, 0.50], [0.75, 0.75, 0.75], [1.0, 1.0, 1.0],
        [0.70, 0.58, 0.50], [0.60, 0.47, 0.40], [0.75, 0.20, 0.20], [0.30, 0.70, 0.35],
        [0.62, 0.62, 0.62], [0.85, 0.85, 0.85], [0.20, 0.30, 0.70], [0.90, 0.80, 0.70],
    ]
    static let ffmpegPath = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// 10-bit HEVC BT.2020 clip of `patches` encoded by ffmpeg (independent YCbCr matrix / range), HLG or PQ.
    static func ffmpegPatchClip(_ tf: TransferFunction) throws -> URL? {
        guard let ff = ffmpegPath else { return nil }
        let trc = tf == .pq ? "smpte2084" : "arib-std-b67"
        let url = TestMedia.directory.appendingPathComponent("patches-\(trc).mov")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let w = 640, h = 360
        var ppm = Data("P6\n\(w) \(h)\n65535\n".utf8)
        for y in 0..<h {
            for x in 0..<w {
                for c in patches[(y * 3 / h) * 4 + x * 4 / w] {
                    let v = UInt16((c * 65535).rounded())
                    ppm.append(UInt8(v >> 8)); ppm.append(UInt8(v & 0xff))
                }
            }
        }
        let src = TestMedia.directory.appendingPathComponent("patches-\(UUID().uuidString).ppm")
        try ppm.write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }
        let tmp = TestMedia.directory.appendingPathComponent("tmp-\(UUID().uuidString).mov")
        _ = try shell(ff, ["-v", "error", "-y", "-loop", "1", "-i", src.path, "-t", "1", "-r", "30",
                           "-vf", "scale=in_range=pc:out_color_matrix=bt2020:out_range=tv,format=yuv420p10le",
                           "-c:v", "libx265", "-x265-params", "log-level=error:crf=4:colorprim=bt2020:transfer=\(trc):colormatrix=bt2020nc:range=limited",
                           "-tag:v", "hvc1", "-color_primaries", "bt2020", "-color_trc", trc, "-colorspace", "bt2020nc",
                           "-color_range", "tv", tmp.path])
        guard FileManager.default.fileExists(atPath: tmp.path) else { return nil }
        try? FileManager.default.moveItem(at: tmp, to: url)
        return url
    }

    static func patchCentre(_ i: Int) -> (Double, Double) { (Double(i % 4) * 0.25 + 0.08, Double(i / 4) / 3 + 0.1) }

    /// Rendered patch colours vs the CPU reference (ColorMath) and Apple's own HDR → SDR conversion of the same file.
    func checkPatches(_ tf: TransferFunction) async throws {
        guard let clip = try Self.ffmpegPatchClip(tf) else { return }   // no ffmpeg on this machine
        var p = TestProject(canvas: Size2(640, 360))
        try await p.addMedia(clip)
        let img = try await p.render(at: 0.5)
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: clip))
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        let apple = Bitmap(try await gen.image(at: CMTime(value: 15, timescale: 30)).image)
        var appleErr = 0.0
        for (i, code) in Self.patches.enumerated() {
            let (x, y) = Self.patchCentre(i)
            let got = img.average(x: x, y: y, w: 0.09, h: 0.13)
            let want = ColorMath.convert(code, from: tf, wide: true, to: .sdr, wide: false)
            #expect(got.isClose(to: RGBA(want[0], want[1], want[2]), tolerance: 0.05), "\(tf) patch \(i) \(code): \(got) vs \(want)")
            let a = apple.average(x: x, y: y, w: 0.09, h: 0.13)
            appleErr += (abs(got.r - a.r) + abs(got.g - a.g) + abs(got.b - a.b)) / 3
            #expect(got.r <= 0.999 || code[0] >= 0.85 || tf == .pq, "\(tf) patch \(i) blown: \(got)")
        }
        // mean distance to Apple's rendering (HLG ≈ 0.03; PQ patches are very bright: both saturate)
        #expect(appleErr / Double(Self.patches.count) < (tf == .hlg ? 0.06 : 0.13), "\(tf) vs Apple: \(appleErr / 12)")
    }

    @Test func hlgPatchesInSDRProject() async throws { try await checkPatches(.hlg) }
    @Test func pqPatchesInSDRProject() async throws { try await checkPatches(.pq) }

    /// HLG skin patch in an SDR project: natural (Apple: 161,105,90), not orange (old pipeline: ≈ 246,162,140 on the
    /// owner's footage).
    @Test func hlgSkinPatchNotOversaturated() async throws {
        guard let clip = try Self.ffmpegPatchClip(.hlg) else { return }
        var p = TestProject(canvas: Size2(640, 360))
        try await p.addMedia(clip)
        let img = try await p.render(at: 0.5)
        let (x, y) = Self.patchCentre(4)
        let skin = img.average(x: x, y: y, w: 0.09, h: 0.13)
        #expect(skin.isClose(to: RGBA(161.0 / 255, 105.0 / 255, 90.0 / 255), tolerance: 0.08), "\(skin)")
        let (wx, wy) = Self.patchCentre(2)
        #expect(img.average(x: wx, y: wy, w: 0.09, h: 0.13).luma < 0.72)   // 75 % HLG reference white not blown
    }

    /// Preview of an HDR project on a non-EDR screen (and player snapshots): the present pass tone-maps the HLG / PQ
    /// code values with the same math as SDR export (the old preview showed raw HLG codes: grey, low contrast).
    @Test func previewToneMapMatchesExportMath() throws {
        let ctx = MetalContext.shared
        for tf in [TransferFunction.hlg, .pq] {
            for code in [[0.75, 0.75, 0.75], [0.70, 0.58, 0.50], [0.30, 0.70, 0.35]] {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 8, height: 8, mipmapped: false)
                d.usage = [.shaderRead]; d.storageMode = .shared
                let src = try #require(ctx.device.makeTexture(descriptor: d))
                let px: [UInt16] = (0..<64).flatMap { _ in [Half.bits(Float(code[0])), Half.bits(Float(code[1])), Half.bits(Float(code[2])), 0x3C00] }
                px.withUnsafeBytes { src.replace(region: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 8 * 8) }
                let od = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 8, height: 8, mipmapped: false)
                od.usage = [.renderTarget, .shaderRead]; od.storageMode = .shared
                let out = try #require(ctx.device.makeTexture(descriptor: od))
                let cmd = try #require(ctx.queue.makeCommandBuffer())
                Presenter.encode(src, to: out, contentAspect: 1, letterbox: .black, mode: .toneMapToSDR(tf), commandBuffer: cmd)
                cmd.commit(); cmd.waitUntilCompleted()
                var bgra = [UInt8](repeating: 0, count: 4)
                out.getBytes(&bgra, bytesPerRow: 32, from: MTLRegionMake2D(4, 4, 1, 1), mipmapLevel: 0)
                let want = ColorMath.convert(code, from: tf, wide: true, to: .sdr, wide: false)
                let got = [Double(bgra[2]), Double(bgra[1]), Double(bgra[0])].map { $0 / 255 }
                for (g, w) in zip(got, want) { #expect(abs(g - w) < 0.02, "\(tf) \(code): \(got) vs \(want)") }
            }
        }
    }

    static func shell(_ exe: String, _ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try p.run()
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }
}
