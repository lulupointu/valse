@preconcurrency import AVFoundation
import Testing
import Foundation
import CoreVideo
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
        #expect(c.luma > 0.85 && c.luma < 1.0, "\(c)")
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
}
