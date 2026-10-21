import Testing
import MontageCore
import MontageEffects

@Suite struct RegistryTests {
    @Test func idsAreUniqueAndNamespaced() {
        let ids = (Registries.effects.all.map(\.id) + Registries.transitions.all.map(\.id) + Registries.animations.all.map(\.id))
            // other tests register extensions / user LUTs / generated AI looks (ColorLooks: "ai.look.*") concurrently
            .filter { !$0.hasPrefix("test.") && !$0.hasPrefix("user.") && !$0.hasPrefix("ai.look.") }
        #expect(Set(ids).count == ids.count)
        let foreign = ids.filter { !$0.hasPrefix("montage.") }
        #expect(foreign.isEmpty, "not namespaced: \(foreign)")
    }

    @Test func instancesCarryDefaultsAndPackInOrder() {
        let d = Registries.effects["montage.adjust.basic"]!
        let inst = d.makeInstance()
        #expect(inst.params.count == d.params.count)
        var v = inst.params; v["contrast"] = .scalar(0.5)
        let packed = d.packParams(v)
        #expect(packed.count == d.params.count)
        #expect(packed[1] == 0.5)
    }

    @Test func animationsChangeStateMonotonically() {
        let fade = Registries.animations["montage.anim.in.fade"]!
        var s0 = AnimatedLayerState(transform: Transform(), opacity: 1), s1 = s0
        fade.apply(0, &s0); fade.apply(1, &s1)
        #expect(s0.opacity == 0 && s1.opacity == 1)
    }

    @Test func registeringAnExtensionWorks() {
        let d = EffectDescriptor(id: "test.identity", category: .effect, nameKey: "x", groupKey: "y",
                                 shader: "float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) { return src.sample(s, uv); }")
        Registries.effects.register(d)
        #expect(Registries.effects["test.identity"] != nil)
        #expect(Registries.effects(in: .effect).contains { $0.id == "test.identity" })
    }
}
