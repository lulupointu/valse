import SwiftUI
import MontageCore
import MontageEffects
import Perception

// MARK: - Adjust ▸ Basic ▸ ☑ Adjust

/// The basic colour panel (`BuiltinAdjustments.basic`), laid out like CapCut: Color / Lightness / Effects captions,
/// gradient tracks for Temp/Hue/Saturation, every row with its own field and ‹◇›. Sliders show the defaults until
/// the first edit, which adds the adjustment to the clip (one undo step). Unknown params (added later by the colour
/// team) land in the group their key suggests, or at the end.
struct AdjustBasicSection: View {
    let ctx: InspectorContext
    static let descriptor = BuiltinAdjustments.basic

    static let groups: [(titleKey: String, keys: [String])] = [
        ("adjust.caption.color", ["temperature", "temp", "tint", "hue", "saturation"]),
        ("adjust.caption.lightness", ["exposure", "brightness", "contrast", "highlights", "shadows", "whites", "blacks", "brilliance", "light"]),
        ("adjust.caption.effects", ["sharpen", "clarity", "grain", "particles", "fade", "vignette"]),
    ]

    static func instance(_ c: Clip?) -> EffectInstance? { c?.effects.first { $0.typeID == descriptor.id } }

    static func chrome(_ ctx: InspectorContext) -> InspectorSectionChrome {
        let store = ctx.store
        let inst = instance(ctx.clip)
        return InspectorSectionChrome(
            isEnabled: Binding(get: { inst?.isEnabled ?? true }, set: { v in
                guard let id = ctx.clip?.id, inst != nil else { return }
                let tid = descriptor.id   // by type: the same panel on every selected clip (C2)
                store.performInspector(UpdateClip(id, nameKey: "cmd.adjust") { c in
                    if let i = c.effects.firstIndex(where: { $0.typeID == tid }) { c.effects[i].isEnabled = v }
                })
            }),
            reset: {
                guard let id = ctx.clip?.id, inst != nil else { return }
                let defaults = descriptor.makeInstance().params
                let tid = descriptor.id
                store.performInspector(UpdateClip(id, nameKey: "cmd.adjust") { c in
                    guard let i = c.effects.firstIndex(where: { $0.typeID == tid }) else { return }
                    let iid = c.effects[i].id
                    c.effects[i].params = defaults
                    c.clearKeyframes(c.effectParamKeys(iid))
                })
            },
            keyframeKeys: inst.map { i in descriptor.params.map { ParamKey.effect(i.id, $0.key) } } ?? [])
    }

    var body: some View {
        WithPerceptionTracking {
            let d = Self.descriptor
            let known = Set(Self.groups.flatMap(\.keys))
            let extra = d.params.filter { !known.contains($0.key) }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Self.groups, id: \.titleKey) { g in
                    WithPerceptionTracking {
                        let specs = g.keys.compactMap { k in d.params.first { $0.key == k } } + (g.titleKey == "adjust.caption.effects" ? extra : [])
                        if !specs.isEmpty {
                            GroupCaption(title: tr(g.titleKey))
                            ForEach(specs, id: \.key) { spec in WithPerceptionTracking { row(spec) } }
                        }
                    }
                }
            }
        }
    }

    func row(_ spec: ParamSpec) -> some View {
        guard case .scalar(let lo, let hi, let def) = spec.kind else { return AnyView(EmptyView()) }
        let k = spec.displayScale
        let inst = Self.instance(ctx.clip)
        let key = inst.map { ParamKey.effect($0.id, spec.key) }
        let d = Self.descriptor
        return AnyView(ClipParamRow(
            ctx: ctx, label: tr(spec.nameKey),
            spec: RowSpec(range: lo * k...hi * k, origin: lo < 0 ? 0 : nil, gradient: EffectParamRow.gradient(for: spec.key), step: 1, format: Fmt.int),
            get: { c, t in
                guard let i = Self.instance(c) else { return def * k }
                return (c.value(.effect(i.id, spec.key), at: t)?.scalar ?? def) * k
            },
            set: { c, v, t in
                if Self.instance(c) == nil { c.effects.append(d.makeInstance()) }
                guard let i = Self.instance(c) else { return }
                c.setValue(.effect(i.id, spec.key), .scalar(v / k), at: t)
            },
            dependsOnTime: { c in key.map { c.hasKeyframes($0) } ?? false },
            keyframeKeys: key.map { [$0] } ?? [], gestureName: "cmd.adjust"))
    }

    /// Footer "Apply to all" (kept for callers): the whole Adjust-tab grade on every video / image clip.
    static func applyToAll(_ ctx: InspectorContext) { AdjustTools.applyToAll(ctx) }
}

