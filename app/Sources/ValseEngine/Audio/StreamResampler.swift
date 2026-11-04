@preconcurrency import AVFoundation
import Foundation

/// Offline sample-rate conversion with a deterministic result (BUG-SPLIT-AUDIO-FLAKE).
///
/// Why not let AVFoundation resample (`AVSampleRateKey` on an AVAssetReader output, or an
/// AVAssetReaderAudioMixOutput mixing a 44.1 kHz track at 48 kHz)? Its converter sometimes restarts in the middle of
/// the stream — at an AAC packet boundary, depending on how the decode happens to be batched, so on the timing of the
/// machine: 1 read in ~10 of the same iPhone clip — and the restart leaves its filter latency of silence in the
/// output: ~15 samples at 0 with ringing on both sides, a click. Measured on `RealLikeMedia.iPhoneHLGPortrait`
/// (44.1 kHz AAC): AVAssetReaderTrackOutput at the native rate gave the same samples 40 reads in 40; at 48 kHz three
/// different dropouts (source 0.371 / 0.418 / 0.441 s = AAC packets 16, 18, 19) in 1 read out of 10 to 20, with any
/// `AVSampleRateConverterAlgorithmKey`. Decoding at the native rate and converting here, in fixed-size chunks fed in
/// order, gives the same output every time.
final class StreamResampler {
    let inRate: Double, outRate: Double
    let channels: Int
    let chunk: Int
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private var fill = 0
    /// Frames fed / delivered so far (the output is trimmed / padded to `fed × outRate / inRate` at `finish`).
    private(set) var fed = 0
    private(set) var delivered = 0

    init(from inRate: Double, to outRate: Double, channels: Int, chunk: Int = 4096) throws {
        self.inRate = inRate; self.outRate = outRate; self.channels = channels; self.chunk = chunk
        let ch = AVAudioChannelCount(channels)
        guard let inF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inRate, channels: ch, interleaved: false),
              let outF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outRate, channels: ch, interleaved: false),
              let conv = AVAudioConverter(from: inF, to: outF),
              let i = AVAudioPCMBuffer(pcmFormat: inF, frameCapacity: AVAudioFrameCount(chunk)),
              // room for a whole chunk plus what the converter held back: every call consumes all of its input
              let o = AVAudioPCMBuffer(pcmFormat: outF, frameCapacity: AVAudioFrameCount(Double(chunk) * outRate / inRate) + 4096)
        else { throw NSError(domain: "Valse.audio", code: 10, userInfo: [NSLocalizedDescriptionKey: "resampler \(inRate) → \(outRate)"]) }
        conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        conv.primeMethod = .normal   // zero latency: output frame 0 is input time 0
        converter = conv; input = i; output = o
    }

    /// Queues one input frame (`value(c)` = channel c); `emit` receives converted frames as non-interleaved channels.
    @inline(__always)
    func push(_ value: (Int) -> Float, _ emit: (UnsafePointer<UnsafeMutablePointer<Float>>, Int) throws -> Void) throws {
        let p = input.floatChannelData!
        for c in 0..<channels { p[c][fill] = value(c) }
        fill += 1; fed += 1
        if fill == chunk { try convert(final: false, emit) }
    }

    /// Converts what is queued, flushes the converter and pads / trims the output to the exact length.
    func finish(_ emit: (UnsafePointer<UnsafeMutablePointer<Float>>, Int) throws -> Void) throws {
        try convert(final: true, emit)
    }

    private var expectedTotal: Int { Int((Double(fed) * outRate / inRate).rounded()) }

    private func convert(final: Bool, _ emit: (UnsafePointer<UnsafeMutablePointer<Float>>, Int) throws -> Void) throws {
        input.frameLength = AVAudioFrameCount(fill)
        var given = fill == 0
        while true {
            output.frameLength = 0
            var err: NSError?
            let status = converter.convert(to: output, error: &err) { _, s in
                if given { s.pointee = final ? .endOfStream : .noDataNow; return nil }
                given = true; s.pointee = .haveData
                return self.input
            }
            if status == .error { throw err ?? NSError(domain: "Valse.audio", code: 11) }
            var n = Int(output.frameLength)
            if final { n = min(n, max(0, expectedTotal - delivered)) }
            if n > 0 { try emit(UnsafePointer(output.floatChannelData!), n); delivered += n }
            if status == .endOfStream || status == .inputRanDry || output.frameLength == 0 { break }
        }
        fill = 0
        if final, delivered < expectedTotal {
            let p = output.floatChannelData!
            while delivered < expectedTotal {
                let n = min(Int(output.frameCapacity), expectedTotal - delivered)
                for c in 0..<channels { p[c].update(repeating: 0, count: n) }
                try emit(UnsafePointer(p), n); delivered += n
            }
        }
    }
}
