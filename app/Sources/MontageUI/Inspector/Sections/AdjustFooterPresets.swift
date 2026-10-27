import SwiftUI
import Perception
import MontageCore
import MontageEffects

// Adjust tab footer `[Apply to all] [Save as preset]` and "My presets" (UX.md §5 Footer, §5.1 Adjust, [32]).
// What belongs to the Adjust tab: adjustment-category effects (Basic, HSL, Curves, Color wheel, LUT, white balance,
// auto adjust…) plus the Adjust ▸ Mask. Filters and special effects are not part of it.

@MainActor
enum AdjustTools {
    nonisolated static func isAdjust(_ e: EffectInstance) -> Bool { Registries.effects[e.typeID]?.category == .adjustment }

    /// The clip's Adjust-tab grading (a copy of each instance, without keyframes).
    nonisolated static func grading(of c: Clip) -> [EffectInstance] { c.effects.filter(isAdjust) }

    /// Whether the clip has anything to apply / save.
    nonisolated static func hasGrading(_ c: Clip?) -> Bool { c.map { !grading(of: $0).isEmpty || $0.adjustMask != nil } ?? false }

    /// Replaces `c`'s Adjust-tab grading with fresh copies of `effects` (new instance ids, so keyframes never alias).
    nonisolated static func replaceGrading(_ c: inout Clip, with effects: [EffectInstance], mask: Mask?) {
        for e in c.effects where isAdjust(e) { c.clearKeyframes(c.effectParamKeys(e.id)) }
        c.effects.removeAll(where: isAdjust)
        let copies = effects.map { e -> EffectInstance in var n = e; n.id = EffectInstanceID(); return n }
        c.effects.insert(contentsOf: copies, at: 0)
        c.clearKeyframes(ParamKey.adjustMaskGroup)
        c.adjustMask = mask
    }

    /// Clips that can take a grade: video / image clips (any visual track, not locked), the source excluded.
    nonisolated static func gradeTargets(_ p: Project, excluding id: ClipID) -> [ClipID] {
        p.timeline.tracks.filter { $0.kind.isVisual && !$0.isLocked }.flatMap(\.clips).filter { c in
            guard c.id != id, let m = c.mediaID, let a = p.asset(m) else { return false }
            return a.kind != .audio
        }.map(\.id)
    }

    /// Footer "Apply to all": the selected clip's whole Adjust-tab grade on every video / image clip, one undo step.
    static func applyToAll(_ ctx: InspectorContext) {
        guard let clip = ctx.clip else { return }
        let fx = grading(of: clip.resolved(at: ctx.localTime)), mask = clip.adjustMask
        let targets = gradeTargets(ctx.store.project, excluding: clip.id)
        guard !targets.isEmpty else { return }
        ctx.store.perform(Edit("cmd.adjust.applyAll") { p in
            for id in targets { if var c = p.timeline.clip(id) { replaceGrading(&c, with: fx, mask: mask); p.timeline[clip: id] = c } }
        })
        ctx.store.showToast(tr("toast.appliedToAll"))
    }

    /// Footer "Save as preset": stores the grade under the next free "Preset N" name.
    static func saveAsPreset(_ ctx: InspectorContext) {
        guard let clip = ctx.clip, hasGrading(clip) else { return }
        let p = AdjustPresets.shared.add(effects: grading(of: clip.resolved(at: ctx.localTime)), mask: clip.adjustMask)
        ctx.store.showToast(tr("toast.presetSaved", p.name))
    }

    static func apply(_ preset: AdjustPreset, _ ctx: InspectorContext) {
        guard let id = ctx.clip?.id else { return }
        ctx.store.performInspector(UpdateClip(id, nameKey: "cmd.adjust.preset") { replaceGrading(&$0, with: preset.effects, mask: preset.mask) })
    }
}

/// A saved Adjust-tab grade ("My presets").
struct AdjustPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var effects: [EffectInstance]
    var mask: Mask?
}

/// User adjustment presets, persisted in UserDefaults (UI tests get a throw-away store).
@MainActor @Perceptible
final class AdjustPresets {
    static let shared = AdjustPresets(defaults: TestAnchors.isEnabled ? testDefaults() : .standard)
    static func testDefaults() -> UserDefaults {
        AppDefaults.suite("montage.uitest.adjustPresets")   // per process in UI tests (AppDefaults)
    }
    static let defaultsKey = "montage.inspector.adjustPresets"
    private(set) var all: [AdjustPreset]
    @PerceptionIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        all = (defaults.data(forKey: Self.defaultsKey)).flatMap { try? JSONDecoder().decode([AdjustPreset].self, from: $0) } ?? []
    }

    /// Next "Preset N" not in use.
    func nextName() -> String {
        var n = all.count + 1
        while all.contains(where: { $0.name == tr("adjust.preset.name", n) }) { n += 1 }
        return tr("adjust.preset.name", n)
    }

    @discardableResult
    func add(effects: [EffectInstance], mask: Mask?) -> AdjustPreset {
        let p = AdjustPreset(name: nextName(), effects: effects, mask: mask)
        all.append(p); save()
        return p
    }

    func remove(_ id: UUID) { all.removeAll { $0.id == id }; save() }

    func rename(_ id: UUID, to name: String) {
        guard let i = all.firstIndex(where: { $0.id == id }), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        all[i].name = name; save()
    }

    private func save() { defaults.set(try? JSONEncoder().encode(all), forKey: Self.defaultsKey) }
}

/// Sticky footer of the Adjust tab: `[Apply to all]` (secondary) `[Save as preset]` (accent).
struct AdjustFooter: View {
    let ctx: InspectorContext
    var body: some View {
        WithPerceptionTracking {
            let has = AdjustTools.hasGrading(ctx.clip)
            HStack(spacing: 8) {
                PillButton(title: tr("inspector.applyToAll"), enabled: has) { AdjustTools.applyToAll(ctx) }.testID("adjust.applyAll")
                PillButton(title: tr("inspector.saveAsPreset"), accent: true, enabled: has) { AdjustTools.saveAsPreset(ctx) }.testID("adjust.savePreset")
            }
        }
    }
}

/// Adjust ▸ Basic ▸ My presets: one chip per saved grade (click = apply, right-click = delete). Hidden when empty.
struct AdjustPresetsSection: View {
    let ctx: InspectorContext
    @State private var presets = AdjustPresets.shared
    var body: some View {
        WithPerceptionTracking {
            FlowChips(items: presets.all) { p in
                Button { AdjustTools.apply(p, ctx) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 10))
                        Text(verbatim: p.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    }
                    .foregroundStyle(Theme.textPrimary).padding(.horizontal, 10).frame(height: 24)
                    .background(Theme.buttonSecondary, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(tr("adjust.preset.applyHelp"))
                .contextMenu { Button(tr("adjust.preset.delete")) { presets.remove(p.id) } }
                .testID("adjust.preset.\(presets.all.firstIndex(of: p) ?? 0)")
            }
        }
    }
}

/// Wrapping row of chips.
struct FlowChips<Item: Identifiable, Chip: View>: View {
    let items: [Item]
    @ViewBuilder let chip: (Item) -> Chip
    var body: some View { WithPerceptionTracking { FlowLayout(spacing: 6) { ForEach(items) { item in WithPerceptionTracking { chip(item) } } } } }
}
