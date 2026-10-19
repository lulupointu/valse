import SwiftUI
import AppKit
import MontageCore
import MontageEffects

// MARK: - Generic descriptor rows

/// Rows generated from an effect descriptor's `ParamSpec`s (scalar → slider row with ‹◇›, colour → swatch,
/// bool → toggle, choice → dropdown). Shared by Adjust, Effects, Filter and Chroma key so they look identical.
struct EffectParamRows: View {
    let ctx: InspectorContext
    let instance: EffectInstance
    let descriptor: EffectDescriptor
    var only: [String]? = nil
    var enabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(descriptor.params.filter { only?.contains($0.key) ?? true }, id: \.key) { spec in
                EffectParamRow(ctx: ctx, instanceID: instance.id, spec: spec, enabled: enabled)
            }
        }
    }
}

struct EffectParamRow: View {
    let ctx: InspectorContext
    let instanceID: EffectInstanceID
    let spec: ParamSpec
    var enabled = true

    /// Colour tracks (UX.md §5 "Colour parameters show a gradient track").
    static func gradient(for key: String) -> [Color]? {
        switch key {
        case "temperature", "temp": return [Color(hex: 0x2B4BFF), Color(hex: 0x8A8A8A), Color(hex: 0xFFE14D)]
        case "tint", "hue": return [Color(hex: 0x3FA93A), Color(hex: 0x8A7A8A), Color(hex: 0xE23BE6)]
        case "saturation": return [Color(hex: 0x3A3A3A), Color(hex: 0xE5352B)]
        default: return nil
        }
    }

    var body: some View {
        let key = ParamKey.effect(instanceID, spec.key)
        switch spec.kind {
        case .scalar(let lo, let hi, _):
            let k = spec.displayScale
            ClipParamRow(ctx: ctx, label: tr(spec.nameKey),
                         spec: RowSpec(range: lo * k...hi * k, origin: lo < 0 ? 0 : nil, gradient: Self.gradient(for: spec.key),
                                       step: 1, format: Fmt.int),
                         get: { c, t in (c.value(key, at: t)?.scalar ?? 0) * k },
                         set: { c, v, t in c.setValue(key, .scalar(v / k), at: t) },
                         dependsOnTime: { $0.hasKeyframes(key) }, keyframeKeys: [key], gestureName: "cmd.effect", enabled: enabled)
        case .color(let d):
            let c = ctx.clip?.effects.first { $0.id == instanceID }?.params[spec.key].flatMap { if case .color(let c) = $0 { return c }; return nil } ?? d
            InlineRow(label: tr(spec.nameKey), enabled: enabled, triplet: Bind.triplet(ctx, [key])) {
                ColorSwatchButton(color: c, eyedropper: ctx.store, testID: "effect.\(spec.key)") { v in setParam(.color(v)) }
            }
        case .bool(let d):
            ToggleLine(label: tr(spec.nameKey), isOn: Binding(get: {
                if case .bool(let b) = param() { return b }; return d
            }, set: { setParam(.bool($0)) }), enabled: enabled)
        case .choice(let keys, let d):
            InlineRow(label: tr(spec.nameKey), enabled: enabled) {
                Dropdown(items: keys.enumerated().map { ($0.offset, tr($0.element)) },
                         selection: { if case .choice(let i) = param() { return i }; return d }()) { setParam(.choice($0)) }
            }
        }
    }

    func param() -> ParamValue? { ctx.clip?.effects.first { $0.id == instanceID }?.params[spec.key] }

    func setParam(_ v: ParamValue) {
        guard let id = ctx.clip?.id else { return }
        let iid = instanceID, k = spec.key
        ctx.store.perform(UpdateClip(id, nameKey: "cmd.effect") { c in
            if let i = c.effects.firstIndex(where: { $0.id == iid }) { c.effects[i].params[k] = v }
        })
    }
}