/// Filter applied to a clip (Adjust ▸ Basic ▸ Filter): Name + Strength ‹◇› (UX.md §5.5).
struct ClipFilterBlocks: View {
    let ctx: InspectorContext
    var body: some View {
        WithPerceptionTracking {
            let filters = (ctx.clip?.effects ?? []).filter { Registries.effects[$0.typeID]?.category == .filter }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(filters) { inst in
                    WithPerceptionTracking {
                        if let d = Registries.effects[inst.typeID] {
                            FilterDetailsBlock(ctx: ctx, instance: inst, descriptor: d, title: tr("inspector.filter"), removable: true)
                        }
                    }
                }
            }
        }
    }
}

struct FilterDetailsBlock: View {
    let ctx: InspectorContext
    let instance: EffectInstance
    let descriptor: EffectDescriptor
    let title: String
    var removable = false
    var body: some View {
        WithPerceptionTracking {
            var chrome = EffectChrome.make(ctx, instance, descriptor, removable: removable)
            chrome.isEnabled = nil
            return VStack(alignment: .leading, spacing: 8) {
                SectionHeaderBar(title: title, chrome: chrome, expanded: true, ctx: ctx) {}
                InlineRow(label: tr("inspector.name")) {
                    Text(verbatim: tr(descriptor.nameKey)).font(Theme.Fonts.row).foregroundStyle(Theme.textPrimary)
                }
                EffectParamRows(ctx: ctx, instance: instance, descriptor: descriptor)
            }
            .padding(.vertical, 6)
        }
    }
}

/// Other adjustment-category entries on the clip (e.g. HSL/LUT descriptors added later): generated blocks.
struct OtherAdjustmentBlocks: View {
    let ctx: InspectorContext
    /// Adjustment-category entries without a dedicated section (HSL / Curves / Color wheel / Auto adjust have sub-tabs).
    static func listed(_ e: EffectInstance) -> Bool {
        e.typeID != BuiltinAdjustments.basic.id && !ColorGradingInspector.ownIDs.contains(e.typeID)
            && !e.typeID.hasPrefix("ai.look.") && Registries.effects[e.typeID]?.category == .adjustment
    }
    var body: some View {
        WithPerceptionTracking {
            let list = (ctx.clip?.effects ?? []).filter(Self.listed)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, inst in
                    WithPerceptionTracking {
                        if i > 0 { Rectangle().fill(Theme.separator).frame(height: 1).padding(.vertical, 6) }
                        if let d = Registries.effects[inst.typeID] { EffectBlock(ctx: ctx, instance: inst, descriptor: d) }
                    }
                }
            }
        }
    }
}

/// Video effects dropped onto a clip (clip inspector ▸ Effects): one generated block per effect.
struct ClipEffectBlocks: View {
    let ctx: InspectorContext
    static func hasEffects(_ ctx: InspectorContext) -> Bool {
        (ctx.clip?.effects ?? []).contains { Registries.effects[$0.typeID]?.category == .effect }
    }
    var body: some View {
        WithPerceptionTracking {
            let list = (ctx.clip?.effects ?? []).filter { Registries.effects[$0.typeID]?.category == .effect }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, inst in
                    WithPerceptionTracking {
                        if i > 0 { Rectangle().fill(Theme.separator).frame(height: 1).padding(.vertical, 6) }
                        if let d = Registries.effects[inst.typeID] { EffectBlock(ctx: ctx, instance: inst, descriptor: d) }
                    }
                }
            }
        }
    }
}

// MARK: - Effect / filter clips

