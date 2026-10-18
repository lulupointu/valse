import CoreGraphics
import Foundation
import Testing
import MontageCore
import MontageEffects
@testable import MontageEngine
import MontageTestSupport

/// W5 KF-012: Lottie parsing, keyframe interpolation, vector rendering, animated stickers through the compositor.
@Suite struct LottieTests {
    static func url(_ name: String) throws -> URL {
        try #require(EffectsResources.bundle.url(forResource: "lottie-\(name)", withExtension: "json"))
    }
    static func render(_ name: String, frame: Double, side: Int = 128) throws -> Bitmap {
        let a = try LottieAnimation(url: try url(name))
        return Bitmap(try #require(LottieRenderer.image(a, frame: frame, width: side, height: side)))
    }
    /// Fraction of pixels with alpha > 0.5.
    static func coverage(_ b: Bitmap) -> Double {
        var n = 0
        for i in stride(from: 3, to: b.pixels.count, by: 4) where b.pixels[i] > 128 { n += 1 }
        return Double(n) / Double(b.width * b.height)
    }

    @Test func everyBundledStickerParsesAndAnimates() throws {
        #expect(BuiltinStickers.animated.count >= 8)
        for s in BuiltinStickers.animated {
            guard case .lottie(let r, let b) = s.source else { Issue.record("\(s.id) not lottie"); continue }
            let a = try LottieAnimation(url: try #require(b().url(forResource: r, withExtension: nil)))
            #expect(a.width == 512 && a.frameRate == 30 && a.duration > 0.5)
            let f0 = try #require(LottieRenderer.image(a, frame: a.inPoint, width: 96, height: 96))
            let f1 = try #require(LottieRenderer.image(a, frame: a.inPoint + (a.outPoint - a.inPoint) * 0.37, width: 96, height: 96))
            let b0 = Bitmap(f0), b1 = Bitmap(f1)
            let diff = zip(b0.pixels, b1.pixels).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
            #expect(diff > 2000, "\(s.id) moves")
            #expect(Self.coverage(b1) > 0.01, "\(s.id) draws something")
        }
        // MONTAGE_SNAPSHOT_DIR=… : contact sheet of every sticker at 5 points of its loop, to look at
        if let dir = ProcessInfo.processInfo.environment["MONTAGE_SNAPSHOT_DIR"] {
            let cell = 96, n = BuiltinStickers.animated.count
            let ctx = CGContext(data: nil, width: cell * 5, height: cell * n, bitsPerComponent: 8, bytesPerRow: cell * 5 * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(gray: 0.25, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: cell * 5, height: cell * n))
            for (row, s) in BuiltinStickers.animated.enumerated() {
                guard case .lottie(let r, let b) = s.source, let u = b().url(forResource: r, withExtension: nil),
                      let a = try? LottieAnimation(url: u) else { continue }
                for k in 0..<5 {
                    let f = a.inPoint + (a.outPoint - a.inPoint) * Double(k) / 5
                    if let img = LottieRenderer.image(a, frame: f, width: cell, height: cell) {
                        ctx.draw(img, in: CGRect(x: k * cell, y: (n - 1 - row) * cell, width: cell, height: cell))
                    }
                }
            }
            Bitmap(ctx.makeImage()!).writePNG(URL(fileURLWithPath: dir).appendingPathComponent("w5-lottie-stickers.png"))
        }
    }

    @Test func keyframesHoldEaseAndLoop() throws {
        let json = """
        {"w":100,"h":100,"fr":10,"ip":0,"op":20,"layers":[{"ty":4,"ind":1,"ip":0,"op":20,"st":0,
         "ks":{"p":{"a":1,"k":[{"t":0,"s":[0,0],"o":{"x":[0],"y":[0]},"i":{"x":[1],"y":[1]}},{"t":10,"s":[100,50],"h":1},{"t":15,"s":[0,0]}]}},
         "shapes":[{"ty":"gr","it":[{"ty":"rc","p":{"a":0,"k":[0,0]},"s":{"a":0,"k":[20,20]},"r":{"a":0,"k":0}},
                                   {"ty":"fl","c":{"a":0,"k":[1,0,0,1]},"o":{"a":0,"k":100}},{"ty":"tr"}]}]}]}
        """
        let a = try LottieAnimation(data: Data(json.utf8))
        let p = a.layers[0].transform.position!
        #expect(p.point(5) == CGPoint(x: 50, y: 25))            // linear bezier (0,0)-(1,1)
        #expect(p.point(12) == CGPoint(x: 100, y: 50))           // hold
        #expect(p.point(30) == CGPoint(x: 0, y: 0))
        #expect(abs(a.frame(at: 2.5) - 5) < 1e-9)                // 25 frames → loops at 20
        // the red square follows the position: at frame 10 it sits at (100, 50) → right edge, middle
        let img = Bitmap(try #require(LottieRenderer.image(a, frame: 10, width: 100, height: 100)))
        #expect(img.pixel(95, 50).r > 0.9 && img.pixel(50, 50).a < 0.1)
    }

    @Test func shapesFillsStrokesTrimsAndGradients() throws {
        // checkmark: the disc pops in (scale 0 → 100), then the tick is drawn by a trim path
        let start = try Self.render("checkmark", frame: 0), done = try Self.render("checkmark", frame: 40)
        #expect(Self.coverage(start) < 0.02)
        #expect(done[0.5, 0.15].g > 0.6 && done[0.5, 0.15].r < 0.4)   // green disc
        let tickMid = try Self.render("checkmark", frame: 19)
        // the tick's start (lower-left) exists mid-draw, its end (upper-right) only once finished
        let endPt = (x: 0.67, y: 0.385)   // tick end (95, -65) around the centre of the 512 comp
        #expect(done[endPt.x, endPt.y].luma > 0.85)
        #expect(tickMid[endPt.x, endPt.y].luma < 0.85)
        // heartbeat: the heart grows on the beat
        #expect(Self.coverage(try Self.render("heartbeat", frame: 8)) > Self.coverage(try Self.render("heartbeat", frame: 0)) + 0.02)
        #expect(try Self.render("heartbeat", frame: 0)[0.5, 0.55].r > 0.8)
        // sparkle: radial gradient, near-white centre to orange tips
        let sp = try Self.render("sparkle", frame: 15)
        #expect(sp[0.5, 0.5].b > 0.7 && sp[0.5, 0.5].r > 0.9)
    }

    @Test func animatedStickerPlaysInTheCompositor() throws {
        let id = "montage.sticker.anim.bounceBall"
        func frame(_ t: Double) -> Bitmap? {
            let canvas = Size2(160, 90)
            let side = canvas.height * 0.35
            let l = LayerDescription(clipID: ClipID(), trackID: TrackID(), source: .sticker(id: id), sourceSize: Size2(side, side),
                                     transform: Transform(scale: Vec2(2, 2)), opacity: 1, blendMode: .normal, crop: CropRect(),
                                     mask: nil, effects: [], animations: [], localTime: Time(t))
            let f = FrameDescription(time: Time(t), canvasSize: canvas, background: .black, items: [.layer(l)])
            return PresetPreviewRenderer.render(f, width: 160, height: 90).map(Bitmap.init)
        }
        let a = try #require(frame(0)), b = try #require(frame(0.5)), c = try #require(frame(1.0))
        // ball high at 0 s and 1 s (30-frame loop at 30 fps), low at 0.5 s
        func orangeY(_ bmp: Bitmap) -> Int? { (0..<bmp.height).first { y in (0..<bmp.width).contains { x in let p = bmp.pixel(x, y); return p.r > 0.8 && p.g < 0.7 && p.g > 0.3 } } }
        let ya = try #require(orangeY(a)), yb = try #require(orangeY(b)), yc = try #require(orangeY(c))
        #expect(yb > ya + 5)
        #expect(abs(yc - ya) <= 1)
        #expect(TextMetrics.stickerSize(id, side: 31.5) == Size2(31.5, 31.5))
    }
}
