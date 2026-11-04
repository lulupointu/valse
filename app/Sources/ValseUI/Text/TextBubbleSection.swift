import SwiftUI
import AppKit
import ValseCore
import ValseEffects
import ValseEngine
import Perception

/// Text ▸ Bubble (TX-014, TX-BUBBLE2), laid out like Text ▸ Basic: a compact preset row on top ("All" expands the
/// group pills + full grid in place, "Based on X · Edited ↺"), then one inspector section per part: Shape (always
/// shown, ⊘ removes the bubble; Roundness / Edge per shape), ☐ Fill, ☐ Outline, ☐ Neon, ☐ Shadow, ☐ Tail (shapes with
/// a tail) and Padding. With no bubble, picking a shape or ticking a part builds one from scratch ("start from blank").
/// Edits apply to every selected text clip (C2), one undo step each, not keyframable; a preset edit makes it "Edited".
@MainActor
enum BubbleSections {
    static func text(_ ctx: InspectorContext) -> TextContent? { TextInspector.text(ctx) }
    static func bubble(_ ctx: InspectorContext) -> TextBubbleStyle? { text(ctx)?.resolvedBubble() }

    static let all: [InspectorSection] = [
        InspectorSection(id: "text.bubble", tab: "text", subTab: "bubble", order: 0, titleKey: nil) { AnyView(TextBubbleSection(ctx: $0)) },
        InspectorSection(id: "text.bubble.shape", tab: "text", subTab: "bubble", order: 10, titleKey: "text.bubble.shape") {
            AnyView(BubbleShapeSection(ctx: $0))
        },
        InspectorSection(id: "text.bubble.fill", tab: "text", subTab: "bubble", order: 20, titleKey: "text.bubble.fill",
                         chrome: { chrome($0, .fill) }) { AnyView(BubbleFillSection(ctx: $0)) },
        InspectorSection(id: "text.bubble.outline", tab: "text", subTab: "bubble", order: 30, titleKey: "text.bubble.outline",
                         chrome: { chrome($0, .outline) }) { AnyView(BubbleOutlineSection(ctx: $0)) },
        InspectorSection(id: "text.bubble.neon", tab: "text", subTab: "bubble", order: 40, titleKey: "text.bubble.neon",
                         chrome: { chrome($0, .neon) }) { AnyView(BubbleNeonSection(ctx: $0)) },
        InspectorSection(id: "text.bubble.shadow", tab: "text", subTab: "bubble", order: 50, titleKey: "text.bubble.shadow",
                         chrome: { chrome($0, .shadow) }) { AnyView(BubbleShadowSection(ctx: $0)) },
        InspectorSection(id: "text.bubble.tail", tab: "text", subTab: "bubble", order: 60, titleKey: "text.bubble.tail",
                         appliesTo: { bubble($0)?.family.hasTail ?? false },
                         chrome: { chrome($0, .tail) }) { AnyView(BubbleTailSection(ctx: $0)) },
        InspectorSection(id: "text.bubble.padding", tab: "text", subTab: "bubble", order: 70, titleKey: "text.bubble.padding",
                         chrome: { ctx in
                             InspectorSectionChrome(reset: bubble(ctx) == nil ? nil : {
                                 let ref = text(ctx)?.bubblePreset?.style
                                 ctx.store.updateBubble { $0.padding = ref?.padding ?? TextBubbleStyle.blank($0.family).padding }
                             })
                         }) { ctx in
            AnyView(WithPerceptionTracking {
                let s = bubble(ctx)
                BubblePaddingRows(ctx: ctx, style: s).disabled(s == nil).opacity(s == nil ? 0.45 : 1)
            })
        },
    ]

    // MARK: Parts (checkbox sections)

    enum Part { case fill, outline, neon, shadow, tail }

    static func isOn(_ p: Part, _ s: TextBubbleStyle) -> Bool {
        switch p {
        case .fill: return s.fill.a > 0
        case .outline: return s.outline != nil
        case .neon: return s.outline?.neon != nil
        case .shadow: return s.shadow != nil
        case .tail: return s.tail != nil
        }
    }

