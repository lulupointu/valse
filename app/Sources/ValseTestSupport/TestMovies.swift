@preconcurrency import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ValseCore
import ValseEngine

/// Special-purpose test movies (alpha, VFR, multiple audio streams) written with AVAssetWriter.
public enum TestMovies {
    /// One image held for `seconds`. `alpha` → ProRes 4444 with straight alpha, else H.264.
    public static func write(to url: URL, image: CGImage, seconds: Double, alpha: Bool) async throws {
        let box = UncheckedSendable(image)
        try await write(to: url, times: [0], end: seconds, codec: alpha ? .proRes4444 : .h264,
                        size: CGSize(width: image.width, height: image.height)) { pb, _ in
            draw(box.value, into: pb, straight: alpha)
        }
    }

    /// Solid frames at explicit (possibly irregular) presentation times; optional sine audio streams (440 Hz × n).
    public static func write(to url: URL, times: [Double], end: Double, audioStreams: Int = 0,
                             color: @escaping @Sendable (Int) -> RGBA) async throws {
        try await write(to: url, times: times, end: end, codec: .h264, size: CGSize(width: 160, height: 90), audioStreams: audioStreams) { pb, i in
            draw(nil, into: pb, straight: false, fill: color(i))
        }
    }

    /// AVAssetWriter's encoder fails now and then on a loaded machine (its pixel buffer pool then disappears: a bare
    /// "Code=92" flaked RelightRenderTests, FLAKY-SYS-UNIT): the movie is rewritten, twice at most.
    static func write(to url: URL, times: [Double], end: Double, codec: AVVideoCodecType, size: CGSize, audioStreams: Int = 0,
                      fill: @escaping @Sendable (CVPixelBuffer, Int) -> Void) async throws {
        for attempt in 1... {
            do {
                return try await writeOnce(to: url, times: times, end: end, codec: codec, size: size, audioStreams: audioStreams, fill: fill)
            } catch where attempt < 3 && !(error is CancellationError) {
                print("TestMovies: writing \(url.lastPathComponent) failed (attempt \(attempt)): \(error)")
                try await Task.sleep(nanoseconds: UInt64(attempt) * 300_000_000)
            }
        }
    }

    static func writeOnce(to url: URL, times: [Double], end: Double, codec: AVVideoCodecType, size: CGSize, audioStreams: Int,
                          fill: @escaping @Sendable (CVPixelBuffer, Int) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var vs: [String: Any] = [AVVideoCodecKey: codec, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)]
        if codec == .h264 { vs[AVVideoCompressionPropertiesKey] = [AVVideoAllowFrameReorderingKey: false, AVVideoAverageBitRateKey: 2_000_000] }
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vs)
        vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height)])
        writer.add(vIn)
        var aIns: [AVAssetWriterInput] = []
        for _ in 0..<audioStreams {
            var layout = AudioChannelLayout(); layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000,
                AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)])
            i.expectsMediaDataInRealTime = false
            writer.add(i); aIns.append(i)
        }
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "Valse", code: 90) }
        writer.startSession(atSourceTime: .zero)
        for (i, t) in times.enumerated() {
            try await SyntheticMedia.waitUntilReady(vIn, writer)
            var pbOut: CVPixelBuffer?
            // the writer's pool is gone once its encoder failed: report the writer's error (not a bare code)
            if let pool = adaptor.pixelBufferPool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) }
            guard let pb = pbOut else { throw writer.error ?? NSError(domain: "Valse", code: 92) }
            fill(pb, i)
            guard adaptor.append(pb, withPresentationTime: CMTime(seconds: t, preferredTimescale: 6000)) else {
                throw writer.error ?? NSError(domain: "Valse", code: 93)
            }
        }
        vIn.markAsFinished()
        for (k, aIn) in aIns.enumerated() {
            let total = Int(end * 48000)
            var pos = 0
            while pos < total {
                try await SyntheticMedia.waitUntilReady(aIn, writer)
                let n = min(4800, total - pos)
                if let sb = SyntheticMedia.sineSampleBuffer(start: pos, count: n, hz: 440 * Double(k + 1)) { aIn.append(sb) }
                pos += n
            }
            aIn.markAsFinished()
        }
        writer.endSession(atSourceTime: CMTime(seconds: end, preferredTimescale: 6000))
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? NSError(domain: "Valse", code: 91) }
    }

    static func draw(_ img: CGImage?, into pb: CVPixelBuffer, straight: Bool, fill: RGBA? = nil) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb),
              let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        if let fill { ctx.setFillColor(CGColor(srgbRed: fill.r, green: fill.g, blue: fill.b, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
        if let img { ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h)) }
        // straight alpha: the drawn content is fully opaque or fully clear in tests, nothing to un-premultiply
        _ = straight
    }
}
