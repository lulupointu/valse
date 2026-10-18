import Testing
import AVFoundation
@testable import MontageEngine

let mediaDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../../../bench/media").standardized

@Test func werBasics() {
    #expect(WER.compute(reference: "Bonjour et bienvenue", hypothesis: "bonjour, et bienvenue !") == 0)
    #expect(abs(WER.compute(reference: "a b c d", hypothesis: "a x c") - 0.5) < 1e-9)
    #expect(WER.normalize("l’endroit") == ["l'", "endroit"])
}

/// Render test: 0.5 s export through the Metal compositor, then pixel-check a decoded frame.
@Test func exportRendersComposedFrames() async throws {
    let project = try await ProjectBuilder.fourLayer(mediaDir: mediaDir)
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("montage-test.mp4")
    try await Exporter.export(project: project, range: CMTimeRange(start: .zero, duration: CMTime(value: 15, timescale: 30)), to: out)
    let asset = AVURLAsset(url: out)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    #expect(try await track.load(.naturalSize) == CGSize(width: 1920, height: 1080))
    let gen = AVAssetImageGenerator(asset: asset)
    gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
    let (img, _) = try await gen.image(at: CMTime(value: 7, timescale: 30))
    // Centre pixel lies under the grayscale layer (saturation 0): R≈G≈B, not black.
    let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(img, in: CGRect(x: -960, y: -540, width: 1920, height: 1080))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    let (r, g, b) = (Int(p[0]), Int(p[1]), Int(p[2]))
    #expect(r + g + b > 30)
    #expect(Swift.abs(r - g) < 40 && Swift.abs(g - b) < 40)
}

@Test func timeStretchPreservesPitch() async throws {
    let pcm = try await AudioStretch.loadPCM(url: mediaDir.appendingPathComponent("a.mp4"), seconds: 3)
    let c = try AudioStretch.check(input: pcm, rate: 1.5)
    #expect(abs(c.pitchRatio - 1) < 0.03)
    #expect(abs(c.consumedRatio - 1.5) < 0.1)
}