    /// The bubble a part's checkbox builds when the text has none (owner decision "start from blank"): Fill → white
    /// pill, Shadow → white pill with a shadow, Outline / Neon → a transparent rounded box with only that line.
    static func blank(_ p: Part) -> TextBubbleStyle {
        switch p {
        case .fill, .shadow: return .blank(.pill)
        case .outline, .neon, .tail: var b = TextBubbleStyle.blank(.box); b.fill = .clear; return b
        }
    }

    /// Checkbox: on keeps what is there (or takes the preset's part, else a default), off removes the part. Neon on
    /// turns the outline on (pink tube); outline off removes the neon with it.
    static func toggle(_ p: Part, _ s: inout TextBubbleStyle, on: Bool, ref: TextBubbleStyle?) {
        switch p {
        case .fill:
            if !on { s.fill.a = 0 }
            else if s.fill.a == 0 {
                let f = s.fill
                s.fill = f.r + f.g + f.b > 0 ? RGBA(f.r, f.g, f.b, 1) : (ref.map { $0.fill.a > 0 ? $0.fill : .white } ?? .white)
            }
        case .outline:
            if !on { s.outline = nil }
            else if s.outline == nil {
                s.outline = ref?.outline.map { var o = $0; o.neon = nil; return o } ?? TextBubbleOutline(color: .white)
            }
        case .neon:
            if !on { s.outline?.neon = nil; return }
            if s.outline == nil { s.outline = TextBubbleOutline(color: TextNeonStyle.swatches[0].color) }
            if s.outline?.neon == nil { s.outline?.neon = ref?.outline?.neon ?? TextBubbleOutline.neonStyle() }
        case .shadow:
            s.shadow = on ? (s.shadow ?? ref?.shadow ?? TextBubbleShadow(color: RGBA(0, 0, 0, 0.4))) : nil
        case .tail:
            s.tail = on ? (s.tail ?? ref?.tail ?? TextBubbleTail(side: .bottomLeft)) : nil
        }
    }

    /// Section ↺: that part back from the preset (or the blank defaults for a bubble built from scratch).
    static func reset(_ p: Part, _ s: inout TextBubbleStyle, ref: TextBubbleStyle) {
        switch p {
        case .fill: s.fill = ref.fill
        case .outline:
            if var o = ref.outline { o.neon = s.outline?.neon; s.outline = o } else { s.outline = nil }
        case .neon:
            if s.outline != nil { s.outline?.neon = ref.outline?.neon ?? TextBubbleOutline.neonStyle() }
        case .shadow: s.shadow = ref.shadow
        case .tail: s.tail = ref.family.hasTail ? ref.tail : TextBubbleTail(side: .bottomLeft)
        }
    }

    static func chrome(_ ctx: InspectorContext, _ p: Part) -> InspectorSectionChrome {
        let has = bubble(ctx) != nil
        return InspectorSectionChrome(
            isEnabled: Binding.perceived(get: { bubble(ctx).map { isOn(p, $0) } ?? false }, set: { on in
                let ref = text(ctx)?.bubblePreset?.style
                ctx.store.updateBubble(blank: on ? blank(p) : nil) { toggle(p, &$0, on: on, ref: ref) }
            }),
            reset: has ? {
                let ref = text(ctx)?.bubblePreset?.style
                ctx.store.updateBubble { st in reset(p, &st, ref: ref ?? .blank(st.family)) }
            } : nil)
    }
}

// MARK: - Presets

/// Top of the Bubble tab: the flat Background warning, 2 rows of small preset tiles (⊘ None, recents first, then the
/// first picks of each group), "All N" to expand the group pills + full grid in place, "Based on X · Edited ↺".
struct TextBubbleSection: View {
    let ctx: InspectorContext
    static let compactCount = 13

