import Testing
import Foundation
import ValseCore
@testable import ValseEffects

/// Text engine content: registries are populated, ids unique, every key translated, glyph animation maths.
struct TextContentTests {
    /// TX-BUBBLE2: 63 presets (24 v1 + 39, 3 of them circles), unique ids, groups in the pill list, neon presets see-through with a neon
    /// outline, v1 shapes map onto styles (classic tails), grid order follows the groups.
    @Test func bubblePresetsV2() {
        let all = Registries.textBubbles.all
        #expect(all.count == 63 && BuiltinTextBubbles.legacy.count == 24 && BuiltinTextBubbles.added.count == 39)
        #expect(Set(all.map(\.id)).count == 63)
        #expect(all.filter { $0.style.family == .circle }.count == 3)
        #expect(all.allSatisfy { BuiltinTextBubbles.groups.contains($0.groupKey) })
        let order = all.map { BuiltinTextBubbles.groups.firstIndex(of: $0.groupKey)! }
        #expect(order == order.sorted())
        for d in all where d.groupKey == "bubble.group.neon" {
            #expect(d.style.outline?.neon != nil, "\(d.id) neon")
            if d.id != "valse.bubble.neonNightSign" { #expect(d.style.fill.a == 0, "\(d.id) transparent") }
        }
        let speech = Registries.textBubbles["valse.bubble.speechWhite"]!.style
        #expect(speech.family == .box && speech.cornerRadius == 0.5 && speech.tail == TextBubbleTail(side: .bottomLeft)
                && speech.outline == TextBubbleOutline(color: RGBA(hex: 0x141414), width: 0.07) && !speech.containsText)
        #expect(Registries.textBubbles["valse.bubble.thought"]!.style.tail?.kind == .dots)
        #expect(Registries.textBubbles["valse.bubble.cloud"]!.style.family == .cloud)
        #expect(Registries.textBubbles["valse.bubble.outlinePillDark"]!.previewBackdrop == .light)
        #expect(Registries.textBubbles["valse.bubble.comicShout"]!.style.containsText)
        // v1 ids and shapes unchanged
        for d in BuiltinTextBubbles.legacy { #expect(TextBubbleDescriptor.shape(of: d.style) == d.shape, "\(d.id)") }
    }

    /// Resolution and Customize edits: bubbleStyle ?? preset (with the legacy bubbleColor fill); an edit copies the
    /// style and clears bubbleColor; Edited = differs from the preset; Reset = bubbleStyle nil.
    @Test func bubbleResolutionAndEdits() {
        var t = TextContent(string: "Hi")
        #expect(t.resolvedBubble() == nil)
        t.editBubble { $0.fill = .red }
        #expect(t.bubbleStyle == nil)   // no bubble: no-op
        t.bubbleID = "valse.bubble.speechYellow"; t.bubbleColor = RGBA(0, 1, 0, 1)
        #expect(t.resolvedBubble()?.fill == RGBA(0, 1, 0, 1) && !t.isBubbleEdited)
        t.editBubble { $0.cornerRadius = 0.8 }
        #expect(t.bubbleColor == nil && t.bubbleStyle?.fill == RGBA(0, 1, 0, 1) && t.bubbleStyle?.cornerRadius == 0.8 && t.isBubbleEdited)
        t.bubbleStyle = Registries.textBubbles["valse.bubble.speechYellow"]!.style
        #expect(!t.isBubbleEdited)
        t.bubbleStyle = nil
        #expect(t.resolvedBubble() == Registries.textBubbles["valse.bubble.speechYellow"]!.style)
    }

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
        Registries.textStyles["valse.text.outline"]!.restyle(&t)
        #expect(t.string == "keep me" && t.fontSize == 0.1 && t.caption?.words.count == 2)
        #expect(t.color == .white && t.glow == nil && t.strokeWidth > 0 && t.styleID == "valse.text.outline")
    }