/// Header chrome for one effect instance (checkbox = enabled, reset = defaults, diamond over all its params).
@MainActor
enum EffectChrome {
    static func make(_ ctx: InspectorContext, _ instance: EffectInstance, _ d: EffectDescriptor, removable: Bool = true) -> InspectorSectionChrome {
        let store = ctx.store
        let clipID = ctx.clip?.id
        let iid = instance.id
        return InspectorSectionChrome(
            isEnabled: Binding(get: { instance.isEnabled }, set: { v in
                guard let clipID else { return }
                store.perform(UpdateClip(clipID, nameKey: "cmd.effect") { c in
                    if let i = c.effects.firstIndex(where: { $0.id == iid }) { c.effects[i].isEnabled = v }
                })
            }),
            reset: {
                guard let clipID else { return }
                let defaults = d.makeInstance().params
                store.perform(UpdateClip(clipID, nameKey: "cmd.effect") { c in
                    if let i = c.effects.firstIndex(where: { $0.id == iid }) { c.effects[i].params = defaults }
                    c.clearKeyframes(c.effectParamKeys(iid))
                })
            },
            keyframeKeys: d.params.filter { if case .scalar = $0.kind { return true }; if case .color = $0.kind { return true }; return false }
                .map { ParamKey.effect(iid, $0.key) },
            accessory: removable ? AnyView(SmallIconButton(symbol: "trash", help: tr("inspector.removeEffect"), size: 12) {
                guard let clipID else { return }
                store.perform(UpdateClip(clipID, nameKey: "cmd.effect") { c in
                    c.clearKeyframes(c.effectParamKeys(iid)); c.effects.removeAll { $0.id == iid }
                })
            }) : nil)
    }
}

/// A self-contained section block for one effect instance (used where the number of sections is dynamic).
struct EffectBlock: View {
    let ctx: InspectorContext
    let instance: EffectInstance
    let descriptor: EffectDescriptor
    var removable = true
    @State private var expanded = true
    var body: some View {
        let chrome = EffectChrome.make(ctx, instance, descriptor, removable: removable)
        VStack(alignment: .leading, spacing: 10) {
            SectionHeaderBar(title: tr(descriptor.nameKey), chrome: chrome, expanded: expanded && instance.isEnabled, ctx: ctx) {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            }
            if expanded && instance.isEnabled {
                EffectParamRows(ctx: ctx, instance: instance, descriptor: descriptor)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Cutout

/// Video ▸ Cutout ▸ ☐ Auto cutout / ☐ Customized: needs the AI matte in the compositor (W10/W6). Shown disabled with
/// the reason until that backend exists.
enum CutoutAvailability {
    /// Set to true by the AI/render teams once a matte can be composited (see ARCHITECTURE §18).
    nonisolated(unsafe) static var matteCompositingAvailable = true   // W10 mattes + W6 compositor (MontageUI/AI/CutoutUI.swift)
}

/// Video ▸ Cutout ▸ ☑ Chroma key: colour picker (system eyedropper samples anywhere on screen, e.g. the player),
/// Strength, Shadow, Feather edge, Clean up edge — sliders disabled until a colour is picked (UX.md §5.1, [122]).
struct ChromaKeySection: View {
    let ctx: InspectorContext

    static func instance(_ ctx: InspectorContext) -> EffectInstance? {
        ctx.clip?.effects.first { $0.typeID == BuiltinKeying.chromaKeyID }
    }

    static func chrome(_ ctx: InspectorContext) -> InspectorSectionChrome {
        let store = ctx.store
        let inst = instance(ctx)
        return InspectorSectionChrome(
            isEnabled: Binding(get: { inst != nil }, set: { on in
                guard let id = ctx.clip?.id else { return }
                store.perform(UpdateClip(id, nameKey: "cmd.chromaKey") { c in
                    if on {
                        if !c.effects.contains(where: { $0.typeID == BuiltinKeying.chromaKeyID }) {
                            c.effects.insert(BuiltinKeying.chromaKey.makeInstance(), at: 0)   // key before colour work
                        }
                    } else {
                        for e in c.effects where e.typeID == BuiltinKeying.chromaKeyID { c.clearKeyframes(c.effectParamKeys(e.id)) }
                        c.effects.removeAll { $0.typeID == BuiltinKeying.chromaKeyID }
                    }
                })
            }),
            reset: {
                guard let id = ctx.clip?.id, let iid = inst?.id else { return }
                let defaults = BuiltinKeying.chromaKey.makeInstance().params
                store.perform(UpdateClip(id, nameKey: "cmd.chromaKey") { c in
                    if let i = c.effects.firstIndex(where: { $0.id == iid }) { c.effects[i].params = defaults }
                    c.clearKeyframes(c.effectParamKeys(iid))
                })
            },
            keyframeKeys: inst.map { i in ["intensity", "shadow", "feather", "cleanup"].map { ParamKey.effect(i.id, $0) } } ?? [])
    }

    var body: some View {
        let inst = Self.instance(ctx)
        let color: RGBA? = inst.flatMap { i in if case .color(let c) = i.params["color"], c.a > 0.5 { return c }; return nil }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(loc: "key.chroma.color").font(Theme.Fonts.row).foregroundStyle(IStyle.label)
                Button { pick() } label: {
                    Image(systemName: "eyedropper").font(.system(size: 13)).foregroundStyle(.white)
                        .frame(width: 26, height: 26).background(IStyle.field, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain).help(tr("inspector.chroma.pickHelp")).testID("inspector.chroma.pick")
                if let color {
                    RoundedRectangle(cornerRadius: 4).fill(Color(color)).frame(width: 26, height: 26)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.2)))
                }
                Spacer()
                if color == nil { HintText(text: tr("inspector.chroma.hint")) }
            }
            .frame(minHeight: IStyle.rowHeight)
            if let inst {
                EffectParamRows(ctx: ctx, instance: inst, descriptor: BuiltinKeying.chromaKey,
                                only: ["intensity", "shadow", "feather", "cleanup"], enabled: color != nil)
            }
        }
    }