    var body: some View {
        WithPerceptionTracking {
            let ui = TextUIState.shared
            let t = TextInspector.text(ctx)
            let cur = t?.bubbleID
            let style = t?.resolvedBubble()
            VStack(alignment: .leading, spacing: 10) {
                if let t, style != nil, t.backgroundColor.a > 0 {
                    HStack(spacing: 8) {
                        HintText(text: tr("text.bubble.bgOn"))
                        Spacer(minLength: 4)
                        PillButton(title: tr("text.bubble.bgOff")) { set(name: "cmd.textBubbleEdit") { $0.backgroundColor.a = 0 } }
                            .testID("text.bubble.bgOff")
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    if ui.bubblePresetsExpanded {
                        groupPills(ui)
                        grid(ui, cur: cur, edited: t?.isBubbleEdited ?? false, noBubble: style == nil)
                    } else {
                        compact(ui, cur: cur, edited: t?.isBubbleEdited ?? false, noBubble: style == nil)
                    }
                    expandButton(ui)
                }
                .testID("text.bubble.presets")
                if let t { basedOn(t) }
            }
        }
    }

    private func set(name: String, _ edit: @escaping (inout TextContent) -> Void) {
        guard let id = ctx.store.bubbleTargetClipID else { return }
        ctx.store.updateText(id, nameKey: name, edit)
    }

    /// Recents first, then round-robin over the groups (each group's first preset, then its second…).
    static func compactPresets(recents: [String]) -> [TextBubbleDescriptor] {
        let all = Registries.textBubbles.all
        var out: [TextBubbleDescriptor] = recents.compactMap { Registries.textBubbles[$0] }
        let byGroup = BuiltinTextBubbles.groups.map { g in all.filter { $0.groupKey == g } }
        var i = 0
        while out.count < compactCount, byGroup.contains(where: { $0.count > i }) {
            for g in byGroup where g.count > i && !out.contains(where: { $0.id == g[i].id }) { out.append(g[i]) }
            i += 1
        }
        return Array(out.prefix(compactCount))
    }

    private func compact(_ ui: TextUIState, cur: String?, edited: Bool, noBubble: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 40, maximum: 48), spacing: 6)], spacing: 6) {
            smallTile(selected: noBubble, testID: "text.bubble.tile.none", help: tr("anim.none")) {
                Image(systemName: "nosign").font(.system(size: 18, weight: .light)).foregroundStyle(Color(white: 0.75))
            } action: { ctx.store.applyBubble(nil) }
            ForEach(Self.compactPresets(recents: ui.recentBubbles)) { d in
                WithPerceptionTracking {
                    smallTile(selected: cur == d.id, testID: Self.tileID(d), help: tr(d.nameKey)) { preview(d) } action: { ctx.store.applyBubble(d) }
                        .overlay(alignment: .topTrailing) { if cur == d.id && edited { editedDot } }
                }
            }
        }
    }

    private func expandButton(_ ui: TextUIState) -> some View {
        Button { ui.bubblePresetsExpanded.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: ui.bubblePresetsExpanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
                Text(verbatim: ui.bubblePresetsExpanded ? tr("text.bubble.less") : tr("text.bubble.all", Registries.textBubbles.all.count))
                    .font(.system(size: 11.5, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
        .testID("text.bubble.all")
    }

    /// "Based on <preset> · Edited" + ↺ (the whole preset back with its paired text look).
    @ViewBuilder private func basedOn(_ t: TextContent) -> some View {
        if let d = t.bubblePreset {
            HStack(spacing: 6) {
                Text(verbatim: tr("text.bubble.basedOn", tr(d.nameKey)) + (t.isBubbleEdited ? " · " + tr("text.bubble.edited") : ""))
                    .font(Theme.Fonts.hint).foregroundStyle(IStyle.caption).lineLimit(1).truncationMode(.middle)
                    .testID("text.bubble.basedOn")
                Spacer(minLength: 4)
                if t.bubbleStyle != nil {
                    SmallIconButton(symbol: "arrow.counterclockwise", help: tr("text.bubble.reset")) { ctx.store.resetBubble() }
                        .testID("text.bubble.reset")
                }
            }
        }
    }

    private var editedDot: some View {
        Circle().fill(Theme.accent).frame(width: 7, height: 7).padding(4).allowsHitTesting(false)
    }

    static func tileID(_ d: TextBubbleDescriptor) -> String { "text.bubble.tile.\(d.id.split(separator: ".").last ?? "")" }

    private func preview(_ d: TextBubbleDescriptor) -> some View {
        ZStack {
            if d.previewBackdrop == .light { Color(hex: 0xD9D9D9) }
            TextPreviewImage(key: "bubble:\(d.id)", content: TextPreviewImage.bubble(d), fontPx: 30, padding: 4)
        }
    }

    private func smallTile<C: View>(selected: Bool, testID: String, help: String, @ViewBuilder _ c: () -> C,
                                    action: @escaping () -> Void) -> some View {
        ZStack { RoundedRectangle(cornerRadius: 6).fill(IStyle.tile); c() }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .help(help)
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: help))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .testID(testID)
    }

    // MARK: Full grid ("All")

    private func groupPills(_ ui: TextUIState) -> some View {
        FlowLayout(spacing: 6) {
            pill(nil, tr("text.bubble.group.all"), ui)
            ForEach(BuiltinTextBubbles.groups, id: \.self) { g in
                WithPerceptionTracking { pill(g, tr(g), ui) }
            }
        }
    }

    private func pill(_ g: String?, _ title: String, _ ui: TextUIState) -> some View {
        let on = ui.bubbleGroup == g
        return Text(verbatim: title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10).frame(height: 24)
            .background(on ? Theme.accentDim : Theme.buttonSecondary, in: Capsule())
            .contentShape(Capsule())
            .onTapGesture { ui.bubbleGroup = g }
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: title))
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            .testID("text.bubble.group.\(g.map { String($0.split(separator: ".").last ?? "") } ?? "all")")
    }

    @ViewBuilder
    private func grid(_ ui: TextUIState, cur: String?, edited: Bool, noBubble: Bool) -> some View {
        let none = Tile(title: tr("anim.none"), selected: noBubble, testID: "text.bubble.tile.none", titleLines: 2) { ctx.store.applyBubble(nil) } content: {
            Image(systemName: "nosign").font(.system(size: 26, weight: .light)).foregroundStyle(Color(white: 0.75))
        }
        // A flow of equal-width tiles (columns line up) rather than a lazy grid: every tile exists, so a group's tiles
        // are reachable right after its pill is picked even when the section is scrolled (cached previews).
        if let g = ui.bubbleGroup {
            FlowLayout(spacing: 6, lineSpacing: 10) {
                none
                ForEach(Registries.textBubbles.all.filter { $0.groupKey == g }) { d in WithPerceptionTracking { tile(d, cur: cur, edited: edited) } }
            }
        } else {
            FlowLayout(spacing: 6, lineSpacing: 10) { none }
            ForEach(BuiltinTextBubbles.groups, id: \.self) { g in
                WithPerceptionTracking {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: tr(g)).font(.system(size: 12, weight: .medium)).foregroundStyle(IStyle.caption)
                        FlowLayout(spacing: 6, lineSpacing: 10) {
                            ForEach(Registries.textBubbles.all.filter { $0.groupKey == g }) { d in WithPerceptionTracking { tile(d, cur: cur, edited: edited) } }
                        }
                    }
                }
            }
        }
    }

    private func tile(_ d: TextBubbleDescriptor, cur: String?, edited: Bool) -> some View {
        Tile(title: tr(d.nameKey), selected: cur == d.id, testID: Self.tileID(d), titleLines: 2) {
            ctx.store.applyBubble(d)
        } content: {
            ZStack {
                if d.previewBackdrop == .light { Color(hex: 0xD9D9D9) }
                TextPreviewImage(key: "bubble:\(d.id)", content: TextPreviewImage.bubble(d), fontPx: 30, padding: 6)
            }
        }
        .overlay(alignment: .topTrailing) { if cur == d.id && edited { editedDot.padding(1) } }
    }
}

