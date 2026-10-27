import Testing
import Foundation
@testable import ValseAI
import ValseCore
import ValseEngine
import ValseTestSupport

/// Face cover stickers (ST-006): faces are tracked into per-face tracks, and a sticker clip per face follows it.
@Suite(.serialized) struct FaceStickerTests {
    @Test func associatorKeepsIdentitiesAndDropsSingleDetections() {
        var a = FaceTracker.Associator()
        for i in 0..<10 {
            let t = Double(i) * 0.1
            var boxes = [NormRect(x: 0.1 + Double(i) * 0.01, y: 0.3, width: 0.1, height: 0.15),    // face A moving right
                         NormRect(x: 0.7, y: 0.2 + Double(i) * 0.01, width: 0.12, height: 0.18)]  // face B moving down
            if i == 4 { boxes.removeFirst() }                                                        // A missed once
            if i == 6 { boxes.append(NormRect(x: 0.45, y: 0.8, width: 0.05, height: 0.05)) }        // one-off false positive
            a.update(time: t, boxes: boxes)
        }
        let tracks = a.tracks()
        #expect(tracks.count == 2)
        #expect(tracks.allSatisfy { $0.count >= 9 })
        let a0 = tracks.first { $0[0].box.x < 0.5 }!
        #expect(a0.last!.box.x > a0.first!.box.x + 0.05)
    }

    @Test func faceStickerFollowsTheWalkingFace() async throws {
        var p = TestProject(canvas: Size2(640, 360))
        let id = try await p.addMedia(try await FaceCoverTests.faceVideo())
        let asset = p.project.media[0]
        let clip = p[id]
        let tracks = try await FaceTracker.analyze(asset, range: clip.sourceRange)
        #expect(tracks.count == 1, "\(tracks.map(\.count))")
        try FaceStickers.apply(tracks, sticker: FaceStickers.circleID, to: id, in: &p.project)
        let covers = FaceStickers.covers(of: id, in: p.project.timeline)
        #expect(covers.count == 1)
        let s = try #require(covers.first)
        #expect(s.linkedTo == id && s.content == .sticker(id: FaceStickers.circleID))
        let pos = try #require(s.keyframes[ParamKey.position.raw]?.keyframes)
        #expect(pos.count >= 5)
        #expect(pos.last!.value.vec2!.x > pos.first!.value.vec2!.x + 0.1)          // walks right
        // the white circle covers the face in the render
        let img = try await p.render(at: 0.5)
        let face = tracks[0].min { abs($0.time - 0.5) < abs($1.time - 0.5) }!.box
        #expect(img[face.center.x, face.center.y].luma > 0.9)
        FaceStickers.remove(from: id, in: &p.project)
        #expect(FaceStickers.covers(of: id, in: p.project.timeline).isEmpty)
        #expect(p.project.timeline.tracks.count == 1)
    }
}
