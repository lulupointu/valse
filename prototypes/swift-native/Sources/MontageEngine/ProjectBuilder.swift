import AVFoundation

public struct BuiltProject {
    public let composition: AVMutableComposition
    public let videoComposition: AVVideoComposition
    public let duration: CMTime
}

/// Builds the benchmark project: 4 × 4K HEVC clips stacked as layers + audio of clip A.
/// The production equivalent would translate the project model (tracks/clips/keyframes) into an
/// AVComposition + a render-graph-carrying instruction list.
public enum ProjectBuilder {
    public static func fourLayer(mediaDir: URL) async throws -> BuiltProject {
        // [bench harness] MONTAGE_LAYERS=8 -> a..d twice (8-layer stress test); separate assets = separate decoders
        let nLayers = Int(ProcessInfo.processInfo.environment["MONTAGE_LAYERS"] ?? "") ?? 4
        let names = (0..<nLayers).map { ["a", "b", "c", "d"][$0 % 4] }
        let comp = AVMutableComposition()
        var duration = CMTime.positiveInfinity
        var assets: [AVURLAsset] = []
        for n in names {
            let a = AVURLAsset(url: mediaDir.appendingPathComponent("\(n).mp4"),
                               options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            assets.append(a)
            duration = CMTimeMinimum(duration, try await a.load(.duration))
        }
        let range = CMTimeRange(start: .zero, duration: duration)
        var trackIDs: [CMPersistentTrackID] = []
        for a in assets {
            guard let src = try await a.loadTracks(withMediaType: .video).first,
                  let dst = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw NSError(domain: "Montage", code: 10, userInfo: [NSLocalizedDescriptionKey: "no video track"])
            }
            try dst.insertTimeRange(range, of: src, at: .zero)
            trackIDs.append(dst.trackID)
        }
        if let srcA = try await assets[0].loadTracks(withMediaType: .audio).first,
           let dstA = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try dstA.insertTimeRange(range, of: srcA, at: .zero)
        }
        var layers = [
            LayerSpec(trackID: trackIDs[0], center: [0.5, 0.5], scale: 1.0, opacity: 0.8, saturation: 1.2, brightness: 0.0),
            LayerSpec(trackID: trackIDs[1], center: [0.3, 0.3], scale: 0.55, opacity: 0.8, saturation: 0.6, brightness: 0.05),
            LayerSpec(trackID: trackIDs[2], center: [0.7, 0.65], scale: 0.5, opacity: 0.8, saturation: 1.5, brightness: -0.05),
            LayerSpec(trackID: trackIDs[3], center: [0.5, 0.5], scale: 0.35, opacity: 0.8, saturation: 0.0, brightness: 0.1),
        ]
        for i in 4..<trackIDs.count {  // [bench harness] layers 5-8: smaller, offset
            var l = layers[i - 4]
            l.trackID = trackIDs[i]
            l.scale *= 0.6
            l.center = [0.2 + 0.6 * Float((i - 4) % 2), 0.25 + 0.5 * Float((i - 4) / 2)]
            layers.append(l)
        }
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = MetalCompositor.self
        vc.frameDuration = CMTime(value: 1, timescale: 30)
        vc.renderSize = CGSize(width: 1920, height: 1080)
        vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        vc.instructions = [MontageInstruction(timeRange: range, layers: layers)]
        return BuiltProject(composition: comp, videoComposition: vc, duration: duration)
    }
}
