@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import MontageCore

/// Generates small synthetic media files (tests, demo project, base track). Deterministic content:
/// each frame is a solid background plus an optional box, so pixel asserts are easy and codec-robust.
public enum SyntheticMedia {
    public enum Codec: Sendable { case h264, hevc, proRes422 }

    public struct Paint: Sendable {
        public var background: (UInt8, UInt8, UInt8)
        /// Normalized rect (x, y, w, h; y down) and colour.
        public var box: (CGRect, (UInt8, UInt8, UInt8))?
        public init(background: (UInt8, UInt8, UInt8), box: (CGRect, (UInt8, UInt8, UInt8))? = nil) {
            self.background = background; self.box = box
        }
    }

    /// Common patterns.
    public enum Pattern: Sendable {
        case solid(RGBA)
        /// Gray level encodes the frame index: level = (frame * 4) % 256 → frame-accuracy tests.
        case frameIndex
        /// Left half `a`, right half `b` (orientation/transform tests).
        case split(RGBA, RGBA)
        /// Background with a box moving left → right.
        case movingBox(RGBA, RGBA)
        /// Even frames `a`, odd frames `b` (frame blending / motion blur tests).
        case alternate(RGBA, RGBA)

        func paint(_ frame: Int, _ total: Int) -> Paint {
            func c(_ x: RGBA) -> (UInt8, UInt8, UInt8) { (UInt8(x.r * 255), UInt8(x.g * 255), UInt8(x.b * 255)) }
            switch self {
            case .solid(let col): return Paint(background: c(col))
            case .frameIndex:
                let l = UInt8((frame * 4) % 256); return Paint(background: (l, l, l))
            case .split(let a, let b): return Paint(background: c(a), box: (CGRect(x: 0.5, y: 0, width: 0.5, height: 1), c(b)))
            case .movingBox(let bg, let fg):
                let x = Double(frame) / Double(max(total - 1, 1)) * 0.75
                return Paint(background: c(bg), box: (CGRect(x: x, y: 0.375, width: 0.25, height: 0.25), c(fg)))
            case .alternate(let a, let b): return Paint(background: c(frame % 2 == 0 ? a : b))
            }
        }
    }

    /// Writes a video file. Returns when finished.
    public static func writeVideo(to url: URL, size: CGSize, seconds: Double, fps: Int32, codec: Codec = .h264,
                                  pattern: Pattern, audioHz: Double? = nil) async throws {
        try await writeVideo(to: url, size: size, seconds: seconds, fps: fps, codec: codec, audioHz: audioHz) { f, n in
            pattern.paint(f, n)
        }
    }

    /// Low-level variant: `paint(frameIndex, frameCount)`.
    public static func writeVideo(to url: URL, size: CGSize, seconds: Double, fps: Int32, codec: Codec = .h264,
                                  audioHz: Double? = nil, paint: @escaping @Sendable (Int, Int) -> (UInt8, UInt8, UInt8)) async throws {
        try await writeVideo(to: url, size: size, seconds: seconds, fps: fps, codec: codec, audioHz: audioHz) { f, n in
            Paint(background: paint(f, n))
        }
    }

