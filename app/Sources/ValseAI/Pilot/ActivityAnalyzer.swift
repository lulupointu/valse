@preconcurrency import AVFoundation
import Accelerate
import Foundation
import ValseCore
import ValseEngine

/// Measures `ActivityProfile`s (audio level per 50 ms + visual motion per 0.25 s) of a media file, once per content hash
/// (memory + `Caches/Valse/activity/<hash>.json`). Cheap DSP, no model: 16 kHz mono decode for the level, a 64 px
/// luma decode (proxy when ready) for motion. Used by EditPilot (AI-048) for "boring parts" (speed up quiet parts);
/// silence cuts use Quick cut's detector (`QuickCutAnalyzer`, TL-048).
public final class ActivityAnalyzer: @unchecked Sendable {
    public static let shared = ActivityAnalyzer()
    private let lock = NSLock()
    private var memory: [String: ActivityProfile] = [:]

    var directory: URL { ValsePaths.cacheDirectory.appendingPathComponent("activity", isDirectory: true) }
    func file(_ hash: String) -> URL { directory.appendingPathComponent("\(hash).v1.json") }

    public func cached(_ asset: MediaAsset) -> ActivityProfile? {
        if let p = lock.withLock({ memory[asset.contentHash] }) { return p }
        guard !asset.contentHash.isEmpty, let d = try? Data(contentsOf: file(asset.contentHash)),
              let p = try? JSONDecoder().decode(ActivityProfile.self, from: d) else { return nil }
        lock.withLock { memory[asset.contentHash] = p }
        return p
    }

    public func profile(_ asset: MediaAsset, progress: (@Sendable (Double) -> Void)? = nil) async throws -> ActivityProfile {
        if let p = cached(asset) { return p }
        let audio = asset.hasAudio ? try await Self.levels(url: asset.url) { progress?($0 * 0.5) } : []
        try Task.checkCancellation()
        let video = asset.kind == .video
            ? try await Self.motion(url: ProxyManager.shared.readyProxyURL(for: asset) ?? asset.url) { progress?(0.5 + $0 * 0.5) } : []
        let p = ActivityProfile(levels: audio, motion: video)
        lock.withLock { memory[asset.contentHash] = p }
        if !asset.contentHash.isEmpty {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? JSONEncoder().encode(p).write(to: file(asset.contentHash), options: .atomic)
        }
        progress?(1)
        return p
    }

    /// RMS level in dBFS per 50 ms window of the first audio track.
    static func levels(url: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false])
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? AIToolError.noInput }
        defer { reader.cancelReading() }
        let window = Int(16000 * ActivityProfile.audioStep)
        var pending: [Float] = []
        var levels: [Float] = []
        // blocking read loop: off the cooperative pool (OffPool)
        try await OffPool.run { ctx in
            while let sb = out.copyNextSampleBuffer() {
                try ctx.checkCancellation()
                guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
                let n = CMBlockBufferGetDataLength(block) / 4
                var chunk = [Float](repeating: 0, count: n)
                chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
                pending += chunk
                var i = 0
                while pending.count - i >= window {
                    var rms: Float = 0
                    pending.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress! + i, 1, &rms, vDSP_Length(window)) }
                    levels.append(rms > 1e-5 ? 20 * log10(rms) : -100)
                    i += window
                }
                pending.removeFirst(i)
                if duration > 0 { progress?(min(1, Double(levels.count) * ActivityProfile.audioStep / duration)) }
            }
        }
        return levels
    }

    /// Mean absolute luma difference (0…1) between frames 0.25 s apart, on a 64 px wide decode.
    static func motion(url: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let duration = try await asset.load(.duration).seconds
        let natural = try await track.load(.naturalSize)
        let w = 64, h = max(8, Int((64 * abs(natural.height) / max(abs(natural.width), 1)).rounded()) / 2 * 2)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? AIToolError.noInput }
        defer { reader.cancelReading() }
        var result: [Float] = []
        var previous: [UInt8]?
        var next = 0.0
        // blocking read loop: off the cooperative pool (OffPool)
        try await OffPool.run { ctx in
            while let sb = out.copyNextSampleBuffer() {
                try ctx.checkCancellation()
                let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                guard t + 1e-3 >= next, let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                next += ActivityProfile.motionStep
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                let pw = CVPixelBufferGetWidthOfPlane(pb, 0), ph = CVPixelBufferGetHeightOfPlane(pb, 0)
                let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
                var luma = [UInt8](repeating: 0, count: pw * ph)
                if let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self) {
                    for y in 0..<ph { for x in 0..<pw { luma[y * pw + x] = base[y * stride + x] } }
                }
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)
                if let p = previous, p.count == luma.count {
                    var sum = 0
                    for i in luma.indices { sum += abs(Int(luma[i]) - Int(p[i])) }
                    result.append(Float(sum) / Float(luma.count * 255))
                } else {
                    result.append(0)
                }
                previous = luma
                if duration > 0 { progress?(min(1, t / duration)) }
            }
        }
        // value k describes the change from k-1 to k; shift so it describes the window [k, k+1)
        if result.count > 1 { result.removeFirst(); result.append(result.last ?? 0) }
        return result
    }
}
