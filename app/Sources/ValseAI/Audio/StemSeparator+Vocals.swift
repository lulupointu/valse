@preconcurrency import AVFoundation
import Foundation
import ValseCore
import ValseEngine

/// AU-009 (F3) "Isolate voice ▸ Music": the singing voice is HTDemucs' `vocals` stem; the accompaniment
/// (`demucs-novocals`) is the sum of every other stem, so keep + remove add back up to the original mix.
extension StemSeparator {
    public static let accompanimentKind = "demucs-novocals"

    public static func separateVocals(_ asset: MediaAsset, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let store = AudioStemStore.shared
        if isReady(asset, .vocals), store.readyStem(media: asset, kind: accompanimentKind) != nil { progress?(1); return }
        try await separate(asset) { progress?(0.95 * $0) }
        let parts = Stem.allCases.filter { $0 != .vocals }.compactMap { store.readyStem(media: asset, kind: $0.storeKind) }
        guard !parts.isEmpty else { throw AIToolError.noInput }
        let dst = store.stemURL(media: asset, kind: accompanimentKind)
        let tmp = store.directory.appendingPathComponent("tmp-\(UUID().uuidString).caf")
        do {
            try sum(parts, to: tmp)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: tmp, to: dst)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        progress?(1)
    }

    /// Sample-wise sum of same-format CAF stems (48 kHz stereo float, `convertToCAF`).
    static func sum(_ files: [URL], to dst: URL) throws {
        let ins = try files.map { try AVAudioFile(forReading: $0) }
        let fmt = ins[0].processingFormat
        let out = try AVAudioFile(forWriting: dst, settings: fmt.settings, commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
        let chunk: AVAudioFrameCount = 65_536
        let acc = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk)!
        let tmp = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk)!
        let length = ins.map(\.length).max() ?? 0
        var pos: AVAudioFramePosition = 0
        while pos < length {
            let n = AVAudioFrameCount(min(Int64(chunk), length - pos))
            acc.frameLength = n
            for c in 0..<Int(fmt.channelCount) { memset(acc.floatChannelData![c], 0, Int(n) * MemoryLayout<Float>.size) }
            for f in ins where f.framePosition < f.length {
                tmp.frameLength = 0
                try f.read(into: tmp, frameCount: n)
                let m = Int(tmp.frameLength)
                for c in 0..<Int(fmt.channelCount) {
                    let a = acc.floatChannelData![c], b = tmp.floatChannelData![min(c, Int(f.processingFormat.channelCount) - 1)]
                    for i in 0..<m { a[i] += b[i] }
                }
            }
            try out.write(from: acc)
            pos += AVAudioFramePosition(n)
        }
    }
}