    func pick() {
        guard let id = ctx.clip?.id, let iid = Self.instance(ctx)?.id else { return }
        let store = ctx.store
        // canvas eyedropper (loupe over the video, samples the frame with this key switched off) — W2-8
        store.pickCanvasColor(disabling: iid, in: id) { rgba in
            store.perform(UpdateClip(id, nameKey: "cmd.chromaKey") { clip in
                if let i = clip.effects.firstIndex(where: { $0.id == iid }) { clip.effects[i].params["color"] = .color(rgba) }
            })
        }
    }
}

// MARK: - Mask

/// Which mask a mask section edits: the clip's shape mask (Video ▸ Mask) or the grading mask (Adjust ▸ Mask).
nonisolated struct MaskTarget: Sendable {
    nonisolated(unsafe) let mask: WritableKeyPath<Clip, Mask?>
    let center: ParamKey, size: ParamKey, feather: ParamKey, rotation: ParamKey, roundness: ParamKey
    let group: [ParamKey]
    /// Clip mask number (1…4, MK-005); 0 = the Adjust mask.
    var index = 1
    static let clip = MaskTarget(mask: \.mask, center: .maskCenter, size: .maskSize, feather: .maskFeather, rotation: .maskRotation,
                                 roundness: .maskRoundness, group: ParamKey.maskGroup)
    static let adjust = MaskTarget(mask: \.adjustMask, center: .adjustMaskCenter, size: .adjustMaskSize, feather: .adjustMaskFeather,
                                   rotation: .adjustMaskRotation, roundness: .adjustMaskRoundness, group: ParamKey.adjustMaskGroup, index: 0)

    /// Clip mask `n` (1 = `mask`, 2…4 = `extraMasks`).
    static func clip(_ n: Int) -> MaskTarget {
        n <= 1 ? .clip : MaskTarget(mask: Clip.maskKeyPath(n), center: .maskParam(n, "center"), size: .maskParam(n, "size"),
                                    feather: .maskParam(n, "feather"), rotation: .maskParam(n, "rotation"),
                                    roundness: .maskParam(n, "roundness"), group: ParamKey.maskGroup(n), index: n)
    }

    /// The clip mask selected in the inspector (MK-005 chips) for a clip-mask target; the Adjust mask stays as is.
    @MainActor func resolved(_ clip: Clip?) -> MaskTarget {
        guard index >= 1, let clip else { return self }
        let n = min(max(InspectorUIState.shared.maskIndex[clip.id] ?? 1, 1), max(clip.maskCount, 1))
        return .clip(n)
    }
}

