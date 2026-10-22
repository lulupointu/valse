// Measure AVAssetReader decode speed to 16 kHz mono Float32.
import AVFoundation
import Foundation

func decode(_ path: String) async throws -> (Int, Double) {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return (0, 0) }
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
    out.alwaysCopiesSampleData = false
    reader.add(out); reader.startReading()
    var n = 0
    while let sb = out.copyNextSampleBuffer() { n += CMSampleBufferGetNumSamples(sb) }
    return (n, Double(n) / 16000)
}
let files = Array(CommandLine.arguments.dropFirst())
let t0 = Date()
var total = 0.0
await withTaskGroup(of: (String, Double, Double).self) { g in
    for f in files { g.addTask { let a = Date(); let (_, d) = (try? await decode(f)) ?? (0, 0); return (f, d, Date().timeIntervalSince(a)) } }
    for await (f, d, t) in g { total += d; print(String(format: "%@: %.1fs audio in %.3fs (%.0fx)", (f as NSString).lastPathComponent, d, t, d / t)) }
}
let wall = Date().timeIntervalSince(t0)
print(String(format: "parallel total %.0fs audio in %.2fs wall (%.0fx)", total, wall, total / wall))
