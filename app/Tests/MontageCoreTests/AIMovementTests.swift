import Testing
import Foundation
@testable import MontageCore

/// AI movement (AI-025) keyframe maths + camera tracking hand box (AI-013).
@Suite struct AIMovementTests {
    let source = Size2(1920, 1080), canvas = Size2(1920, 1080)

    /// One 10 s video clip + a music clip with beats at 1, 2, 3 s.
    func project(beats: [Double] = [1, 2, 3]) -> (Project, ClipID) {
        var (p, ids) = Fx.project(mainClips: 1, seconds: 10)
        let a = Fx.audio("m")
        p.media.append(a)
        var m = TimelineOps.makeClip(for: a, at: .zero)
        m.duration = Time(10)
        m.beats = beats.map { Time($0) }
        let tid = TimelineOps.addTrack(.audio, to: &p.timeline)
        p.timeline.tracks[p.timeline.trackIndex(tid)!].clips = [m]
        return (p, ids[0])
    }

    func scale(_ c: Clip, _ t: Double) -> Double { c.keyframes[ParamKey.scale.raw]!.value(at: Time(t))!.vec2!.x }

    @Test func beatsAreCollectedInClipLocalTime() {
        var (p, id) = project()
        #expect(AIMovement.beats(for: p.timeline.clip(id)!, in: p.timeline) == [1, 2, 3])
        // a clip starting at 1.5 s sees the 2 s and 3 s beats at 0.5 s and 1.5 s
        p.timeline[clip: id]!.start = Time(1.5)
        p.timeline[clip: id]!.duration = Time(3)
        let b = AIMovement.beats(for: p.timeline.clip(id)!, in: p.timeline)
        #expect(b.count == 2 && abs(b[0] - 0.5) < 1e-6 && abs(b[1] - 1.5) < 1e-6)
    }

    @Test func beatSyncedPunchZoomsLandOnBeats() {
        let (p, id) = project()
        var c = p.timeline.clip(id)!
        let beats = AIMovement.beats(for: c, in: p.timeline)
        AIMovement.apply(AIMovementOptions(preset: .zoom, strength: 1, syncToBeats: true),
                         subject: [SubjectSample(time: 0, x: 0.5, y: 0.5)], beats: beats, to: &c, source: source, canvas: canvas)
        let k = c.keyframes[ParamKey.scale.raw]!
        for b in beats {
            #expect(k.keyframes.contains { abs($0.time.seconds - b) < 1e-6 }, "keyframe on beat \(b)")
            #expect(scale(c, b) > scale(c, b - 0.05) + 0.1, "punch on beat \(b)")
            #expect(scale(c, b) > scale(c, b + 0.6), "relaxes after beat \(b)")
        }
        #expect(c.aiMovement?.preset == .zoom)
        // without beat sync: one smooth zoom-in
        var d = p.timeline.clip(id)!
        AIMovement.apply(AIMovementOptions(preset: .zoom, strength: 1, syncToBeats: false),
                         subject: [SubjectSample(time: 0, x: 0.5, y: 0.5)], beats: beats, to: &d, source: source, canvas: canvas)
        #expect(d.keyframes[ParamKey.scale.raw]!.keyframes.count == 2 && scale(d, 9.9) > scale(d, 0.1))
    }

    @Test func shakeIsBoundedAndDeterministic() {
        let (p, id) = project()
        var a = p.timeline.clip(id)!, b = a
        let o = AIMovementOptions(preset: .shake, strength: 1, syncToBeats: false)
        AIMovement.apply(o, subject: [], beats: [], to: &a, source: source, canvas: canvas)
        AIMovement.apply(o, subject: [], beats: [], to: &b, source: source, canvas: canvas)
        #expect(a == b)
        let pos = a.keyframes[ParamKey.position.raw]!.keyframes.map { $0.value.vec2! }
        let rot = a.keyframes[ParamKey.rotation.raw]!.keyframes.map { $0.value.scalar! }
        #expect(pos.count >= 100, "≈ 12 keys/s")
        #expect(pos.allSatisfy { abs($0.x) < 0.04 && abs($0.y) < 0.04 })
        #expect(rot.allSatisfy { abs($0) <= 2.0 } && rot.contains { abs($0) > 0.3 }, "small but visible rotation")
        #expect(Set(pos.map(\.x)).count > 20, "noise, not constant")
    }