/// Video ▸ Mask ▸ ☑ Mask: "+ Add mask" pill (dimmed shape grid until a mask exists), then a "Mask 1 · Shape" chip and
/// the shape grid with the selected tile outlined (UX.md §5.1, [24]/[26]).
struct MaskShapesSection: View {
    let ctx: InspectorContext
    var target: MaskTarget = .clip

    static func symbol(_ s: MaskShape) -> String {
        switch s {
        case .linear: return "rectangle.split.1x2"
        case .mirror: return "rectangle.split.3x1"
        case .circle: return "circle"
        case .rectangle: return "rectangle"
        case .heart: return "heart"
        case .star: return "star"
        case .text: return "textformat"
        case .pen: return "scribble.variable"
        }
    }

    static func defaultMask(_ s: MaskShape) -> Mask {
        switch s {
        case .linear: return Mask(shape: .linear, size: Vec2(1, 1))
        case .mirror: return Mask(shape: .mirror, size: Vec2(1, 0.4))
        case .circle: return Mask(shape: .circle, size: Vec2(0.5, 0.5))
        case .rectangle: return Mask(shape: .rectangle, size: Vec2(0.5, 0.5))
        case .heart: return Mask(shape: .heart, size: Vec2(0.5, 0.5))
        case .star: return Mask(shape: .star, size: Vec2(0.5, 0.5))
        case .text:
            var m = Mask(shape: .text, size: Vec2(0.7, 0.35)); m.text = tr("mask.text.default"); return m
        case .pen:
            var m = Mask(shape: .pen, size: Vec2(0.5, 0.6)); m.points = Mask.defaultPenPoints; return m
        }
    }

    var body: some View {
        let target = self.target.resolved(ctx.clip)
        let mask = ctx.clip?[keyPath: target.mask]
        VStack(alignment: .leading, spacing: 12) {
            if let mask, let clip = ctx.clip {
                // one chip per mask ("Mask 2 · Circle"), the edited one highlighted; ＋ adds another (up to 4, MK-005)
                let count = target.index >= 1 ? clip.maskCount : 1
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(1...max(count, 1), id: \.self) { n in
                            let m = target.index >= 1 ? clip.mask(n) : mask
                            let selected = target.index == 0 || n == target.index
                            Button {
                                if target.index >= 1 { InspectorUIState.shared.maskIndex[clip.id] = n }
                            } label: {
                                Text(verbatim: tr("inspector.mask.chip", n, tr((m ?? mask).shape.nameKey)))
                                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                                    .padding(.horizontal, 12).frame(height: 26)
                                    .background(selected ? Theme.accentDim : Theme.buttonSecondary, in: Capsule())
                                    .overlay(Capsule().strokeBorder(selected && count > 1 ? Theme.accent : .clear, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .testID("mask.chip.\(n)")
                        }
                        if target.index >= 1 && count < Clip.maxMasks {
                            SmallIconButton(symbol: "plus", help: tr("inspector.mask.addAnother"), size: 12) { addMask(clip) }
                                .testID("mask.addAnother")
                        }
                        SmallIconButton(symbol: "trash", help: tr("inspector.mask.remove"), size: 12) { setShape(nil) }
                            .testID("mask.remove")
                    }
                }
            } else {
                Button { setShape(.rectangle) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                        Text(loc: "inspector.mask.add").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white).padding(.horizontal, 14).frame(height: 26)
                    .background(Theme.buttonSecondary, in: Capsule())
                }
                .buttonStyle(.plain)
                .testID("mask.add")
            }
            TileGrid {
                ForEach(MaskShape.allCases, id: \.self) { s in
                    Tile(title: tr(s.nameKey), selected: mask?.shape == s) { setShape(s) } content: {
                        Image(systemName: Self.symbol(s)).font(.system(size: 24, weight: .light)).foregroundStyle(Color(white: 0.85))
                    }
                    .opacity(mask == nil ? 0.35 : 1)
                    .testID("mask.shape.\(s.rawValue)")
                }
            }
        }
    }

    /// ＋: a new rectangle mask after the last one, selected for editing.
    func addMask(_ clip: Clip) {
        let n = clip.maskCount + 1
        guard n <= Clip.maxMasks else { return }
        ctx.store.perform(UpdateClip(clip.id, nameKey: "cmd.mask") { c in c.setMask(n, MaskShapesSection.defaultMask(.rectangle)) })
        InspectorUIState.shared.maskIndex[clip.id] = n
    }