/// Numeric row on the selected texts' bubble (one undo step "Edit bubble" per drag / typed value).
@MainActor
enum BubbleRows {
    static func row(_ ctx: InspectorContext, _ label: String, _ testID: String, range: ClosedRange<Double> = 0...100,
                    format: @escaping (Double) -> String = { String(Int($0.rounded())) }, spec: RowSpec? = nil,
                    get: @escaping (TextBubbleStyle) -> Double, set: @escaping (inout TextBubbleStyle, Double) -> Void) -> ClipParamRow {
        ClipParamRow(ctx: ctx, label: label, spec: spec ?? RowSpec(range: range, step: 1, format: format),
                     get: { c, _ in if case .text(let t) = c.content, let s = t.resolvedBubble() { return get(s) }; return range.lowerBound },
                     set: { c, v, _ in if case .text(var t) = c.content { t.editBubble { set(&$0, v) }; c.content = .text(t) } },
                     gestureName: "cmd.textBubbleEdit", testID: testID)
    }

    static func segmented(_ items: [(String, String)], selection: String?, testID: String, onSelect: @escaping (String) -> Void) -> some View {
        SegmentedTabs(items.map { (id: $0.0, title: $0.1) },
                      selection: Binding.perceived(get: { selection ?? "" }, set: { onSelect($0) }))
            .testID(testID)
    }
}