    @Test func zoomMovesTowardsTheSubject() {
        let (p, id) = project(beats: [])
        var c = p.timeline.clip(id)!
        AIMovement.apply(AIMovementOptions(preset: .zoom, strength: 1, syncToBeats: true),
                         subject: [SubjectSample(time: 0, x: 0.8, y: 0.3)], beats: [], to: &c, source: source, canvas: canvas)
        let k = c.keyframes[ParamKey.position.raw]!
        let start = k.value(at: .zero)!.vec2!, end = k.value(at: Time(10))!.vec2!
        #expect(abs(start.x) < 1e-6 && abs(start.y) < 1e-6)
        #expect(end.x < -0.05, "subject on the right → frame moves left")
        #expect(end.y > 0.02, "subject near the top → frame moves down")
        // the frame keeps covering the canvas: |offset| ≤ (scale − 1) / 2
        let s = scale(c, 10)
        #expect(abs(end.x) <= (s - 1) / 2 + 1e-9 && abs(end.y) <= (s - 1) / 2 + 1e-9)
    }

    @Test func dynamicAndSoftProduceMoves() {
        let (p, id) = project()
        for preset in [AIMovementOptions.Preset.dynamic, .soft] {
            var c = p.timeline.clip(id)!
            AIMovement.apply(AIMovementOptions(preset: preset), subject: [SubjectSample(time: 0, x: 0.4, y: 0.5)],
                             beats: [1, 2, 3], to: &c, source: source, canvas: canvas)
            let k = c.keyframes[ParamKey.scale.raw]!
            #expect(k.keyframes.count >= 2, "\(preset)")
            #expect(Set(k.keyframes.map { $0.value.vec2!.x }).count >= 2, "\(preset) zooms")
            #expect(c.keyframes[ParamKey.rotation.raw] == nil)
        }
        var c = p.timeline.clip(id)!
        AIMovement.apply(AIMovementOptions(preset: .dynamic, syncToBeats: true), subject: [], beats: [1, 2, 3], to: &c, source: source, canvas: canvas)
        let times = c.keyframes[ParamKey.scale.raw]!.keyframes.map { $0.time.seconds }
        #expect([1.0, 2, 3].allSatisfy { b in times.contains { abs($0 - b) < 1e-6 } }, "direction changes on beats")
    }

    @Test func excludesReframeAndCameraTrackingAndRemoves() {
        let (p, id) = project()
        var c = p.timeline.clip(id)!
        c.cameraLock = CameraLockOptions()
        c.reframe = ReframeOptions()
        AIMovement.apply(AIMovementOptions(), subject: [], beats: [], to: &c, source: source, canvas: canvas)
        #expect(c.cameraLock == nil && c.reframe == nil && c.aiMovement != nil)
        var r = c
        ReframePath.apply([SubjectSample(time: 0, x: 0.5, y: 0.5)], to: &r, source: source, canvas: Size2(1080, 1920))
        #expect(r.aiMovement == nil)
        var l = c
        CameraLock.apply([LockSample(time: 0, x: 0.5, y: 0.5, size: 0.3), LockSample(time: 1, x: 0.6, y: 0.5, size: 0.3)],
                         to: &l, source: source, canvas: canvas, options: CameraLockOptions())
        #expect(l.aiMovement == nil)
        AIMovement.remove(&c)
        #expect(c.aiMovement == nil && c.keyframes.isEmpty && c.transform.scale == .one)
    }

    @Test func handBoxFromJoints() {
        // Vision coords (origin bottom-left): joints spanning x 0.6…0.7, y 0.2…0.4 → centre (0.65, 0.7) top-left origin
        let pts: [(x: Double, y: Double, confidence: Double)] = [(0.6, 0.2, 0.9), (0.7, 0.4, 0.8), (0.65, 0.3, 0.9), (0.62, 0.35, 0.7),
                                                                 (0.1, 0.9, 0.05)]   // low-confidence outlier ignored
        let b = try! #require(CameraLock.handBox(pts))
        #expect(abs(b.x - 0.65) < 1e-9 && abs(b.y - 0.7) < 1e-9)
        #expect(abs(b.size - 0.2 * 1.3) < 1e-9)
        #expect(CameraLock.handBox(Array(pts.prefix(3))) == nil, "needs ≥ 4 confident joints")
    }
}