    func setShape(_ s: MaskShape?) {
        guard let id = ctx.clip?.id else { return }
        let t = target.resolved(ctx.clip)
        if s == nil && t.index >= 1 {
            ctx.store.perform(UpdateClip(id, nameKey: "cmd.mask.remove") { c in c.removeMask(t.index) })
            InspectorUIState.shared.maskIndex[id] = max(1, t.index - 1)
            return
        }
        ctx.store.perform(UpdateClip(id, nameKey: s == nil ? "cmd.mask.remove" : "cmd.mask") { c in
            if let s {
                if var m = c[keyPath: t.mask] {
                    m.shape = s; if s == .mirror && m.size.y > 0.9 { m.size.y = 0.4 }
                    let d = MaskShapesSection.defaultMask(s)
                    if m.text == nil { m.text = d.text }
                    if m.points == nil { m.points = d.points }
                    c[keyPath: t.mask] = m
                }
                else { c[keyPath: t.mask] = MaskShapesSection.defaultMask(s) }
            } else {
                c[keyPath: t.mask] = nil
                c.clearKeyframes(t.group)
            }
        })
    }
}

/// Video ▸ Mask ▸ Mask settings: [invert] ↺ ‹◇›; Position, Rotation + dial, Size W ⛓ H, Feather, Round corners.
struct MaskSettingsSection: View {
    let ctx: InspectorContext
    var target: MaskTarget = .clip

    static func chrome(_ ctx: InspectorContext) -> InspectorSectionChrome { chrome(ctx, target: .clip) }

    static func chrome(_ ctx: InspectorContext, target t0: MaskTarget) -> InspectorSectionChrome {
        let t = t0.resolved(ctx.clip)
        let store = ctx.store
        let inverted = ctx.clip?[keyPath: t.mask]?.inverted ?? false
        return InspectorSectionChrome(
            reset: {
                guard let id = ctx.clip?.id else { return }
                store.perform(UpdateClip(id, nameKey: "cmd.mask") { c in
                    if let s = c[keyPath: t.mask]?.shape { c[keyPath: t.mask] = MaskShapesSection.defaultMask(s) }
                    c.clearKeyframes(t.group)
                })
            },
            keyframeKeys: t.group,
            accessory: AnyView(SmallIconButton(symbol: "circle.lefthalf.striped.horizontal.inverse", help: tr("inspector.mask.invert"),
                                               active: inverted, size: 14) {
                guard let id = ctx.clip?.id else { return }
                store.perform(UpdateClip(id, nameKey: "cmd.mask") { $0[keyPath: t.mask]?.inverted.toggle() })
            }))
    }

    var body: some View {
        let layer = layerSize()
        let t = target.resolved(ctx.clip)
        let shape = ctx.clip?[keyPath: t.mask]?.shape
        let locked = InspectorUIState.shared.maskLock
        VStack(alignment: .leading, spacing: 4) {
            if shape == .text { MaskTextField(ctx: ctx, target: t) }
            if shape == .pen { HintText(text: tr("inspector.mask.penHint")) }
            InlineRow(label: tr("prop.position"), triplet: Bind.triplet(ctx, [t.center])) {
                HStack(spacing: 14) {
                    Bind.field(ctx, key: t.center, component: 0, prefix: "X", spec: RowSpec(range: -100_000...100_000, step: 1, format: Fmt.int),
                               toUI: { $0 * layer.width }, fromUI: { $0 / max(layer.width, 1) }, gestureName: "cmd.mask")
                    Bind.field(ctx, key: t.center, component: 1, prefix: "Y", spec: RowSpec(range: -100_000...100_000, step: 1, format: Fmt.int),
                               toUI: { -$0 * layer.height }, fromUI: { -$0 / max(layer.height, 1) }, gestureName: "cmd.mask")
                }
            }
            InlineRow(label: tr("prop.rotation"), triplet: Bind.triplet(ctx, [t.rotation])) {
                HStack(spacing: 18) {
                    Bind.field(ctx, key: t.rotation, spec: RowSpec(range: -360...360, step: 1, format: Fmt.degrees1), gestureName: "cmd.mask")
                    RotationDialBinding(ctx: ctx, key: t.rotation)
                }
            }
            if shape != .linear {
                InlineRow(label: tr("inspector.size"), triplet: Bind.triplet(ctx, [t.size])) {
                    HStack(spacing: 4) {
                        sizeField(0, layer: layer, locked: locked)
                        Button { InspectorUIState.shared.maskLock.toggle() } label: {
                            Image(systemName: locked ? "link" : "link").font(.system(size: 11))
                                .foregroundStyle(locked ? Theme.accent : IStyle.iconDim).frame(width: 20, height: 24)
                        }
                        .buttonStyle(.plain).help(tr("inspector.mask.lockRatio"))
                        sizeField(1, layer: layer, locked: locked)
                    }
                }
            }
            Bind.row(ctx, tr("prop.maskFeather"), key: t.feather, spec: RowSpec(range: 0...100, step: 1, format: Fmt.int),
                     toUI: { $0 * 100 }, fromUI: { $0 / 100 }, gestureName: "cmd.mask")
            if shape == .rectangle {
                Bind.row(ctx, tr("prop.maskRoundness"), key: t.roundness, spec: RowSpec(range: 0...100, step: 1, format: Fmt.int),
                         toUI: { $0 * 100 }, fromUI: { $0 / 100 }, gestureName: "cmd.mask")
            }
        }
    }

