import Testing
@testable import ValseCore

@Suite struct KeyframeTests {
    @Test func linearAndHold() {
        var k = KeyframeTrack()
        k.set(.scalar(0), at: 0)
        k.set(.scalar(10), at: 2)
        #expect(k.value(at: 1) == .scalar(5))
        #expect(k.value(at: -1) == .scalar(0))
        #expect(k.value(at: 5) == .scalar(10))
        k.setEasing(.hold, at: 0)
        #expect(k.value(at: 1.99) == .scalar(0))
    }

    @Test func bezierEasingIsMonotonicAndBounded() {
        let e = Easing.easeInOut
        var prev = -1.0
        for i in 0...100 {
            let v = e.apply(Double(i) / 100)
            #expect(v >= prev - 1e-9)
            prev = v
        }
        #expect(abs(e.apply(0.5) - 0.5) < 1e-4)
        #expect(Easing.easeIn.apply(0.25) < 0.25)
        #expect(Easing.easeOut.apply(0.25) > 0.25)
    }

    @Test func vectorAndColorInterpolation() {
        let a = AnimValue.vec2(Vec2(0, 0)), b = AnimValue.vec2(Vec2(2, -2))
        #expect(a.lerp(b, 0.5) == .vec2(Vec2(1, -1)))
        let c = AnimValue.color(.black).lerp(.color(.white), 0.5)
        #expect(c == .color(RGBA(0.5, 0.5, 0.5, 1)))
    }

    @Test func clipPropertyKeyframesResolve() {
        var c = Clip(content: .solid(.red), start: 0, duration: 10)
        c.toggleKeyframe(.opacity, at: 0, tolerance: Time(0.01))
        c.setValue(.opacity, .scalar(1), at: 0)
        c.keyframes[ParamKey.opacity.raw]!.set(.scalar(0), at: 4)
        #expect(c.resolved(at: 2).opacity == 0.5)
        // editing with keyframes present adds a keyframe at the playhead
        c.setValue(.opacity, .scalar(0.2), at: 8)
        #expect(c.keyframes[ParamKey.opacity.raw]!.keyframes.count == 3)
        #expect(c.resolved(at: 8).opacity == 0.2)
        // toggling at an existing keyframe removes it
        c.toggleKeyframe(.opacity, at: 8, tolerance: Time(0.01))
        #expect(c.keyframes[ParamKey.opacity.raw]!.keyframes.count == 2)
    }

    @Test func effectParamsAreAnimatable() {
        var c = Clip(content: .solid(.red), start: 0, duration: 10)
        let fx = EffectInstance(typeID: "test.blur", params: ["radius": .scalar(0)])
        c.effects.append(fx)
        let key = ParamKey.effect(fx.id, "radius")
        #expect(key.effectParam?.1 == "radius")
        c.keyframes[key.raw] = KeyframeTrack([Keyframe(time: 0, value: .scalar(0)), Keyframe(time: 2, value: .scalar(20))])
        #expect(c.resolved(at: 1).effects[0].params["radius"] == .scalar(10))
    }
}