    public static func writeVideo(to url: URL, size: CGSize, seconds: Double, fps: Int32, codec: Codec,
                                  audioHz: Double?, paint: @escaping @Sendable (Int, Int) -> Paint) async throws {
        try? FileManager.default.removeItem(at: url)
        let fileType: AVFileType = codec == .proRes422 ? .mov : (url.pathExtension.lowercased() == "mov" ? .mov : .mp4)
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let codecType: AVVideoCodecType = codec == .h264 ? .h264 : (codec == .hevc ? .hevc : .proRes422)
        var vSettings: [String: Any] = [AVVideoCodecKey: codecType, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)]
        if codec != .proRes422 {
            vSettings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: max(500_000, Int(size.width * size.height * 4)),
                                                          AVVideoMaxKeyFrameIntervalKey: Int(fps),
                                                          AVVideoAllowFrameReorderingKey: false]
        }
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
        vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height)])
        writer.add(vIn)
        var aIn: AVAssetWriterInput?
        if audioHz != nil {
            var layout = AudioChannelLayout(); layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000,
                AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)])
            i.expectsMediaDataInRealTime = false
            writer.add(i); aIn = i
        }
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "Montage", code: 60) }
        writer.startSession(atSourceTime: .zero)
        let frames = max(1, Int((seconds * Double(fps)).rounded()))
        let w = Int(size.width), h = Int(size.height)

        let box = UncheckedSendable((vIn, adaptor, aIn, writer))
        try await withThrowingTaskGroup(of: Void.self) { g in
            g.addTask {
                let (vIn, adaptor, _, writer) = box.value
                for f in 0..<frames {
                    try await waitUntilReady(vIn, writer)
                    guard let pool = adaptor.pixelBufferPool else { throw NSError(domain: "Montage", code: 61) }
                    var pbOut: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
                    guard let pb = pbOut else { throw NSError(domain: "Montage", code: 62) }
                    fill(pb, w: w, h: h, paint: paint(f, frames))
                    adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: fps))
                }
                vIn.markAsFinished()
            }
            if let hz = audioHz {
                g.addTask {
                    let (_, _, aIn, writer) = box.value
                    guard let aIn else { return }
                    let total = Int(seconds * 48000)
                    var pos = 0
                    while pos < total {
                        try await waitUntilReady(aIn, writer)
                        let n = min(4800, total - pos)
                        if let sb = sineBuffer(start: pos, count: n, hz: hz) { aIn.append(sb) }
                        pos += n
                    }
                    aIn.markAsFinished()
                }
            }
            try await g.waitForAll()
        }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? NSError(domain: "Montage", code: 63) }
    }

    /// Writes a still PNG image.
    public static func writePNG(to url: URL, size: CGSize, pattern: Pattern) throws {
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw NSError(domain: "Montage", code: 64) }
        let p = pattern.paint(0, 1)
        func cg(_ c: (UInt8, UInt8, UInt8)) -> CGColor { CGColor(srgbRed: Double(c.0) / 255, green: Double(c.1) / 255, blue: Double(c.2) / 255, alpha: 1) }
        ctx.setFillColor(cg(p.background)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if let (r, c) = p.box {
            ctx.setFillColor(cg(c))
            ctx.fill(CGRect(x: r.minX * Double(w), y: (1 - r.maxY) * Double(h), width: r.width * Double(w), height: r.height * Double(h)))
        }
        guard let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw NSError(domain: "Montage", code: 65) }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "Montage", code: 66) }
    }

    /// Writes a mono→stereo sine WAV/M4A audio-only file.
    public static func writeAudio(to url: URL, seconds: Double, hz: Double) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        var layout = AudioChannelLayout(); layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)])
        writer.add(aIn)
        writer.startWriting(); writer.startSession(atSourceTime: .zero)
        let total = Int(seconds * 48000)
        var pos = 0
        while pos < total {
            try await waitUntilReady(aIn, writer)
            let n = min(4800, total - pos)
            if let sb = sineBuffer(start: pos, count: n, hz: hz) { aIn.append(sb) }
            pos += n
        }
        aIn.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? NSError(domain: "Montage", code: 67) }
    }

    /// Waits for `input` to take more data. A writer that failed (an encoder error under load) never makes its inputs
    /// ready again: throw instead of polling forever (a UI test hung 2 min building the demo media this way).
    static func waitUntilReady(_ input: AVAssetWriterInput, _ writer: AVAssetWriter) async throws {
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed || writer.status == .cancelled { throw writer.error ?? NSError(domain: "Montage", code: 68) }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    static func fill(_ pb: CVPixelBuffer, w: Int, h: Int, paint: Paint) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        func px(_ c: (UInt8, UInt8, UInt8)) -> UInt32 { 0xFF00_0000 | UInt32(c.0) << 16 | UInt32(c.1) << 8 | UInt32(c.2) }  // BGRA LE
        let bg = px(paint.background)
        var bx0 = 0, bx1 = 0, by0 = 0, by1 = 0, fg: UInt32 = 0
        if let (r, c) = paint.box {
            bx0 = Int(r.minX * Double(w)); bx1 = Int(r.maxX * Double(w)); by0 = Int(r.minY * Double(h)); by1 = Int(r.maxY * Double(h)); fg = px(c)
        }
        for y in 0..<h {
            let row = (base + y * bpr).assumingMemoryBound(to: UInt32.self)
            row.update(repeating: bg, count: w)
            if y >= by0 && y < by1 && bx1 > bx0 { (row + bx0).update(repeating: fg, count: min(bx1, w) - bx0) }
        }
    }

    /// 48 kHz stereo 16-bit sine chunk (test media).
    public static func sineSampleBuffer(start: Int, count: Int, hz: Double) -> CMSampleBuffer? { sineBuffer(start: start, count: count, hz: hz) }

    static func sineBuffer(start: Int, count: Int, hz: Double) -> CMSampleBuffer? {
        var samples = [Int16](repeating: 0, count: count * 2)
        for i in 0..<count {
            let v = Int16(sin(2 * .pi * hz * Double(start + i) / 48000) * 0.3 * 32767)
            samples[2 * i] = v; samples[2 * i + 1] = v
        }
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
                                               mBitsPerChannel: 16, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        var block: CMBlockBuffer?
        let bytes = count * 4
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
        guard let block, let fmt else { return nil }
        samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: fmt,
                                                             sampleCount: count, presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: 48000),
                                                             packetDescriptions: nil, sampleBufferOut: &sb)
        return sb
    }
}
