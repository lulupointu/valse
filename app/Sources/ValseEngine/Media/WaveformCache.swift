@preconcurrency import AVFoundation
import Foundation
import ValseCore

/// Audio levels for timeline waveforms: 100 values/s of peak (max |sample|) and RMS, mono mix, 0…255, computed once per
/// media in the background and stored in ~/Library/Caches/Valse/waveforms/<hash>.wave (peaks then RMS; AU-019 two-layer
/// drawing). Lower zoom levels downsample on draw.
public struct Waveform: Sendable {
    public static let peaksPerSecond = 100
    public let peaks: [UInt8]
    /// RMS per 10 ms (same length as `peaks`; empty for waveforms built from peaks only).
    public let rms: [UInt8]
    public init(peaks: [UInt8], rms: [UInt8] = []) { self.peaks = peaks; self.rms = rms }

    /// RMS level over [start, end) seconds (energy average of the 10 ms windows), 0…1. Falls back to 0.7 × peak.
    public func rmsLevel(from start: Double, to end: Double) -> Double {
        guard rms.count == peaks.count, !rms.isEmpty else { return peak(from: start, to: end) * 0.7 }
        let a = max(0, Int(start * Double(Self.peaksPerSecond))), b = min(rms.count, max(a + 1, Int(end * Double(Self.peaksPerSecond))))
        guard a < b else { return 0 }
        var sum = 0.0
        for i in a..<b { let v = Double(rms[i]) / 255; sum += v * v }
        return (sum / Double(b - a)).squareRoot()
    }

    /// File layout: peaks then RMS (2 × n bytes).
    public var data: Data { Data(peaks + rms) }
    public init?(data d: Data) {
        guard d.count % 2 == 0 else { return nil }
        let b = [UInt8](d), n = b.count / 2
        self.init(peaks: Array(b[0..<n]), rms: Array(b[n...]))
    }
    /// Max peak in [start, end) seconds, 0…1.
    public func peak(from start: Double, to end: Double) -> Double {
        let a = max(0, Int(start * Double(Self.peaksPerSecond))), b = min(peaks.count, max(a + 1, Int(end * Double(Self.peaksPerSecond))))
        guard a < b else { return 0 }
        var m: UInt8 = 0
        for i in a..<b where peaks[i] > m { m = peaks[i] }
        return Double(m) / 255
    }
}

public final class WaveformCache: @unchecked Sendable {
    public static let shared = WaveformCache()
    private let lock = NSLock()
    private var memory: [String: Waveform] = [:]
    private var inflight: Set<String> = []
    private let directory = ValsePaths.cacheDirectory.appendingPathComponent("waveforms", isDirectory: true)

    public func cached(_ a: MediaAsset) -> Waveform? { lock.withLock { memory[a.contentHash] } }

    public func waveform(_ a: MediaAsset) async -> Waveform? {
        guard a.hasAudio else { return nil }
        if let w = cached(a) { return w }
        guard lock.withLock({ inflight.insert(a.contentHash).inserted }) else { return nil }
        defer { _ = lock.withLock { inflight.remove(a.contentHash) } }
        let file = directory.appendingPathComponent("\(a.contentHash).wave")
        if let d = try? Data(contentsOf: file), let w = Waveform(data: d) {
            lock.withLock { memory[a.contentHash] = w }; return w
        }
        guard let w = try? await Self.compute(PlayableMediaCache.shared.resolvedURL(for: a)) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? w.data.write(to: file)
        lock.withLock { memory[a.contentHash] = w }
        return w
    }

    public static func compute(_ url: URL) async throws -> Waveform {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return Waveform(peaks: []) }
        // the read loop blocks in copyNextSampleBuffer: keep it off the cooperative pool (OffPool)
        return try await OffPool.run { ctx in
            let reader = try AVAssetReader(asset: asset)
            let sr = 8000
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
            reader.add(out)
            reader.startReading()
            let per = sr / Waveform.peaksPerSecond
            var peaks: [UInt8] = [], rms: [UInt8] = []
            var cur: Int32 = 0, n = 0, sq: Double = 0
            func flush() {
                peaks.append(UInt8(min(255, cur * 255 / 32767)))
                rms.append(UInt8(min(255, (sq / Double(max(n, 1))).squareRoot() * 255 / 32767)))
            }
            while let sb = out.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
                try ctx.checkCancellation()
                let len = CMBlockBufferGetDataLength(bb)
                var chunk = [Int16](repeating: 0, count: len / 2)
                _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
                for s in chunk {
                    let v = abs(Int32(s)); if v > cur { cur = v }
                    sq += Double(v) * Double(v)
                    n += 1
                    if n == per { flush(); cur = 0; n = 0; sq = 0 }
                }
            }
            if n > 0 { flush() }
            return Waveform(peaks: peaks, rms: rms)
        }
    }
}