// MARK: - Shape

/// Shape picker (always shown; ⊘ removes the bubble, a shape with no bubble builds a white one), then Roundness (box)
/// or Edge (cloud / burst).
struct BubbleShapeSection: View {
    let ctx: InspectorContext

    var body: some View {
        WithPerceptionTracking {
            let s = BubbleSections.bubble(ctx)
            VStack(alignment: .leading, spacing: 6) {
                FlowLayout(spacing: 4) {
                    noneButton(selected: s == nil)
                    ForEach(TextBubbleStyle.Family.allCases, id: \.self) { f in
                        WithPerceptionTracking { shapeButton(f, selected: s?.family == f) }
                    }
                }
                .testID("text.bubble.shapes")
                if s == nil { HintText(text: tr("text.bubble.shapeHint")) }
                if let s, s.family == .box {
                    BubbleRows.row(ctx, tr("text.bubble.roundness"), "text.bubble.roundness",
                                   get: { min($0.cornerRadius, 1) * 100 }, set: { s, v in s.cornerRadius = v / 100 })
                }
                if let s, s.family.hasEdge {
                    InlineRow(label: tr("text.bubble.edge")) {
                        BubbleRows.segmented(TextBubbleStyle.Edge.allCases.map { ($0.rawValue, tr("text.bubble.edge.\($0.rawValue)")) },
                                             selection: s.edge?.rawValue, testID: "text.bubble.edge") { v in
                            guard let e = TextBubbleStyle.Edge(rawValue: v) else { return }
                            ctx.store.updateBubble { $0.setEdge(e) }
                        }
                    }
                }
            }
        }
    }

    private func chip<C: View>(selected: Bool, help: String, testID: String, @ViewBuilder _ c: () -> C, action: @escaping () -> Void) -> some View {
        c()
            .frame(width: 30, height: 22)
            .padding(3)
            .background(selected ? Theme.accentDim : IStyle.field, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .help(help)
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: help))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .testID(testID)
    }

    private func noneButton(selected: Bool) -> some View {
        chip(selected: selected, help: tr("text.bubble.shape.none"), testID: "text.bubble.shape.none") {
            Image(systemName: "nosign").font(.system(size: 13)).foregroundStyle(selected ? Theme.accentText : Theme.textSecondary)
        } action: { ctx.store.applyBubble(nil) }
    }

    private func shapeButton(_ f: TextBubbleStyle.Family, selected: Bool) -> some View {
        let size = CGSize(width: 30, height: 22)
        return chip(selected: selected, help: tr("text.bubble.family.\(f.rawValue)"), testID: "text.bubble.shape.\(f.rawValue)") {
            Path(BubbleIcons.path(f, size: size)).stroke(selected ? Theme.accentText : Theme.textSecondary, lineWidth: 1.3)
        } action: { ctx.store.updateBubble(blank: .blank(f)) { $0.setFamily(f) } }
    }
}

