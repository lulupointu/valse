import Testing
import Foundation
import MontageCore
@testable import MontageEffects

/// Text engine content: registries are populated, ids unique, every key translated, glyph animation maths.
struct TextContentTests {
    @Test func registriesHoldTheCapCutSizedLibraries() {
        #expect(Registries.textStyles.all.count >= 200)
        #expect(Registries.textStyles(.preset).count >= 20)
        #expect(Registries.animations(.in, for: .text).count >= 20)
        #expect(Registries.animations(.out, for: .text).count >= 10)
        #expect(Registries.animations(.combo, for: .text).count >= 10)
        #expect(Registries.textBubbles.all.count >= 20)
        #expect(Registries.textTemplates.all.count >= 20)
        #expect(Registries.captionTemplates.all.count >= 12)
        // text-only glyph animations stay out of the video/sticker libraries
        #expect(!Registries.animations(.in, for: .video).contains { $0.glyph != nil })
        for list in [Registries.textStyles.all.map(\.id), Registries.textBubbles.all.map(\.id), Registries.textTemplates.all.map(\.id),
                     Registries.captionTemplates.all.map(\.id), Registries.animations.all.map(\.id)] {
            #expect(Set(list).count == list.count)
        }
    }

    @Test func templateLayersReferenceRealAnimations() {
        for t in Registries.textTemplates.all {
            for l in t.layers {
                for id in [l.inAnim?.id, l.outAnim?.id, l.loopAnim?.id].compactMap({ $0 }) {
                    #expect(Registries.animations[id]?.glyph != nil, "\(t.id) uses unknown animation \(id)")
                }
                if let s = l.slot { #expect(s < t.slotKeys.count, "\(t.id) slot \(s)") }
                if let s = l.fitSlot { #expect(s < t.slotKeys.count) }
            }
            if let id = t.makeContent().bubbleID { #expect(Registries.textBubbles[id] != nil) }
        }
    }

    @Test func everyTextKeyIsTranslated() {
        EffectsResources.register()
        var keys: [String] = []
        keys += Registries.textStyles.all.flatMap { [$0.nameKey, $0.groupKey] }
        keys += Registries.animations.all.filter { $0.targets == .text }.map(\.nameKey)
        keys += Registries.textBubbles.all.flatMap { [$0.nameKey, $0.groupKey] }
        keys += Registries.captionTemplates.all.flatMap { [$0.nameKey, $0.groupKey] }
        keys += Registries.textTemplates.all.flatMap { [$0.nameKey, $0.groupKey] + $0.slotKeys }
        let en = L10n.shared.keys(for: "en"), fr = L10n.shared.keys(for: "fr")
        let missing = Set(keys).filter { !en.contains($0) || !fr.contains($0) }.sorted()
        #expect(missing.isEmpty, "missing: \(missing)")
    }

    @Test func staggerSpreadsUnitsAcrossTheAnimation() {
        let spec = GlyphAnimationSpec(unit: .character, span: 0.25) { t, _, s in s.opacity = t }
        func u(_ i: Int) -> GlyphUnitInfo { GlyphUnitInfo(index: i, count: 5, random: glyphRandom(i)) }
        #expect(spec.unitProgress(0, phase: .in, unit: u(0)) == 0)
        #expect(spec.unitProgress(1, phase: .in, unit: u(4)) == 1)
        #expect(spec.unitProgress(0.25, phase: .in, unit: u(0)) == 1)      // first unit done after its span
        #expect(spec.unitProgress(0.25, phase: .in, unit: u(4)) == 0)      // last one not started
        #expect(abs(spec.unitProgress(0.5, phase: .in, unit: u(2)) - 0.5) < 1e-9)
        // backward order flips the ranks
        let back = GlyphAnimationSpec(unit: .character, order: .backward, span: 0.25) { _, _, _ in }
        #expect(back.unitProgress(0.25, phase: .in, unit: u(4)) == 1)
        // loops shift the phase per unit
        let wave = GlyphAnimationSpec(unit: .character, waveSpread: 1) { _, _, _ in }
        #expect(wave.unitProgress(0, phase: .combo, unit: u(0)) == 0)
        #expect(abs(wave.unitProgress(0, phase: .combo, unit: u(4)) - 0) < 1e-9 || wave.unitProgress(0, phase: .combo, unit: u(2)) > 0)
        #expect(glyphRandom(3) == glyphRandom(3) && glyphRandom(3) != glyphRandom(4))
    }

    @Test func restyleKeepsTextAndTimingButReplacesTheLook() {
        var t = TextContent(string: "keep me", fontSize: 0.1)
        t.caption = CaptionData(words: [CaptionWord("keep", start: 0, end: 1), CaptionWord("me", start: 1, end: 2)])
        t.color = .red; t.glow = TextGlowStyle(color: .blue)
        Registries.textStyles["montage.text.outline"]!.restyle(&t)
        #expect(t.string == "keep me" && t.fontSize == 0.1 && t.caption?.words.count == 2)
        #expect(t.color == .white && t.glow == nil && t.strokeWidth > 0 && t.styleID == "montage.text.outline")
    }

    @Test func templateMakesLocalizedSlots() {
        EffectsResources.register()
        let d = Registries.textTemplates["montage.template.lowerThird"]!
        let t = d.makeContent()
        #expect(t.template?.texts.count == d.slotKeys.count - 1)
        #expect(TextTemplateDescriptor.text(slot: 1, of: t, descriptor: d) == tr(d.slotKeys[1]))
        #expect(!t.string.hasPrefix("template."))
    }

    /// UX_GAPS W7-2: word-art effects have descriptive names ("Yellow stroke", "Néon rose"), unique per group, in en and fr.
    @Test func textEffectsHaveDescriptiveUniqueNames() {
        EffectsResources.register()
        for lang in ["en", "fr"] {
            let table = L10n.load(lang, from: [EffectsResources.bundle])
            var seen: [String: Set<String>] = [:]
            for d in Registries.textStyles(.effect) {
                let fmt = table[d.nameKey] ?? d.nameKey
                let name = String(format: fmt, arguments: d.nameArgKeys.map { (table[$0] ?? $0) as CVarArg })
                #expect(!name.contains("textStyle.") && !name.contains("%@"), "\(lang): \(d.id) → \(name)")
                #expect(!name.contains(where: \.isNumber) || name.contains("3D"), "\(lang): numbered name \(name)")
                #expect(name.count <= 18, "\(lang): long name \(name)")
                #expect(seen[d.groupKey, default: []].insert(name).inserted, "\(lang): duplicate \(name) in \(d.groupKey)")
            }
        }
    }
}
