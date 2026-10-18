@preconcurrency import AVFoundation
import Foundation
import MontageCore

/// Audio peaks for timeline waveforms: 100 peaks/s (max |sample|, mono mix, 0…255), computed once per media in the
/// background and stored in ~/Library/Caches/Montage/waveforms/<hash>.peaks. Lower zoom levels downsample on draw.
public struct Waveform: Sendable {
    public static let peaksPerSecond = 100
    public let peaks: [UInt8]
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
    private let directory = MontagePaths.cacheDirectory.appendingPathComponent("waveforms", isDirectory: true)

    public func cached(_ a: MediaAsset) -> Waveform? { lock.withLock { memory[a.contentHash] } }

    public func waveform(_ a: MediaAsset) async -> Waveform? {
        guard a.hasAudio else { return nil }
        if let w = cached(a) { return w }
        guard lock.withLock({ inflight.insert(a.contentHash).inserted }) else { return nil }
        defer { _ = lock.withLock { inflight.remove(a.contentHash) } }
        let file = directory.appendingPathComponent("\(a.contentHash).peaks")
        if let d = try? Data(contentsOf: file) {
            let w = Waveform(peaks: [UInt8](d)); lock.withLock { memory[a.contentHash] = w }; return w
        }
        guard let w = try? await Self.compute(PlayableMediaCache.shared.resolvedURL(for: a)) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(w.peaks).write(to: file)
        lock.withLock { memory[a.contentHash] = w }
        return w
    }

    public static func compute(_ url: URL) async throws -> Waveform {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return Waveform(peaks: []) }
        let reader = try AVAssetReader(asset: asset)
        let sr = 8000
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(out)
        reader.startReading()
        let per = sr / Waveform.peaksPerSecond
        var peaks: [UInt8] = []
        var cur: Int32 = 0, n = 0
        while let sb = out.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            try Task.checkCancellation()
            let len = CMBlockBufferGetDataLength(bb)
            var chunk = [Int16](repeating: 0, count: len / 2)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            for s in chunk {
                let v = abs(Int32(s)); if v > cur { cur = v }
                n += 1
                if n == per { peaks.append(UInt8(min(255, cur * 255 / 32767))); cur = 0; n = 0 }
            }
        }
        if n > 0 { peaks.append(UInt8(min(255, cur * 255 / 32767))) }
        return Waveform(peaks: peaks)
    }
}
