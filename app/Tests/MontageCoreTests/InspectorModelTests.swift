import Testing
import Foundation
@testable import MontageCore

/// Model logic behind the inspector (W3): group keyframes, smooth speed curves + presets, canvas evaluation.
@Suite struct InspectorModelTests {
    let tol = Time(seconds: 1.0 / 60)

    func clip() -> Clip { Clip(content: .media(MediaID()), start: 10, duration: 4) }

    // MARK: Keyframes

    @Test func groupToggleAddsAndRemovesEveryMember() {
        var c = clip()
        c.transform.scale = Vec2(1.5, 1.5)
        c.toggleKeyframes(ParamKey.transformGroup, at: 1, tolerance: tol)
        for k in ParamKey.transformGroup { #expect(c.hasKeyframes(k)) }
        #expect(c.keyframes[ParamKey.scale.raw]?.keyframes.first?.value == .vec2(Vec2(1.5, 1.5)))
        #expect(c.isOnKeyframe(ParamKey.transformGroup, at: 1, tolerance: tol))
        c.toggleKeyframes(ParamKey.transformGroup, at: 1, tolerance: tol)
        #expect(!c.hasKeyframes(ParamKey.transformGroup))
        #expect(c.keyframes.isEmpty)
    }

    @Test func groupToggleRemovesWhenAnyMemberIsOnKeyframe() {
        var c = clip()
        c.addKeyframe(.rotation, at: 2)
        c.toggleKeyframes(ParamKey.transformGroup, at: 2, tolerance: tol)
        #expect(!c.hasKeyframes(.rotation))
    }

    @Test func prevNextUseUnionOfMembers() {
        var c = clip()
        c.addKeyframe(.position, at: 0.5)
        c.addKeyframe(.scale, at: 1.5)
        c.addKeyframe(.rotation, at: 3)
        let g = ParamKey.transformGroup
        #expect(c.keyframeTimes(g) == [Time(0.5), Time(1.5), Time(3)])
        #expect(c.previousKeyframe(g, before: 1.5, tolerance: tol) == Time(0.5))
        #expect(c.nextKeyframe(g, after: 1.5, tolerance: tol) == Time(3))
        #expect(c.previousKeyframe(g, before: 0.5, tolerance: tol) == nil)
        #expect(c.nextKeyframe(g, after: 3, tolerance: tol) == nil)
    }

    @Test func modifyValueKeepsOtherComponentAndFollowsCapCutSemantics() {
        var c = clip()
        c.modifyValue(.position, at: 1) { $0 = $0.with(component: 0, 0.25) }
        #expect(c.transform.position == Vec2(0.25, 0))            // no keyframes → static edit
        c.addKeyframe(.position, at: 0)
        c.modifyValue(.position, at: 2) { $0 = $0.with(component: 1, -0.1) }
        #expect(c.keyframes[ParamKey.position.raw]?.keyframes.count == 2)  // keyframed → new keyframe at playhead
        #expect(c.value(.position, at: 2) == .vec2(Vec2(0.25, -0.1)))
    }

    @Test func cropAndMaskRoundnessAreAnimatable() {
        var c = clip()
        c.mask = Mask(shape: .rectangle)
        c.keyframes[ParamKey.cropLeft.raw] = KeyframeTrack([Keyframe(time: 0, value: .scalar(0)), Keyframe(time: 2, value: .scalar(0.2))])
        c.keyframes[ParamKey.maskRoundness.raw] = KeyframeTrack([Keyframe(time: 0, value: .scalar(0)), Keyframe(time: 2, value: .scalar(1))])
        let r = c.resolved(at: 1)
        #expect(abs(r.crop.left - 0.1) < 1e-9)
        #expect(abs(r.mask!.roundness - 0.5) < 1e-9)
    }

    @Test func effectParamKeysListEveryParam() {
        var c = clip()
        let e = EffectInstance(typeID: "x", params: ["a": .scalar(1), "b": .scalar(2)])
        c.effects = [e]
        #expect(c.effectParamKeys(e.id) == [ParamKey.effect(e.id, "a"), ParamKey.effect(e.id, "b")])
    }

    // MARK: Speed curves

    @Test func smoothCurveIntegralMatchesNumericIntegration() {
        for preset in SpeedCurvePreset.all {
            let c = preset.curve
            var acc = 0.0
            let n = 20_000
            for i in 0..<n { acc += c.value(at: (Double(i) + 0.5) / Double(n)) / Double(n) }
            #expect(abs(c.integral(to: 1) - acc) < 1e-4, "preset \(preset.id)")
            var part = 0.0
            let m = Int(0.37 * Double(n))
            for i in 0..<m { part += c.value(at: (Double(i) + 0.5) / Double(n)) / Double(n) }
            #expect(abs(c.integral(to: Double(m) / Double(n)) - part) < 1e-4)
        }
    }

    @Test func smoothCurveStaysWithinBeatRange() {
        let c = SpeedCurvePreset.montage.curve
        let lo = c.points.map(\.v).min()!, hi = c.points.map(\.v).max()!
        for i in 0...1000 {
            let v = c.value(at: Double(i) / 1000)
            #expect(v >= lo - 1e-9 && v <= hi + 1e-9)
        }
        // passes through every beat
        for p in c.points { #expect(abs(c.value(at: p.x) - p.v) < 1e-9) }
    }

    @Test func presetsAreValidAndPreserveSourceExtentThroughSetSpeed() throws {
        #expect(SpeedCurvePreset.all.count == 7)
        var p = Project()
        let a = MediaAsset(name: "v", kind: .video, url: URL(fileURLWithPath: "/tmp/v.mp4"), duration: 20, pixelSize: .hd1080,
                           frameRate: .fps30, hasVideo: true, hasAudio: true, contentHash: "h")
        p.media = [a]
        var c = TimelineOps.makeClip(for: a); c.duration = 10
        try TimelineOps.insert(c, into: &p)
        let source = p.timeline.clip(c.id)!.sourceDuration
        for preset in SpeedCurvePreset.all {
            try TimelineOps.setSpeed(c.id, .curve(preset.curve), in: &p.timeline)
            let now = p.timeline.clip(c.id)!
            #expect(abs((now.sourceDuration - source).seconds) < 0.01, "preset \(preset.id)")
            #expect(now.speed == .curve(preset.curve))
            #expect(TimelineOps.validate(p.timeline).isEmpty)
        }
    }

    @Test func curveEditingOps() {
        var c = SpeedCurvePreset.customized.curve
        #expect(c.points.count == 5)
        let i = c.insertPoint(at: 0.6)
        #expect(i == 3 && c.points.count == 6 && c.presetID == nil)
        #expect(c.insertPoint(at: 0.61) == nil)                 // too close to an existing beat
        c.movePoint(3, x: 0.9, v: 50)                            // clamped below the next beat, speed ≤ 10×
        #expect(c.points[3].x < c.points[4].x && c.points[3].v == 10)
        c.movePoint(0, x: 0.3, v: 0.01)                          // first beat stays at x = 0
        #expect(c.points[0].x == 0 && c.points[0].v == 0.1)
        c.removePoint(at: 0)                                     // ends can't be removed
        #expect(c.points.count == 6)
        c.removePoint(at: 3)
        #expect(c.points.count == 5)
        while c.points.count < SpeedCurve.maxPoints { _ = c.insertPoint(at: Double.random(in: 0.05...0.95)) }
        #expect(c.insertPoint(at: 0.5) == nil || c.points.count <= SpeedCurve.maxPoints)
    }

    @Test func legacyCurveJSONDecodesAsLinear() throws {
        let json = #"{"points":[{"x":0,"v":1},{"x":1,"v":3}]}"#
        let c = try JSONDecoder().decode(SpeedCurve.self, from: Data(json.utf8))
        #expect(c.interpolation == nil && !c.isSmooth)
        #expect(abs(c.integral(to: 1) - 2) < 1e-12)
    }

    // MARK: Canvas

    func canvasProject(_ canvas: CanvasBackground?) -> (Project, ClipID) {
        var p = Project(settings: ProjectSettings(canvasSize: Size2(1920, 1080)))
        let a = MediaAsset(name: "v", kind: .video, url: URL(fileURLWithPath: "/tmp/p.mp4"), duration: 10,
                           pixelSize: Size2(1080, 1920), frameRate: .fps30, hasVideo: true, hasAudio: false, contentHash: "p")
        p.media = [a]
        var c = TimelineOps.makeClip(for: a)
        c.canvas = canvas
        try! TimelineOps.insert(c, into: &p)
        return (p, c.id)
    }

    @Test func colorCanvasSetsFrameBackground() {
        let (p, _) = canvasProject(.color(RGBA(1, 0, 0)))
        let f = FrameEvaluator.evaluate(p, at: 1)
        #expect(f.background == RGBA(1, 0, 0))
        #expect(f.items.count == 1)
    }

    @Test func blurCanvasAddsFilledBlurredCopyBelowClip() {
        let (p, id) = canvasProject(.blur(level: 3))
        let f = FrameEvaluator.evaluate(p, at: 1)
        #expect(f.items.count == 2)
        guard case .layer(let bg) = f.items[0], case .layer(let fg) = f.items[1] else { Issue.record("layers"); return }
        #expect(bg.clipID == id && fg.clipID == id)
        // portrait 1080×1920 in 1920×1080: fit = 0.5625, fill = 1.777… → scale ≈ 3.16
        #expect(abs(bg.transform.scale.x - (1920.0 / 1080) / (1080.0 / 1920)) < 1e-9)
        #expect(bg.effects.filter { $0.typeID == CanvasBackground.blurEffectID }.count == 2)
        #expect(fg.effects.isEmpty)
        // stable across frames (instance ids are fixed)
        #expect(FrameEvaluator.evaluate(p, at: 1) == f)
    }

    @Test func styleCanvasAddsFullCanvasPatternLayer() {
        let (p, _) = canvasProject(.style(id: "montage.canvas.dots"))
        let f = FrameEvaluator.evaluate(p, at: 1)
        guard case .layer(let bg) = f.items[0] else { Issue.record("layer"); return }
        #expect(bg.source == .solid(.black) && bg.sourceSize == Size2(1920, 1080))
        #expect(bg.effects.map(\.typeID) == ["montage.canvas.dots"])
    }

    @Test func canvasRoundTripsAndOldClipsDecodeWithoutIt() throws {
        let (p, id) = canvasProject(.blur(level: 2))
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Project.self, from: data)
        #expect(back.timeline.clip(id)?.canvas == .blur(level: 2))
        var raw = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(Clip(content: .solid(.red), start: 0, duration: 1))) as! [String: Any]
        raw.removeValue(forKey: "canvas")
        let old = try JSONDecoder().decode(Clip.self, from: try JSONSerialization.data(withJSONObject: raw))
        #expect(old.canvas == nil)
    }
}