// MARK: - Fill / Outline / Neon / Shadow / Tail

struct BubbleFillSection: View {
    let ctx: InspectorContext
    var body: some View {
        WithPerceptionTracking {
            let s = BubbleSections.bubble(ctx)
            VStack(alignment: .leading, spacing: 4) {
                InlineRow(label: tr("inspector.color")) {
                    ColorSwatchButton(color: s.map { RGBA($0.fill.r, $0.fill.g, $0.fill.b) } ?? .white, eyedropper: ctx.store,
                                      testID: "text.bubble.fill.color") { c in
                        ctx.store.updateBubble(blank: BubbleSections.blank(.fill)) { s in s.fill = RGBA(c.r, c.g, c.b, s.fill.a > 0 ? s.fill.a : 1) }
                    }
                    Spacer()
                }
                BubbleRows.row(ctx, tr("text.bubble.opacity"), "text.bubble.opacity", format: Fmt.percentValue,
                               get: { $0.fill.a * 100 }, set: { s, v in s.fill.a = v / 100 })
            }
        }
    }
}

struct BubbleOutlineSection: View {
    let ctx: InspectorContext
    var body: some View {
        WithPerceptionTracking {
            let s = BubbleSections.bubble(ctx)
            VStack(alignment: .leading, spacing: 4) {
                InlineRow(label: tr("inspector.color")) {
                    ColorSwatchButton(color: s?.outline?.color ?? .white, eyedropper: ctx.store, testID: "text.bubble.outline.color") { c in
                        ctx.store.updateBubble(blank: BubbleSections.blank(.outline)) { s in
                            if s.outline == nil { s.outline = TextBubbleOutline(color: c) } else { s.outline?.color = c }
                        }
                    }
                    Spacer()
                }
                BubbleRows.row(ctx, tr("text.bubble.width"), "text.bubble.width",
                               get: { ($0.outline?.width ?? 0) / 0.2 * 100 }, set: { s, v in s.outline?.width = max(v, 1) / 100 * 0.2 })
                InlineRow(label: tr("text.bubble.outlineStyle")) {
                    BubbleRows.segmented(TextBubbleOutline.Dash.allCases.map { ($0.rawValue, tr("text.bubble.dash.\($0.rawValue)")) },
                                         selection: s?.outline?.dash.rawValue, testID: "text.bubble.dash") { v in
                        guard let d = TextBubbleOutline.Dash(rawValue: v) else { return }
                        ctx.store.updateBubble { $0.outline?.dash = d }
                    }
                }
            }
        }
    }
}

/// Neon tube along the outline (tube colour = outline colour): Glow, Flicker (Off / Whole / One segment).
struct BubbleNeonSection: View {
    let ctx: InspectorContext
    var body: some View {
        WithPerceptionTracking {
            let s = BubbleSections.bubble(ctx)
            VStack(alignment: .leading, spacing: 4) {
                BubbleRows.row(ctx, tr("text.bubble.glow"), "text.bubble.glow",
                               get: { ($0.outline?.neon?.glowSize ?? 0) * 100 }, set: { s, v in s.outline?.neon?.glowSize = max(v, 1) / 100 })
                InlineRow(label: tr("text.bubble.flicker")) {
                    BubbleRows.segmented(TextNeonFlicker.allCases.map { ($0.rawValue, tr("text.bubble.flicker.\($0.rawValue)")) },
                                         selection: (s?.outline?.neon?.flicker ?? .off).rawValue, testID: "text.bubble.flicker") { v in
                        guard let f = TextNeonFlicker(rawValue: v) else { return }
                        ctx.store.updateBubble { $0.outline?.neon?.flicker = f }
                    }
                }
            }
        }
    }
}

