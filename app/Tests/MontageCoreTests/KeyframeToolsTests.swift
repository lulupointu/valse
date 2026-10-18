import Foundation
import Testing
@testable import MontageCore

/// W5 keyframe tools: preset curves, speed graph, copy/paste, reset, per-segment curves, motion path, text props.
@Suite struct KeyframeToolsTests {
    @Test func presetCurvesMatchCapCutAndHitTheirEnds() {
        let ids = EasingPreset.all.map(\.id)
        #expect(Array(ids.prefix(14)) == ["none", "linear", "easeIn", "quadIn", "cubicIn", "easeOut", "quadOut", "cubicOut",
                                         "ease", "quadEase", "cubicEase", "circularEase", "reboundIn", "reboundOut"])
        #expect(Set(ids).count == ids.count)
        for p in EasingPreset.all where p.easing != .hold {
            #expect(abs(p.easing.apply(0)) < 1e-9 && abs(p.easing.apply(1) - 1) < 1e-9, "\(p.id)")
        }
        let reboundOut = EasingPreset.all.first { $0.id == "reboundOut" }!.easing
        #expect((0..<100).map { reboundOut.apply(Double($0) / 100) }.max()! > 1.02)   // overshoots
        #expect(Easing.bounceOut.apply(0.5) > 0.7 && Easing.elasticOut.apply(0.1) > 1)
        #expect(EasingPreset.preset(for: .easeInOut)?.id == "ease")
    }

    @Test func speedGraphIsTheDerivative() {
        let lin = Easing.linear.speedSamples(33)
        #expect(lin.allSatisfy { abs($0 - 1) < 1e-6 })
        let easeIn = Easing.easeIn.speedSamples(33)
        #expect(easeIn.first! < 0.3 && easeIn.last! > 1.5)
        #expect(Easing.hold.controlPoints == nil && Easing.easeOut.controlPoints! == (0, 0, 0.58, 1))
    }

    @Test func newEasingsPersist() throws {
        let t = KeyframeTrack([Keyframe(time: 0, value: .scalar(0), easing: .bounceOut), Keyframe(time: 1, value: .scalar(1), easing: .elasticOut)])
        #expect(try JSONDecoder().decode(KeyframeTrack.self, from: JSONEncoder().encode(t)) == t)
    }

    static func animatedClip() -> Clip {
        var c = Clip(content: .solid(.red), start: 10, duration: 4)
        c.toggleKeyframes(ParamKey.transformGroup, at: 0, tolerance: Time(ticks: 1))
        c.setValue(.position, .vec2(Vec2(0.4, 0)), at: 2)
        c.setValue(.scale, .vec2(Vec2(2, 2)), at: 2)
        c.setValue(.opacity, .scalar(0.5), at: 0)   // not keyframed: static
        return c
    }

    @Test func copyAndPasteKeyframesAtAnotherTime() {
        let src = Self.animatedClip()
        let cb = src.copyKeyframes(at: 2, tolerance: Time(ticks: 1000))
        #expect(Set(cb.entries.map(\.key)) == [ParamKey.position.raw, ParamKey.scale.raw])
        var dst = Clip(content: .solid(.blue), start: 0, duration: 3)
        let n = dst.pasteKeyframes(cb, at: 1)
        #expect(n == 2)
        #expect(dst.value(.position, at: 1)?.vec2 == Vec2(0.4, 0))
        #expect(dst.keyframes[ParamKey.scale.raw]?.keyframes.map(\.time) == [Time(1)])
        // effect keys only paste onto the same instance
        var withFX = src
        let fx = EffectInstance(typeID: "x", params: ["amount": .scalar(0.2)])
        withFX.effects = [fx]
        withFX.toggleKeyframe(.effect(fx.id, "amount"), at: 2, tolerance: Time(ticks: 1))
        var other = Clip(content: .solid(.blue), start: 0, duration: 3)
        #expect(other.pasteKeyframes(withFX.copyKeyframes(at: 2, tolerance: Time(ticks: 1000)), at: 0) == 2)
        #expect(other.keyframes.keys.allSatisfy { !$0.hasPrefix("effect.") })
    }

    @Test func resetKeepsTheValuesShownAtThePlayhead() {
        var c = Self.animatedClip()
        let shown = c.resolved(at: 1)
        c.resetKeyframes(keepingValuesAt: 1)
        #expect(c.keyframes.isEmpty)
        #expect(c.transform.position == shown.transform.position && c.transform.scale == shown.transform.scale)
    }

    @Test func perSegmentAndAllSegmentCurves() {
        var c = Self.animatedClip()
        c.setValue(.position, .vec2(Vec2(0, 0.3)), at: 4)
        let key = ParamKey.position.raw
        c.setEasing(.easeIn, key: key, at: 0, tolerance: Time(ticks: 10))
        #expect(c.keyframes[key]!.keyframes.map(\.easing) == [.easeIn, .linear, .linear])
        // ease-in: the first half of the segment covers less than half the distance
        #expect(c.value(.position, at: 1)!.vec2!.x < 0.2)
        c.setEasing(.easeOut, key: key, at: 0, tolerance: Time(ticks: 10), allSegments: true)
        #expect(c.keyframes[key]!.keyframes.allSatisfy { $0.easing == .easeOut })
        #expect(c.easing(key, at: 2, tolerance: Time(ticks: 10)) == .easeOut)
    }

    @Test func motionPathFollowsTheEasedPosition() throws {
        var c = Self.animatedClip()
        let canvas = Size2(1000, 500)
        c.setEasing(.easeIn, key: ParamKey.position.raw, at: 0, tolerance: Time(ticks: 10))
        let path = try #require(MotionPath.path(for: c, canvas: canvas, samplesPerSegment: 10))
        #expect(path.keyframes == [Vec2(500, 250), Vec2(900, 250)])
        #expect(path.points.first == Vec2(500, 250) && path.points.last == Vec2(900, 250))
        #expect(path.points.count == 11)
        #expect(path.points[5].x < 700)   // eased: slow start
        #expect(MotionPath.path(for: Clip(content: .solid(.red), start: 0, duration: 1), canvas: canvas) == nil)
    }

    @Test func textStylePropertiesAreKeyframeable() {
        var c = Clip(content: .text(TextContent(string: "Hi")), start: 0, duration: 2)
        c.toggleKeyframe(.textSize, at: 0, tolerance: Time(ticks: 1))
        c.setValue(.textSize, .scalar(0.2), at: 2)
        c.toggleKeyframe(.textStrokeColor, at: 0, tolerance: Time(ticks: 1))
        c.setValue(.textStrokeColor, .color(.white), at: 2)
        let mid = c.resolved(at: 1)
        guard case .text(let t) = mid.content else { Issue.record("not text"); return }
        #expect(abs(t.fontSize - 0.13) < 1e-9)
        #expect(t.strokeColor.r > 0.4 && t.strokeColor.r < 0.6)
        for p in AnimatableProperties.all { #expect(p.nameKey.hasPrefix("prop.")) }
    }
}
