import SwiftUI
import AppKit
import ValseCore
import ValseEffects
import ValseEngine
import Perception

/// Text ▸ Bubble (TX-014, TX-BUBBLE2): group filter pills, the preset grid (None first, tiles under group headers),
/// Fill / Outline quick rows once a bubble is applied, and a "Customize" disclosure (shape, roundness, edge, tail,
/// outline style, neon, shadow, padding). Rows that don't apply to the shape are hidden. Edits apply to every selected
/// text clip (C2) and are not keyframable; editing a preset makes it "Edited", Reset brings the preset back.
struct TextBubbleSection: View {
    let ctx: InspectorContext

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
                VStack(alignment: .leading, spacing: 10) {
                    groupPills(ui)
                    grid(ui, cur: cur, edited: t?.isBubbleEdited ?? false)
                }
                .testID("text.bubble.presets")
                if let style, let t {
                    BubbleQuickRows(ctx: ctx, style: style)
                    BubbleCustomize(ctx: ctx, text: t, style: style)
                }
            }
        }
    }

    private func set(name: String, _ edit: @escaping (inout TextContent) -> Void) {
        guard let id = ctx.store.bubbleTargetClipID else { return }
        ctx.store.updateText(id, nameKey: name, edit)
    }

    // MARK: Grid

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
    private func grid(_ ui: TextUIState, cur: String?, edited: Bool) -> some View {
        let none = Tile(title: tr("anim.none"), selected: cur == nil, testID: "text.bubble.tile.none", titleLines: 2) { ctx.store.applyBubble(nil) } content: {
            Image(systemName: "nosign").font(.system(size: 26, weight: .light)).foregroundStyle(Color(white: 0.75))
        }
        // A flow of equal-width tiles (columns line up) rather than a lazy grid: every tile exists, so a group's tiles
        // are reachable right after its pill is picked even when the section is scrolled (60 cached previews).
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
        Tile(title: tr(d.nameKey), selected: cur == d.id, testID: "text.bubble.tile.\(d.id.split(separator: ".").last ?? "")", titleLines: 2) {
            ctx.store.applyBubble(d)
        } content: {
            ZStack {
                if d.previewBackdrop == .light { Color(hex: 0xD9D9D9) }
                TextPreviewImage(key: "bubble:\(d.id)", content: TextPreviewImage.bubble(d), fontPx: 30, padding: 6)
            }
        }
        .overlay(alignment: .topTrailing) {
            if cur == d.id && edited {   // "Edited" dot on the selected preset
                Circle().fill(Theme.accent).frame(width: 7, height: 7).padding(5).allowsHitTesting(false)
            }
        }
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

    /// Small "⊘ None" swatch (transparent fill / no outline).
    static func noneSwatch(selected: Bool, testID: String, action: @escaping () -> Void) -> some View {
        ZStack {
            Circle().fill(Color(white: 0.16))
            Image(systemName: "nosign").font(.system(size: 13, weight: .regular)).foregroundStyle(Color(white: 0.75))
        }
        .frame(width: 22, height: 22)
        .overlay(Circle().strokeBorder(selected ? Theme.accent : .clear, lineWidth: 1.5))
        .contentShape(Circle())
        .onTapGesture(perform: action)
        .help(tr("text.bubble.none"))
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: tr("text.bubble.none")))
        .accessibilityAddTraits(.isButton)
        .testID(testID)
    }

    static func segmented(_ items: [(String, String)], selection: String?, testID: String, onSelect: @escaping (String) -> Void) -> some View {
        SegmentedTabs(items.map { (id: $0.0, title: $0.1) },
                      selection: Binding.perceived(get: { selection ?? "" }, set: { onSelect($0) }))
            .testID(testID)
    }
}

