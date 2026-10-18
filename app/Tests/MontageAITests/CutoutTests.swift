import Testing
import Foundation
import CoreGraphics
@preconcurrency import AVFoundation
@testable import MontageAI
import MontageCore
import MontageEngine
import MontageTestSupport

/// AI cutout (CK-002/003/004): mattes from Vision on generated frames, through the compositor's matte input.
@Suite(.serialized) struct CutoutTests {
    static let gray = RGBA(0.55, 0.55, 0.55), red = RGBA(0.9, 0.1, 0.1), blue = RGBA(0.1, 0.2, 0.9)

    /// Box centre of `.movingBox` at `seconds` (1 s clip, 30 fps).
    static func boxCenter(_ seconds: Double) -> (Double, Double) {
        let f = (seconds * 30).rounded(.down)
        return (f / 29 * 0.75 + 0.125, 0.5)
    }

    func matteFrame(_ url: URL, at s: Double) async throws -> Bitmap {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        let (img, _) = try await gen.image(at: CMTime(seconds: s, preferredTimescale: 600))
        return Bitmap(img)
    }

    @Test func subjectMatteFollowsMovingObject() async throws {
        let url = try await TestMedia.video(.movingBox(Self.gray, Self.red), seconds: 1)
        let asset = try await MediaProbe.probe(url)
        try? FileManager.default.removeItem(at: MatteStore.shared.matteVideoURL(media: asset, kind: "subject"))
        try await MatteGenerator.generate(asset, mode: .subject)
        let m = try #require(MatteStore.shared.readyMatteVideo(media: asset, kind: "subject"))
        for s in [0.2, 0.5, 0.8] {
            let f = try await matteFrame(m, at: s)
            let (cx, cy) = Self.boxCenter(s)
            #expect(f[cx, cy].r > 0.6, "inside box at \(s): \(f[cx, cy])")
            #expect(f[0.05, 0.1].r < 0.3, "background at \(s): \(f[0.05, 0.1])")
        }
    }

    @Test func customSelectionKeepsPaintedObjectOnly() throws {
        // two objects: red square left, green disc right — paint on the red one only
        let w = 320, h = 180
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.55, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: 30, y: 50, width: 80, height: 80))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.8, blue: 0.2, alpha: 1)); ctx.fillEllipse(in: CGRect(x: 200, y: 50, width: 80, height: 80))
        let img = ctx.makeImage()!
        let all = Bitmap(try MatteGenerator.still(img, mode: .subject))
        // CG origin is bottom-left; both objects are vertically centred so y = 0.5 works either way
        let leftX = 70.0 / 320, rightX = 240.0 / 320
        #expect(all[leftX, 0.5].r > 0.5 && all[rightX, 0.5].r > 0.5, "subject mode keeps both")
        let sel = CutoutSelection(time: .zero, strokes: [BrushStroke(points: [Vec2(leftX, 0.5)], radius: 0.02)])
        let one = Bitmap(try MatteGenerator.still(img, mode: .custom(sel)))
        #expect(one[leftX, 0.5].r > 0.5)
        #expect(one[rightX, 0.5].r < 0.3)
        // erasing the same object leaves nothing
        let none = CutoutSelection(time: .zero, strokes: [BrushStroke(points: [Vec2(leftX, 0.5)], radius: 0.02),
                                                          BrushStroke(points: [Vec2(leftX, 0.5)], radius: 0.02, erase: true)])
        #expect(Bitmap(try MatteGenerator.still(img, mode: .custom(none)))[leftX, 0.5].r < 0.3)
    }

    @Test func personMatteVideoCoversEveryFrame() async throws {
        let url = try await TestMedia.video(.movingBox(Self.gray, Self.red), seconds: 1)
        let asset = try await MediaProbe.probe(url)
        try? FileManager.default.removeItem(at: MatteStore.shared.matteVideoURL(media: asset, kind: "person"))
        let log = ProgressLog()
        try await MatteGenerator.generate(asset, mode: .person) { log.add($0) }
        let m = try #require(MatteStore.shared.readyMatteVideo(media: asset, kind: "person"))
        let info = try await MediaInfo.probe(m)
        #expect(abs(info.duration - 1) < 0.1)
        #expect(log.last == 1)
        // no person in a moving box: the matte is (almost) empty
        #expect(try await matteFrame(m, at: 0.5)[0.5, 0.5].r < 0.3)
    }

    /// The subject matte composited by the renderer: the object stays, the clip's background disappears and the
    /// track below shows through (preview and export use the same compositor).
    @Test func cutoutCompositesOverLowerTrack() async throws {
        var p = TestProject()
        _ = try await p.addVideo(.solid(Self.blue), seconds: 1)
        let url = try await TestMedia.video(.movingBox(Self.gray, Self.red), seconds: 1)
        let top = try await p.addMedia(url, at: .zero, target: .newTrack)
        let asset = p.project.asset(p[top].mediaID!)!
        try await MatteGenerator.generate(asset, mode: .subject)
        p[top].matte = ClipMatte(kind: CutoutMode.subject.kind)
        let img = try await p.render(at: 0.5)
        let (cx, cy) = Self.boxCenter(0.5)
        #expect(img[cx, cy].r > 0.6 && img[cx, cy].b < 0.4, "object kept: \(img[cx, cy])")
        #expect(img[0.05, 0.1].b > 0.6 && img[0.05, 0.1].r < 0.4, "background removed: \(img[0.05, 0.1])")
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ v: Double) { lock.withLock { values.append(v) } }
    var last: Double? { lock.withLock { values.last } }
}