/// Effect clip ("Special effects" ▸ Basic ▸ Details) or filter clip ("Filter"): Name + one row per parameter,
/// header ↺ and a diamond over all parameters (UX.md §5.4 / §5.5).
struct EffectClipSection: View {
    let ctx: InspectorContext
    var body: some View {
        WithPerceptionTracking {
            let effects = ctx.clip?.effects ?? []
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(effects.enumerated()), id: \.element.id) { i, inst in
                    WithPerceptionTracking {
                        if i > 0 { Rectangle().fill(Theme.separator).frame(height: 1).padding(.vertical, 6) }
                        if let d = Registries.effects[inst.typeID] {
                            if i == 0 {
                                FilterDetailsBlock(ctx: ctx, instance: inst, descriptor: d, title: tr("inspector.details"))
                            } else {
                                EffectBlock(ctx: ctx, instance: inst, descriptor: d)
                            }
                        }
                    }
                }
                if !effects.isEmpty { EffectScopeRow(ctx: ctx) }   // FX-004 "Apply to" (F4Effects.swift)
            }
        }
    }
}

// MARK: - Transition

/// Transition ▸ Transition parameters ↺: Name, Duration 0.1 s … min(clip lengths, 5 s); footer Apply to all (§5.7).
struct TransitionSection: View {
    let ctx: InspectorContext

    static func maxDuration(_ ctx: InspectorContext) -> Double {
        guard let a = ctx.transitionClip, let loc = ctx.store.project.timeline.locate(a.id) else { return 5 }
        let clips = ctx.store.project.timeline.tracks[loc.track].clips
        let b = loc.clip + 1 < clips.count ? clips[loc.clip + 1] : nil
        return max(0.1, min(5, a.duration.seconds, b?.duration.seconds ?? 5))
    }

    static func chrome(_ ctx: InspectorContext) -> InspectorSectionChrome {
        InspectorSectionChrome(reset: {
            guard let a = ctx.transitionClip, let t = a.transitionOut, let d = Registries.transitions[t.typeID] else { return }
            ctx.store.perform(SetTransition(a.id, d.makeInstance()))
        })
    }

    static func applyToAll(_ ctx: InspectorContext) {
        guard let t = ctx.transitionClip?.transitionOut else { return }
        ctx.store.perform(Edit("cmd.transition.applyAll") { p in
            guard let mi = p.timeline.mainTrackIndex else { return }
            let ids = p.timeline.tracks[mi].clips.dropLast().map(\.id)
            for id in ids { try TimelineOps.setTransition(id, t, in: &p.timeline) }
        })
        ctx.store.showToast(tr("toast.appliedToAll"))
    }

    var body: some View {
        WithPerceptionTracking {
            let store = ctx.store
            let a = ctx.transitionClip
            let t = a?.transitionOut
            let maxD = Self.maxDuration(ctx)
            let value = t?.duration.seconds ?? 0.5
            let scale = SliderScale.linear(0.1...maxD)
            @MainActor func write(_ v: Double, live: Bool) {
                guard let a, var nt = a.transitionOut else { return }
                nt.duration = Time(min(max(v, 0.1), maxD))
                let id = a.id, inst = nt
                if live { store.updateGesture { p in try TimelineOps.setTransition(id, inst, in: &p.timeline) } }
                else { store.perform(SetTransition(id, inst)) }
            }
            return VStack(alignment: .leading, spacing: 8) {
                InlineRow(label: tr("inspector.name")) {
                    Text(verbatim: t.flatMap { Registries.transitions[$0.typeID] }.map { tr($0.nameKey) } ?? "—")
                        .font(Theme.Fonts.row).foregroundStyle(Theme.textPrimary)
                }
                SliderRowView(label: tr("inspector.duration"), unit: scale.toUnit(min(value, maxD)), display: Fmt.seconds(value),
                              enabled: t != nil, parse: NumberParse.number,
                              onBegin: { store.beginGesture("cmd.transition") },
                              onChange: { u in write(scale.fromUnit(u), live: true) },
                              onEnd: { store.endGesture() },
                              commit: { write($0, live: false) },
                              step: { write(value + Double($0) * 0.1, live: false) }, testID: "transition.duration")
                TransitionParamRows(ctx: ctx)   // W5: direction / colour / softness… (MontageUI/Transitions)
            }
        }
    }
}