    /// Size field in layer pixels; with the chain on, changing one side scales the other proportionally.
    func sizeField(_ i: Int, layer: Size2, locked: Bool) -> some View {
        let dim = i == 0 ? layer.width : layer.height
        return ClipNumberField(ctx: ctx, prefixSymbol: i == 0 ? "arrow.left.and.right" : "arrow.up.and.down", width: 64,
                               spec: RowSpec(range: 1...100_000, step: 1, format: Fmt.int),
                               get: { [key = target.resolved(ctx.clip).size] c, t in (c.value(key, at: t)?.component(i) ?? 0.5) * dim },
                               set: { [key = target.resolved(ctx.clip).size] c, v, t in
                                   c.modifyValue(key, at: t) { val in
                                       guard var s = val.vec2 else { return }
                                       let nv = v / max(dim, 1)
                                       let old = i == 0 ? s.x : s.y
                                       if i == 0 { s.x = nv } else { s.y = nv }
                                       if locked, old > 1e-6 { if i == 0 { s.y *= nv / old } else { s.x *= nv / old } }
                                       val = .vec2(s)
                                   }
                               },
                               dependsOnTime: { [key = target.resolved(ctx.clip).size] in $0.hasKeyframes(key) }, gestureName: "cmd.mask")
    }

    /// Layer size in canvas pixels at scale 1 (mask coordinates are layer-relative).
    func layerSize() -> Size2 {
        let canvas = ctx.store.project.settings.canvasSize
        guard let src = ctx.asset?.pixelSize, src.width > 0, src.height > 0 else { return canvas }
        let fit = min(canvas.width / src.width, canvas.height / src.height)
        return Size2((src.width * fit).rounded(), (src.height * fit).rounded())
    }
}

/// Text mask: the string whose glyphs form the mask (W3-7). Enter / focus loss commits one undo step.
struct MaskTextField: View {
    let ctx: InspectorContext
    let target: MaskTarget
    @State private var text = ""
    var body: some View {
        let current = ctx.clip?[keyPath: target.mask]?.text ?? ""
        InlineRow(label: tr("inspector.mask.text")) {
            TextField("", text: $text)
                .textFieldStyle(.plain).font(Theme.Fonts.row).foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 8).frame(height: 28)
                .background(IStyle.field, in: RoundedRectangle(cornerRadius: 4))
                .onSubmit(commit)
                .onAppear { text = current }
                .onChange(of: current) { text = current }
                .testID("mask.text")
        }
    }
    func commit() {
        guard let id = ctx.clip?.id, text != (ctx.clip?[keyPath: target.mask]?.text ?? "") else { return }
        let t = target, v = text
        ctx.store.perform(UpdateClip(id, nameKey: "cmd.mask") { $0[keyPath: t.mask]?.text = v })
    }
}