struct BubbleShadowSection: View {
    let ctx: InspectorContext
    var body: some View {
        WithPerceptionTracking {
            let sh = BubbleSections.bubble(ctx)?.shadow ?? TextBubbleShadow(color: RGBA(0, 0, 0, 0.4))
            InlineRow(label: tr("inspector.color")) {
                HStack(spacing: 10) {
                    ColorSwatchButton(color: sh.color, testID: "text.bubble.shadow.color") { c in
                        ctx.store.updateBubble { st in let a = st.shadow?.color.a ?? 1; st.shadow?.color = RGBA(c.r, c.g, c.b, a) }
                    }
                    BubbleRows.segmented(TextBubbleShadow.Kind.allCases.map { ($0.rawValue, tr("text.bubble.shadow.\($0.rawValue)")) },
                                         selection: sh.kind.rawValue, testID: "text.bubble.shadowKind") { v in
                        guard let k = TextBubbleShadow.Kind(rawValue: v) else { return }
                        ctx.store.updateBubble { $0.shadow?.kind = k }
                    }
                }
            }
        }
    }
}

/// Side pad (8 sides / corners), Point / Curve / Dots, Length.
struct BubbleTailSection: View {
    let ctx: InspectorContext
    var body: some View {
        WithPerceptionTracking {
            let tail = BubbleSections.bubble(ctx)?.tail
            VStack(alignment: .leading, spacing: 4) {
                InlineRow(label: tr("text.bubble.tail.side")) {
                    HStack(alignment: .center, spacing: 10) {
                        TailPad(side: tail?.side) { side in
                            ctx.store.updateBubble { st in
                                if let side { if st.tail == nil { st.tail = TextBubbleTail(side: side) } else { st.tail?.side = side } } else { st.tail = nil }
                            }
                        }
                        if let tail {
                            BubbleRows.segmented(TextBubbleTail.Kind.allCases.map { ($0.rawValue, tr("text.bubble.tail.\($0.rawValue)")) },
                                                 selection: tail.kind.rawValue, testID: "text.bubble.tailKind") { v in
                                guard let k = TextBubbleTail.Kind(rawValue: v) else { return }
                                ctx.store.updateBubble { $0.tail?.kind = k }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                BubbleRows.row(ctx, tr("text.bubble.tail.length"), "text.bubble.tailLength",
                               get: { ($0.tail?.length ?? 0) / 2 * 100 }, set: { s, v in s.tail?.length = max(v, 1) / 100 * 2 })
            }
        }
    }
}

/// 3×3 direction pad: 8 sides / corners, centre = no tail.
struct TailPad: View {
    let side: TextBubbleTail.Side?
    let onSelect: (TextBubbleTail.Side?) -> Void
    static let layout: [[TextBubbleTail.Side?]] = [[.topLeft, .top, .topRight], [.left, nil, .right], [.bottomLeft, .bottom, .bottomRight]]

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 2) {
                        ForEach(0..<3, id: \.self) { col in
                            WithPerceptionTracking { cell(Self.layout[row][col], row: row, col: col) }
                        }
                    }
                }
            }
            .padding(2)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 5))
        }
    }

    private func cell(_ s: TextBubbleTail.Side?, row: Int, col: Int) -> some View {
        let on = s == side
        let name = s?.rawValue ?? "none"
        return ZStack {
            RoundedRectangle(cornerRadius: 3).fill(on ? Theme.accentDim : Color.clear)
            if s == nil {
                Image(systemName: "nosign").font(.system(size: 9)).foregroundStyle(on ? Theme.accentText : Theme.textSecondary)
            } else {
                Image(systemName: "arrow.up").font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(atan2(Double(row - 1), Double(col - 1)) * 180 / .pi + 90))
                    .foregroundStyle(on ? Theme.accentText : Theme.textSecondary)
            }
        }
        .frame(width: 16, height: 16)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(s) }
        .help(tr("text.bubble.tail.side.\(name)"))
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: tr("text.bubble.tail.side.\(name)")))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .testID("text.bubble.tail.\(name)")
    }
}
