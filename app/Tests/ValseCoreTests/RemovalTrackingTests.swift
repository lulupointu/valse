import Foundation
import Testing
@testable import ValseCore

/// AI remove ▸ Track object (AI-041) and camera tracking ▸ Custom box (AI-013) maths.
@Suite("Removal mask tracking")
struct RemovalTrackingTests {
    let strokes = [RemovalStroke(points: [Vec2(0.4, 0.5), Vec2(0.5, 0.5)], radius: 0.05)]

    @Test func boundsIncludeTheBrushRadius() throws {
        let b = try #require(RemovalTracking.bounds(strokes, aspect: 2))
        #expect(abs(b.x - 0.35) < 1e-9 && abs(b.width - 0.2) < 1e-9)
        #expect(abs(b.y - 0.4) < 1e-9 && abs(b.height - 0.2) < 1e-9)   // radius ×2 vertically (16:9-ish aspect 2)
        #expect(RemovalTracking.bounds([RemovalStroke(points: [Vec2(0.5, 0.5)], radius: 0.1, erase: true)], aspect: 1) == nil)
    }

    @Test func maskFollowsAndScalesWithTheBox() {
        let ref = NormRect(x: 0.35, y: 0.4, width: 0.2, height: 0.2)
        let moved = RemovalTracking.transform(strokes, from: ref, to: NormRect(x: 0.55, y: 0.3, width: 0.4, height: 0.2))
        // centre 0.45,0.5 → 0.75,0.4; x offsets double, radius doubles
        #expect(abs(moved[0].points[0].x - (0.75 - 0.1)) < 1e-9 && abs(moved[0].points[0].y - 0.4) < 1e-9)
        #expect(abs(moved[0].points[1].x - (0.75 + 0.1)) < 1e-9)
        #expect(abs(moved[0].radius - 0.1) < 1e-9)
        #expect(RemovalTracking.transform(strokes, from: ref, to: ref) == strokes)
    }

    @Test func boxInterpolatesAndHoldsAtTheEnds() throws {
        let s = [TrackSample(time: 1, box: NormRect(x: 0, y: 0, width: 0.2, height: 0.2)),
                 TrackSample(time: 2, box: NormRect(x: 0.4, y: 0.2, width: 0.2, height: 0.2))]
        #expect(RemovalTracking.box(at: 0, in: s) == s[0].box)
        #expect(RemovalTracking.box(at: 5, in: s) == s[1].box)
        let mid = try #require(RemovalTracking.box(at: 1.5, in: s))
        #expect(abs(mid.x - 0.2) < 1e-9 && abs(mid.y - 0.1) < 1e-9)
        #expect(RemovalTracking.box(at: 1, in: []) == nil)
    }

    @Test func customBoxSamplesUseDisplayCoordinates() {
        let t = [TrackSample(time: 0, box: NormRect(x: 0.1, y: 0.2, width: 0.2, height: 0.4))]
        let up = CameraLock.samples(fromTracked: t, rotation: 0)[0]
        #expect(abs(up.x - 0.2) < 1e-9 && abs(up.y - 0.4) < 1e-9 && abs(up.size - 0.4) < 1e-9)
        let rot = CameraLock.samples(fromTracked: t, rotation: 90)[0]
        #expect(abs(rot.x - 0.6) < 1e-9 && abs(rot.y - 0.2) < 1e-9 && abs(rot.size - 0.2) < 1e-9)
    }

    @Test func trackingInfoDecodesFromOldFiles() throws {
        let old = #"{"original":"\#(UUID().uuidString)","strokes":[]}"#
        let i = try JSONDecoder().decode(ObjectRemovalInfo.self, from: Data(old.utf8))
        #expect(i.tracking == nil)
        var o = CameraLockOptions(target: .custom)
        o.customBox = NormRect(x: 0, y: 0, width: 0.5, height: 0.5); o.customTime = 1
        #expect(try JSONDecoder().decode(CameraLockOptions.self, from: JSONEncoder().encode(o)) == o)
    }
}