/// Fill (⊘ None, colour, opacity) and Outline (⊘ None, colour, width) rows.
struct BubbleQuickRows: View {
    let ctx: InspectorContext
    let style: TextBubbleStyle

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 4) {
                InlineRow(label: tr("text.bubble.fill")) {
                    HStack(spacing: 8) {
                        BubbleRows.noneSwatch(selected: style.fill.a == 0, testID: "text.bubble.fill.none") {
                            ctx.store.updateBubble { $0.fill.a = 0 }
                        }
                        ColorSwatchButton(color: RGBA(style.fill.r, style.fill.g, style.fill.b), eyedropper: ctx.store, testID: "text.bubble.fill.color") { c in
                            ctx.store.updateBubble { s in s.fill = RGBA(c.r, c.g, c.b, s.fill.a > 0 ? s.fill.a : 1) }
                        }
                    }
                }
                BubbleRows.row(ctx, tr("text.bubble.opacity"), "text.bubble.opacity", format: Fmt.percentValue,
                               get: { $0.fill.a * 100 }, set: { s, v in s.fill.a = v / 100 })
                InlineRow(label: tr("text.bubble.outline")) {
                    HStack(spacing: 8) {
                        BubbleRows.noneSwatch(selected: style.outline == nil, testID: "text.bubble.outline.none") {
                            ctx.store.updateBubble { $0.outline = nil }
                        }
                        ColorSwatchButton(color: style.outline?.color ?? .white, eyedropper: ctx.store, testID: "text.bubble.outline.color") { c in
                            ctx.store.updateBubble { s in
                                if s.outline == nil { s.outline = TextBubbleOutline(color: c) } else { s.outline?.color = c }
                            }
                        }
                    }
                }
                if style.outline != nil {
                    BubbleRows.row(ctx, tr("text.bubble.width"), "text.bubble.width",
                                   get: { ($0.outline?.width ?? 0) / 0.2 * 100 }, set: { s, v in s.outline?.width = max(v, 1) / 100 * 0.2 })
                }
            }
        }
    }
}

/// "▸ Customize" disclosure: "Based on <preset> · Edited" + Reset, then the shape controls.
struct BubbleCustomize: View {
    let ctx: InspectorContext
    let text: TextContent
    let style: TextBubbleStyle

    var body: some View {
        WithPerceptionTracking {
            let ui = TextUIState.shared
            VStack(alignment: .leading, spacing: 4) {
                header(ui)
                if ui.bubbleCustomizeExpanded { controls }
            }
        }
    }