    @Test func templateMakesLocalizedSlots() {
        EffectsResources.register()
        let d = Registries.textTemplates["valse.template.lowerThird"]!
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

    // MARK: TX-BUBBLE2 round 3: a bubble never restyles the text

    /// A text effect (word art) keeps the clip's bubble (it used to rebuild the text without it).
    @Test func restyleKeepsTheBubble() {
        var t = TextContent(string: "Hi")
        t.pickBubble(Registries.textBubbles["valse.bubble.neonPinkPill"])
        t.editBubble { $0.fill = .white }
        let bubble = (t.bubbleID, t.bubbleStyle)
        BuiltinTextStyles.shadows[0].restyle(&t)
        #expect(t.bubbleID == bubble.0 && t.bubbleStyle == bubble.1 && t.bubbleStyle != nil)
        var legacy = TextContent(string: "Hi"); legacy.bubbleID = "valse.bubble.speechWhite"; legacy.bubbleColor = .red
        BuiltinTextStyles.outlines[0].restyle(&legacy)
        #expect(legacy.bubbleID == "valse.bubble.speechWhite" && legacy.bubbleColor == .red)
    }

    /// Owner (round 3): picking, switching, resetting or removing a bubble never changes the text's look (font, colour,
    /// effects, neon, case, run colours); only the bubble fields and the flat Background (turned off under a bubble).
    @Test func bubblePickNeverChangesTheTextLook() throws {
        var t = TextContent(string: "Hello", fontSize: 0.08, color: RGBA(hex: 0x00FF00), alignment: .left)
        t.fontName = "Georgia"; t.textCase = .upper; t.italic = true
        t.neon = TextNeonStyle(color: .red, intensity: 0.8, glowSize: 0.3, thickness: 0.05)
        t.runs = [TextRun(TextSpan(0, 2), TextRunStyle(color: .blue))]
        t.backgroundColor = RGBA(0, 0, 1, 1)
        func look(_ x: TextContent) -> TextContent {
            var y = x; y.bubbleID = nil; y.bubbleStyle = nil; y.bubbleColor = nil; y.backgroundColor = .clear; return y
        }
        let before = look(t)
        for id in ["valse.bubble.neonCyanBox", "valse.bubble.comicShout", "valse.bubble.speechWhite", "valse.bubble.neonFlicker"] {
            let d = try #require(Registries.textBubbles[id])
            t.pickBubble(d)
            #expect(t.bubbleID == id && t.bubbleStyle == nil && t.backgroundColor.a == 0)
            #expect(look(t) == before, "\(id)")
            t.editBubble { $0.padding = Vec2(0.5, 0.5) }
            t.resetBubbleToPreset()
            #expect(t.bubbleStyle == nil && look(t) == before, "\(id) reset")
        }
        t.pickBubble(nil)
        #expect(t.bubbleID == nil && t.resolvedBubble() == nil && look(t) == before)
        // a saved bubble: drawn as is, not based on a preset, text untouched
        var saved = TextBubbleStyle.blank(.cloud); saved.fill = .red
        t.applySavedBubble(saved)
        #expect(t.bubbleID == nil && t.resolvedBubble() == saved && look(t) == before)
    }

    /// Projects saved by 0.6 / 0.7 carry a "bubblePrior" text look (removed pairing): decoded and ignored.
    @Test func oldBubblePriorDecodesAndIsIgnored() throws {
        var t = TextContent(string: "Old"); t.color = .red; t.bubbleID = "valse.bubble.neonPinkPill"
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(t)) as? [String: Any])
        var prior = json; prior.removeValue(forKey: "bubbleID"); prior["color"] = json["color"]
        json["bubblePrior"] = prior
        let data = try JSONSerialization.data(withJSONObject: json)
        let back = try JSONDecoder().decode(TextContent.self, from: data)
        #expect(back == t)
        let again = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(back)) as? [String: Any])
        #expect(again["bubblePrior"] == nil)
    }
}
