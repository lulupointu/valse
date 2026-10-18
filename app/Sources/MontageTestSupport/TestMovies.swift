@preconcurrency import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import MontageCore
import MontageEngine

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

    static func write(to url: URL, times: [Double], end: Double, codec: AVVideoCodecType, size: CGSize, audioStreams: Int = 0,
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
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "Montage", code: 90) }
        writer.startSession(atSourceTime: .zero)
        for (i, t) in times.enumerated() {
            while !vIn.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var pbOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pbOut)
            guard let pb = pbOut else { throw NSError(domain: "Montage", code: 92) }
            fill(pb, i)
            adaptor.append(pb, withPresentationTime: CMTime(seconds: t, preferredTimescale: 6000))
        }
        vIn.markAsFinished()
        for (k, aIn) in aIns.enumerated() {
            let total = Int(end * 48000)
            var pos = 0
            while pos < total {
                while !aIn.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
                let n = min(4800, total - pos)
                if let sb = SyntheticMedia.sineSampleBuffer(start: pos, count: n, hz: 440 * Double(k + 1)) { aIn.append(sb) }
                pos += n
            }
            aIn.markAsFinished()
        }
        writer.endSession(atSourceTime: CMTime(seconds: end, preferredTimescale: 6000))
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? NSError(domain: "Montage", code: 91) }
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
