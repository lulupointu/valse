import Testing
import Foundation
import CoreGraphics
import MontageCore
import MontageEngine
import MontageTestSupport

/// Chroma key, AI matte input, stabilization (W6) through the real compositor.
@Suite(.serialized) struct LayerFeatureTests {
    @Test func chromaKeyRemovesKeyColourAndKeepsOthers() async throws {
        var p = TestProject()
        try await p.addVideo(.solid(.blue))
        let o = try await p.addVideo(.split(RGBA(0, 1, 0), .red), target: .newTrack)
        let before = try await p.render(at: 0.5)
        #expect(before[0.25, 0.5].isClose(to: RGBA(0, 1, 0)))
        p[o].chromaKey = ChromaKey(color: RGBA(0, 1, 0))
        let img = try await p.render(at: 0.5)
        #expect(img[0.25, 0.5].isClose(to: .blue), "\(img[0.25, 0.5])")     // keyed → base shows through
        #expect(img[0.75, 0.5].isClose(to: .red))                          // other colours untouched
    }

    @Test func chromaSpillSuppressionNeutralisesGreenCast() async throws {
        var p = TestProject()
        let id = try await p.addVideo(.solid(RGBA(0.8, 0.95, 0.8)))
        p[id].chromaKey = ChromaKey(color: RGBA(0, 1, 0), spill: 0)
        let raw = try await p.render(at: 0.5)[0.5, 0.5]
        #expect(raw.g - raw.r > 0.08)
        p[id].chromaKey = ChromaKey(color: RGBA(0, 1, 0), spill: 1)
        let fixed = try await p.render(at: 0.5)[0.5, 0.5]
        #expect(abs(fixed.g - fixed.r) < 0.05, "\(fixed)")
        #expect(fixed.luma > 0.7)
    }

    @Test func chromaShadowKeepsDarkenedKeyPartiallyOpaque() async throws {
        var p = TestProject(background: .white)
        let id = try await p.addVideo(.solid(RGBA(0, 0.4, 0)))         // shadowed green screen
        p[id].chromaKey = ChromaKey(color: RGBA(0, 1, 0), intensity: 0.5, shadow: 0)
        let none = try await p.render(at: 0.5)[0.5, 0.5].luma
        p[id].chromaKey = ChromaKey(color: RGBA(0, 1, 0), intensity: 0.5, shadow: 1)
        let kept = try await p.render(at: 0.5)[0.5, 0.5].luma
        #expect(none > 0.9)
        #expect(kept < none - 0.15)
    }

    @Test func videoMatteCutsOutLayer() async throws {
        var p = TestProject(background: .blue)
        let id = try await p.addVideo(.solid(.red), seconds: 1)
        let asset = p.project.media[0]
        // matte: left half opaque, right half transparent, for every source frame
        let w = MatteVideoWriter.self
        let writer = try w.init(media: asset, kind: "test-person", size: CGSize(width: 160, height: 90))
        let img = Self.halfImage(width: 160, height: 90)
        for f in 0..<30 { try await writer.append(img, at: FrameRate.fps30.time(ofFrame: Int64(f))) }
        try await writer.finish()
        p[id].matte = ClipMatte(kind: "test-person")
        let out = try await p.render(at: 0.5)
        #expect(out[0.2, 0.5].isClose(to: .red), "\(out[0.2, 0.5])")
        #expect(out[0.8, 0.5].isClose(to: .blue), "\(out[0.8, 0.5])")
        p[id].matte = ClipMatte(kind: "test-person", inverted: true)
        let inv = try await p.render(at: 0.5)
        #expect(inv[0.2, 0.5].isClose(to: .blue))
        #expect(inv[0.8, 0.5].isClose(to: .red))
    }

    @Test func stillMatteCutsOutImage() async throws {
        var p = TestProject(background: .blue)
        let id = try await p.addImage(.solid(.red), size: CGSize(width: 320, height: 180))
        let asset = p.project.media[0]
        MatteStore.shared.setStill(Self.halfImage(width: 64, height: 36), media: asset, kind: "still-test")
        p[id].matte = ClipMatte(kind: "still-test")
        let out = try await p.render(at: 0.5)
        #expect(out[0.2, 0.5].isClose(to: .red))
        #expect(out[0.8, 0.5].isClose(to: .blue))
    }

    @Test func stabilizationAnalysisRecoversJitterAndSteadiesThePicture() async throws {
        // a box whose position jitters ±6 % per frame (camera shake), on black
        let jitter: [Double] = (0..<45).map { i in [0.0, 0.05, -0.04, 0.06, -0.05, 0.02, -0.06, 0.04][i % 8] }
        let url = TestMedia.directory.appendingPathComponent("shake-v2.mp4")
        if !FileManager.default.fileExists(atPath: url.path) {
            try await SyntheticMedia.writeVideo(to: url, size: CGSize(width: 320, height: 180), seconds: 1.5, fps: 30,
                                                codec: .h264, audioHz: nil) { f, _ in
                SyntheticMedia.Paint(background: (0, 0, 0),
                                     box: (CGRect(x: 0.4 + jitter[f], y: 0.35, width: 0.2, height: 0.3), (255, 255, 255)))
            }
        }
        var p = TestProject()
        let id = try await p.addMedia(url)
        let asset = p.project.media[0]
        let path = try await StabilizationStore.analyze(url)
        try StabilizationStore.shared.store(path, for: asset)
        // the measured camera path follows the jitter (frame-to-frame deltas)
        for i in 1..<8 {
            #expect(abs((path.x[i] - path.x[i - 1]) - (jitter[i] - jitter[i - 1])) < 0.01, "i=\(i)")
        }
        func boxX(_ img: Bitmap) -> Double {
            var sx = 0.0, n = 0.0
            for x in 0..<img.width { let v = img.pixel(x, img.height / 2).luma; sx += Double(x) * v; n += v }
            return sx / max(n, 1e-6) / Double(img.width)
        }
        var raw: [Double] = [], steady: [Double] = []
        for f in 10..<18 { raw.append(boxX(try await p.render(at: Double(f) / 30))) }
        p[id].stabilization = Stabilization(level: .mostStable)
        for f in 10..<18 { steady.append(boxX(try await p.render(at: Double(f) / 30))) }
        func spread(_ v: [Double]) -> Double { (v.max() ?? 0) - (v.min() ?? 0) }
        #expect(spread(steady) < spread(raw) * 0.4, "raw \(spread(raw)) steady \(spread(steady))")
    }

    static func halfImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        return ctx.makeImage()!
    }
}