    private func header(_ ui: TextUIState) -> some View {
        HStack(spacing: 6) {
            Button { ui.bubbleCustomizeExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: ui.bubbleCustomizeExpanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                    Text(verbatim: tr("text.bubble.customize")).font(Theme.Fonts.row)
                }
                .foregroundStyle(Theme.textPrimary)
                .frame(minHeight: IStyle.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .testID("text.bubble.customize")
            Spacer(minLength: 4)
            if let d = text.bubblePreset {
                Text(verbatim: tr("text.bubble.basedOn", tr(d.nameKey)) + (text.isBubbleEdited ? " · " + tr("text.bubble.edited") : ""))
                    .font(Theme.Fonts.hint).foregroundStyle(IStyle.caption).lineLimit(1).truncationMode(.middle)
                    .testID("text.bubble.basedOn")
            }
            if text.bubbleStyle != nil {
                SmallIconButton(symbol: "arrow.counterclockwise", help: tr("text.bubble.reset")) { ctx.store.resetBubble() }
                    .testID("text.bubble.reset")
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 4) { shapeRows }.testID("text.bubble.shapeRows")
            VStack(alignment: .leading, spacing: 4) { styleRows }.testID("text.bubble.styleRows")
        }
    }

    /// Shape, Roundness, Edge, Tail.
    @ViewBuilder private var shapeRows: some View {
        let s = style
        InlineRow(label: tr("text.bubble.shape")) {
            FlowLayout(spacing: 4) {
                ForEach(TextBubbleStyle.Family.allCases, id: \.self) { f in
                    WithPerceptionTracking { shapeButton(f, selected: s.family == f) }
                }
            }
        }
        if s.family == .box {
            BubbleRows.row(ctx, tr("text.bubble.roundness"), "text.bubble.roundness",
                           get: { min($0.cornerRadius, 1) * 100 }, set: { s, v in s.cornerRadius = v / 100 })
        }
        if s.family.hasEdge {
            InlineRow(label: tr("text.bubble.edge")) {
                BubbleRows.segmented(TextBubbleStyle.Edge.allCases.map { ($0.rawValue, tr("text.bubble.edge.\($0.rawValue)")) },
                                     selection: s.edge?.rawValue, testID: "text.bubble.edge") { v in
                    guard let e = TextBubbleStyle.Edge(rawValue: v) else { return }
                    ctx.store.updateBubble { $0.setEdge(e) }
                }
            }
        }
        if s.family.hasTail {
            InlineRow(label: tr("text.bubble.tail")) {
                HStack(alignment: .center, spacing: 10) {
                    TailPad(side: s.tail?.side) { side in
                        ctx.store.updateBubble { st in
                            if let side { if st.tail == nil { st.tail = TextBubbleTail(side: side) } else { st.tail?.side = side } } else { st.tail = nil }
                        }
                    }
                    if let tail = s.tail {
                        BubbleRows.segmented(TextBubbleTail.Kind.allCases.map { ($0.rawValue, tr("text.bubble.tail.\($0.rawValue)")) },
                                             selection: tail.kind.rawValue, testID: "text.bubble.tailKind") { v in
                            guard let k = TextBubbleTail.Kind(rawValue: v) else { return }
                            ctx.store.updateBubble { $0.tail?.kind = k }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            if s.tail != nil {
                BubbleRows.row(ctx, tr("text.bubble.tail.length"), "text.bubble.tailLength",
                               get: { ($0.tail?.length ?? 0) / 2 * 100 }, set: { s, v in s.tail?.length = max(v, 1) / 100 * 2 })
            }
        }
    }

    /// Outline style, Neon, Shadow, Padding.
    @ViewBuilder private var styleRows: some View {
        let s = style
        if let o = s.outline {
            InlineRow(label: tr("text.bubble.outlineStyle")) {
                BubbleRows.segmented(TextBubbleOutline.Dash.allCases.map { ($0.rawValue, tr("text.bubble.dash.\($0.rawValue)")) },
                                     selection: o.dash.rawValue, testID: "text.bubble.dash") { v in
                    guard let d = TextBubbleOutline.Dash(rawValue: v) else { return }
                    ctx.store.updateBubble { $0.outline?.dash = d }
                }
            }
        }
        ToggleLine(label: tr("text.bubble.neon"), isOn: Binding.perceived(get: { s.outline?.neon != nil }, set: { on in
            ctx.store.updateBubble { st in
                if on {
                    if st.outline == nil { st.outline = TextBubbleOutline(color: TextNeonStyle.swatches[0].color) }
                    let n = st.outline?.neon ?? TextBubbleOutline.neonStyle()
                    st.outline?.neon = n
                } else { st.outline?.neon = nil }
            }
        }))
        .testID("text.bubble.neon")
        if let n = s.outline?.neon {
            BubbleRows.row(ctx, tr("text.bubble.glow"), "text.bubble.glow",
                           get: { ($0.outline?.neon?.glowSize ?? 0) * 100 }, set: { s, v in s.outline?.neon?.glowSize = max(v, 1) / 100 })
            ToggleLine(label: tr("text.bubble.flicker"), isOn: Binding.perceived(get: { n.flicker != .off }, set: { on in
                ctx.store.updateBubble { $0.outline?.neon?.flicker = on ? .oneLetter : .off }   // the tube stutters as one faulty segment
            }))
            .testID("text.bubble.flicker")
        }
        ToggleLine(label: tr("text.bubble.shadow"), isOn: Binding.perceived(get: { s.shadow != nil }, set: { on in
            ctx.store.updateBubble { $0.shadow = on ? ($0.shadow ?? TextBubbleShadow(color: RGBA(0, 0, 0, 0.4))) : nil }
        }))
        .testID("text.bubble.shadow")
        if let sh = s.shadow {
            InlineRow(label: "") {
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
        InlineRow(label: tr("text.bubble.padding")) { EmptyView() }
        BubblePaddingRows(ctx: ctx, style: s)
    }

    private func shapeButton(_ f: TextBubbleStyle.Family, selected: Bool) -> some View {
        let size = CGSize(width: 30, height: 22)
        return Path(BubbleIcons.path(f, size: size))
            .stroke(selected ? Theme.accentText : Theme.textSecondary, lineWidth: 1.3)
            .frame(width: size.width, height: size.height)
            .padding(3)
            .background(selected ? Theme.accentDim : IStyle.field, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture { ctx.store.updateBubble { $0.setFamily(f) } }
            .help(tr("text.bubble.family.\(f.rawValue)"))
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: tr("text.bubble.family.\(f.rawValue)")))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .testID("text.bubble.shape.\(f.rawValue)")
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
