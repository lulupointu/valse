import SwiftUI
import AppKit
import MontageCore
import MontageEffects
import MontageEngine
import Perception

/// Text clip inspector (UX.md §5.2, screenshots 74/76/77/127/129): Text [Basic · Bubble · Effects] with the content
/// editor, font, size, style, case, colour, spacing, alignment, presets row, Position & Size, Opacity and the optional
/// Stroke / Background / Glow / Shadow / Curve sections; a Captions tab for caption clips; footer "Save as preset".
@MainActor
enum TextInspector {
    static func isText(_ ctx: InspectorContext) -> Bool { ctx.kind == .text }
    static func isCaption(_ ctx: InspectorContext) -> Bool { ctx.clip.map(CaptionOps.isCaption) ?? false }
    static func isTemplate(_ ctx: InspectorContext) -> Bool { text(ctx)?.template != nil }
    static func text(_ ctx: InspectorContext) -> TextContent? { if case .text(let t) = ctx.clip?.content { return t }; return nil }

    static let textTab = InspectorTab(id: "text", titleKey: "inspector.tab.text", order: 0, subTabs: [
        InspectorSubTab(id: "basic", titleKey: "inspector.sub.basic", order: 0),
        // OB-10: the word-art library is "Templates" (was "Effects"); for captions its first category is "Caption"
        // (the caption templates, formerly their own sub-tab)
        InspectorSubTab(id: "templates", titleKey: "text.sub.templates", order: 1),
        // OB-10c: manual controls for what caption templates do to the spoken word, captions only
        InspectorSubTab(id: "spokenWord", titleKey: "text.sub.spokenWord", order: 2, appliesTo: isCaption),
        // OB-10 (owner): Bubble is the rightmost sub-tab
        InspectorSubTab(id: "bubble", titleKey: "text.sub.bubble", order: 3),
    ], footer: { ctx, _ in
        AnyView(PillButton(title: tr("inspector.saveAsPreset"), accent: true) { ctx.store.saveTextPreset() })
    }, appliesTo: { $0.kind == .text })

    /// Captions comes first for caption clips (CapCut: Captions | Text | Animation | …). CAP-EDITOR-UX: shown whenever
    /// the project has captions (after Details with nothing selected, last for other clips).
    static let captionsTab: InspectorTab = {
        var t = InspectorTab(id: "captions", titleKey: "captions.tab", order: -1, appliesTo: { isCaption($0) || hasCaptions($0) })
        t.dynamicOrder = { ctx in isCaption(ctx) || ctx.store.selectedClipsSlice.contains(where: CaptionOps.isCaption) ? -1 : (ctx.kind == .none ? -1 : 100) }
        return t
    }()
    static func hasCaptions(_ ctx: InspectorContext) -> Bool { !CaptionOps.captionTracks(ctx.store.project.timeline).isEmpty }

    static let tabs = [textTab, captionsTab]

    static let sections: [InspectorSection] = [
        InspectorSection(id: "text.applyAllCaptions", tab: "text", subTab: "basic", order: -1, titleKey: nil,
                         appliesTo: isCaption) { AnyView(ApplyToAllCaptionsRow(ctx: $0)) },
        InspectorSection(id: "text.content", tab: "text", subTab: "basic", order: 0, titleKey: nil) { AnyView(TextBasicSection(ctx: $0)) },
        InspectorSection(id: "text.template", tab: "text", subTab: "basic", order: 5, titleKey: "text.template.section",
                         appliesTo: isTemplate) { AnyView(TextTemplateSection(ctx: $0)) },
        InspectorSection(id: "text.template.tools", tab: "text", subTab: "basic", order: 6, titleKey: nil,
                         appliesTo: isTemplate) { AnyView(TextTemplateToolsSection(ctx: $0)) },
        InspectorSection(id: "text.counter", tab: "text", subTab: "basic", order: 8, titleKey: "counter.section",
                         appliesTo: { !isCaption($0) }, chrome: TextCounterSection.chrome) { AnyView(TextCounterSection(ctx: $0)) },
        InspectorSection(id: "text.transform", tab: "text", subTab: "basic", order: 10, titleKey: "inspector.transform",
                         chrome: TransformSection.chrome) { AnyView(TransformSection(ctx: $0, rotateLabelKey: "inspector.planeRotation")) },
        InspectorSection(id: "text.opacity", tab: "text", subTab: "basic", order: 20, titleKey: nil) { AnyView(OpacityRow(ctx: $0)) },
        InspectorSection(id: "text.stroke", tab: "text", subTab: "basic", order: 30, titleKey: "text.stroke",
                         chrome: TextStrokeSection.chrome) { AnyView(TextStrokeSection(ctx: $0)) },
        InspectorSection(id: "text.background", tab: "text", subTab: "basic", order: 40, titleKey: "text.background",
                         chrome: TextBackgroundSection.chrome) { AnyView(TextBackgroundSection(ctx: $0)) },
        InspectorSection(id: "text.glow", tab: "text", subTab: "basic", order: 50, titleKey: "text.glow",
                         chrome: TextGlowSection.chrome) { AnyView(TextGlowSection(ctx: $0)) },
        InspectorSection(id: "text.shadow", tab: "text", subTab: "basic", order: 60, titleKey: "text.shadow",
                         chrome: TextShadowSection.chrome) { AnyView(TextShadowSection(ctx: $0)) },
        InspectorSection(id: "text.curve", tab: "text", subTab: "basic", order: 70, titleKey: "text.curve",
                         chrome: TextCurveSection.chrome) { AnyView(TextCurveSection(ctx: $0)) },
        InspectorSection(id: "text.bubble", tab: "text", subTab: "bubble", order: 0, titleKey: nil) { AnyView(TextBubbleSection(ctx: $0)) },
        InspectorSection(id: "text.templates", tab: "text", subTab: "templates", order: 0, titleKey: nil) { AnyView(TextEffectsSection(ctx: $0)) },
        {
            var s = InspectorSection(id: "captions.list", tab: "captions", order: 0, titleKey: nil) { AnyView(CaptionEditorSection(ctx: $0)) }
            s.ownsScroll = true
            return s
        }(),
        InspectorSection(id: "captions.spokenWord", tab: "text", subTab: "spokenWord", order: 0, titleKey: "spokenWord.section",
                         appliesTo: isCaption, chrome: CaptionSpokenWordSection.chrome) { AnyView(CaptionSpokenWordSection(ctx: $0)) },
    ]

    // MARK: Row helpers

    /// Numeric row on a `TextContent` value (UI units), coalesced into one undo step per drag.
    static func row(_ ctx: InspectorContext, _ label: String, range: ClosedRange<Double>, step: Double = 1,
                    format: @escaping (Double) -> String = { String(Int($0.rounded())) }, origin: Double? = nil,
                    get: @escaping (TextContent) -> Double, set: @escaping (inout TextContent, Double) -> Void) -> ClipParamRow {
        ClipParamRow(ctx: ctx, label: label, spec: RowSpec(range: range, origin: origin, step: step, format: format),
                     get: { c, _ in if case .text(let t) = c.content { return get(t) }; return range.lowerBound },
                     set: { c, v, _ in if case .text(var t) = c.content { set(&t, v); c.content = .text(t) } },
                     gestureName: "cmd.text")
    }

    static func colorRow(_ ctx: InspectorContext, _ label: String, get: @escaping (TextContent) -> RGBA,
                         set: @escaping (inout TextContent, RGBA) -> Void) -> some View {
        InlineRow(label: label) {
            ColorSwatchButton(color: text(ctx).map(get) ?? .white, eyedropper: ctx.store) { col in
                guard let id = ctx.clip?.id else { return }
                ctx.store.updateText(id) { set(&$0, col) }
            }
            Spacer()
        }
    }

    static func binding<V>(_ ctx: InspectorContext, get: @escaping (TextContent) -> V, set: @escaping (inout TextContent, V) -> Void,
                           default d: V) -> Binding<V> {
        Bind.binding(ctx, "cmd.text", get: { c in if case .text(let t) = c.content { return get(t) }; return d },
                     set: { c, v in if case .text(var t) = c.content { set(&t, v); c.content = .text(t) } }, default: d)
    }

    static func chrome(_ ctx: InspectorContext, isOn: @escaping (TextContent) -> Bool, toggle: @escaping (inout TextContent, Bool) -> Void,
                       reset: @escaping (inout TextContent) -> Void) -> InspectorSectionChrome {
        InspectorSectionChrome(
            isEnabled: Binding.perceived(get: { text(ctx).map(isOn) ?? false }, set: { v in
                guard let id = ctx.clip?.id else { return }
                ctx.store.updateText(id) { toggle(&$0, v) }
            }),
            reset: {
                guard let id = ctx.clip?.id else { return }
                ctx.store.updateText(id) { reset(&$0) }
            })
    }
}

// MARK: - Basic

struct TextBasicSection: View {
    let ctx: InspectorContext

    var body: some View {
        WithPerceptionTracking {
            let store = ctx.store
            if let clip = ctx.clip, case .text(let t) = clip.content {
                VStack(alignment: .leading, spacing: 6) {
                    // C2: several text clips edited together share the style, not the words (no text box)
                    if !ctx.isMulti {
                    ClipTextEditor(store: store, clipID: clip.id)
                        .id(clip.id)
                        .testID("text.editor")
                        .frame(height: 64)
                        .background(IStyle.field, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(alignment: .bottomTrailing) {   // AI2 TX-034: dictate into the text clip
                            DictateButton(text: store.dictationBinding(for: clip.id), testID: "text.dictate",
                                          onStart: { store.beginGesture("cmd.dictate") }, onEnd: { store.endGesture() })
                                .padding(2)
                        }
                        .padding(.bottom, 4)
                    }
                    FontRow(ctx: ctx)
                    TextInspector.row(ctx, tr("text.fontSize"), range: 1...300, get: { $0.fontSize * 250 }, set: { t, v in t.fontSize = v / 250 })
                    InlineRow(label: tr("text.style")) {
                        HStack(spacing: 8) {
                            styleButton("bold", "bold", on: style(t).bold ?? false) { TextRunStyle(bold: !$0) }
                            styleButton("underline", "underline", on: style(t).underline ?? false) { TextRunStyle(underline: !$0) }
                            styleButton("italic", "italic", on: style(t).italic ?? false) { TextRunStyle(italic: !$0) }
                        }
                    }
                    InlineRow(label: tr("text.case")) {
                        HStack(spacing: 0) {
                            caseButton("TT", .upper, t); caseButton("tt", .lower, t); caseButton("Tt", .title, t)
                        }
                        .background(IStyle.strip, in: RoundedRectangle(cornerRadius: 4))
                    }
                    InlineRow(label: tr("inspector.color"), triplet: Bind.triplet(ctx, [.textColor])) {
                        ColorSwatchButton(color: style(t).color ?? t.color, eyedropper: store, testID: "text.color") { col in
                            guard let sel = TextUIState.shared.selection[clip.id], sel.length > 0, sel.length < t.utf16Count else {
                                let local = ctx.localTime
                                store.performInspector(UpdateClip(clip.id, nameKey: "cmd.text") { $0.setValue(.textColor, .color(col), at: local) })
                                return
                            }
                            store.applyTextRunStyle(clip.id, TextRunStyle(color: col))
                        }
                    }
                    InlineRow(label: tr("text.character")) {
                        HStack(spacing: 12) {
                            ClipNumberField(ctx: ctx, spec: RowSpec(range: -20...100, format: Fmt.int),
                                            get: { c, _ in if case .text(let t) = c.content { return t.letterSpacing * 20 }; return 0 },
                                            set: { c, v, _ in if case .text(var t) = c.content { t.letterSpacing = v / 20; c.content = .text(t) } },
                                            gestureName: "cmd.text")
                            Text(loc: "text.line").font(Theme.Fonts.row).foregroundStyle(IStyle.label)
                            ClipNumberField(ctx: ctx, spec: RowSpec(range: -20...100, format: Fmt.int),
                                            get: { c, _ in if case .text(let t) = c.content { return t.lineSpacing * 20 }; return 0 },
                                            set: { c, v, _ in if case .text(var t) = c.content { t.lineSpacing = v / 20; c.content = .text(t) } },
                                            gestureName: "cmd.text")
                        }
                    }
                    InlineRow(label: tr("text.alignment")) { TextAlignmentStrip(ctx: ctx, text: t) }
                    TextPresetRow(ctx: ctx, current: t.styleID)
                }
            }
        }
    }

    func style(_ t: TextContent) -> TextRunStyle {
        guard let id = ctx.clip?.id, let sel = TextUIState.shared.selection[id], sel.length > 0 else { return t.baseRunStyle }
        return t.commonStyle(in: sel)
    }

    func styleButton(_ name: String, _ symbol: String, on: Bool, _ make: @escaping (Bool) -> TextRunStyle) -> some View {
        Button {
            guard let id = ctx.clip?.id else { return }
            ctx.store.applyTextRunStyle(id, make(on))
        } label: {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? Theme.accent : Theme.textPrimary)
                .frame(width: 28, height: 28)
                .background(on ? Theme.accentDim.opacity(0.5) : IStyle.strip, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(tr("inspector.\(name)"))
    }

    func caseButton(_ label: String, _ c: TextCase, _ t: TextContent) -> some View {
        let on = t.textCase == c
        return Text(verbatim: label).font(.system(size: 12, weight: .semibold))
            .foregroundStyle(on ? Theme.accent : Theme.textPrimary)
            .frame(width: 34, height: 26)
            .background(on ? Theme.segmentSelected : .clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture {
                guard let id = ctx.clip?.id else { return }
                ctx.store.updateText(id) { $0.textCase = $0.textCase == c ? .none : c }
            }
            .help(tr("text.case.\(c.rawValue)"))
            .accessibilityAddTraits(.isButton)
    }
}

/// Left · centre · right · justify, then vertical text top · centre · bottom (CapCut's 6 alignment buttons + justify).
struct TextAlignmentStrip: View {
    let ctx: InspectorContext
    let text: TextContent
    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 0) {
                button("text.alignleft", .left, .horizontal, "text.align.left")
                button("text.aligncenter", .center, .horizontal, "text.align.center")
                button("text.alignright", .right, .horizontal, "text.align.right")
                button("text.justify", .justify, .horizontal, "text.align.justify")
                Rectangle().fill(Theme.separator).frame(width: 1, height: 16).padding(.horizontal, 2)
                button("align.vertical.top", .left, .vertical, "text.align.vTop")
                button("align.vertical.center", .center, .vertical, "text.align.vCenter")
                button("align.vertical.bottom", .right, .vertical, "text.align.vBottom")
            }
            .background(IStyle.strip, in: RoundedRectangle(cornerRadius: 4))
        }
    }

    func button(_ symbol: String, _ a: MontageCore.TextAlignment, _ o: TextOrientation, _ help: String) -> some View {
        let on = text.alignment == a && text.orientation == o
        return Image(systemName: symbol).font(.system(size: 12))
            .foregroundStyle(on ? Theme.accent : Theme.textPrimary.opacity(0.85))
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
            .onTapGesture {
                guard let id = ctx.clip?.id else { return }
                ctx.store.updateText(id) { $0.alignment = a; $0.orientation = o }
            }
            .help(tr(help))
            .accessibilityAddTraits(.isButton)
    }
}

/// ⊘ + "Aa" style preset tiles in two collapsible rows (UX.md §5.2, screenshot 76).
struct TextPresetRow: View {
    let ctx: InspectorContext
    let current: String?
    var body: some View {
        WithPerceptionTracking {
            let ui = TextUIState.shared
            let presets = Registries.textStyles(.preset)
            let shown = ui.presetsExpanded ? presets : Array(presets.prefix(9))
            VStack(spacing: 4) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 40, maximum: 48), spacing: 6)], spacing: 6) {
                    tile(selected: current == nil || current == "montage.text.default") {
                        Image(systemName: "nosign").font(.system(size: 18, weight: .light)).foregroundStyle(Color(white: 0.75))
                    } action: { ctx.store.applyTextStyle(presets[0]) }
                    ForEach(shown.dropFirst()) { d in
                        WithPerceptionTracking {
                            tile(selected: current == d.id) {
                                TextPreviewImage(key: "preset:\(d.id)", content: TextPreviewImage.style(d, sample: "Aa"), fontPx: 40, padding: 4)
                            } action: { ctx.store.applyTextStyle(d) }
                            .help(d.displayName)
                        }
                    }
                }
                Button { ui.presetsExpanded.toggle() } label: {
                    Image(systemName: ui.presetsExpanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 14).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
            }
            .padding(.top, 6)
        }
    }

    func tile<C: View>(selected: Bool, @ViewBuilder _ c: () -> C, action: @escaping () -> Void) -> some View {
        ZStack { RoundedRectangle(cornerRadius: 6).fill(IStyle.tile); c() }
            .frame(width: 44, height: 44)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Template

/// Template clips: one field per text slot, and the other templates to switch to (text is kept).
struct TextTemplateSection: View {
    let ctx: InspectorContext
    var body: some View {
        WithPerceptionTracking {
            if let clip = ctx.clip, case .text(let t) = clip.content, let inst = t.template {
                let d = Registries.textTemplates[inst.templateID]
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(1..<max(d?.slotKeys.count ?? 1, 1), id: \.self) { i in
                        WithPerceptionTracking {
                            TextField(tr("text.template.slot", i + 1), text: Binding.perceived(
                                get: { TextTemplateDescriptor.text(slot: i, of: t, descriptor: d) },
                                set: { v in
                                    ctx.store.updateText(clip.id, nameKey: "cmd.text") { tt in
                                        var texts = tt.template?.texts ?? []
                                        while texts.count < i { texts.append(d.map { TextTemplateDescriptor.text(slot: texts.count + 1, of: tt, descriptor: $0) } ?? "") }
                                        texts[i - 1] = v
                                        tt.template?.texts = texts
                                    }
                                }))
                                .textFieldStyle(.plain).font(.system(size: 13))
                                .padding(8).background(IStyle.field, in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    Text(loc: "text.template.change").font(.system(size: 12, weight: .medium)).foregroundStyle(IStyle.caption)
                    TileGrid {
                        ForEach(Registries.textTemplates.all) { o in
                            WithPerceptionTracking {
                                Tile(title: tr(o.nameKey), selected: o.id == inst.templateID) { ctx.store.changeTemplate(clip.id, to: o) } content: {
                                    TextPreviewImage(key: "template:\(o.id)", content: o.makeContent(), fontPx: 36, padding: 4)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Optional style sections

struct TextStrokeSection: View {
    let ctx: InspectorContext
    static func chrome(_ ctx: InspectorContext) -> InspectorSectionChrome {
        TextInspector.chrome(ctx, isOn: { $0.strokeWidth > 0 || !$0.extraStrokes.isEmpty },
                             toggle: { t, on in t.strokeWidth = on ? 0.08 : 0; if !on { t.extraStrokes = [] } },
                             reset: { t in t.strokeWidth = 0.08; t.strokeColor = .black; t.extraStrokes = [] })
    }
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 4) {
                TextInspector.colorRow(ctx, tr("inspector.color"), get: { $0.strokeColor }, set: { $0.strokeColor = $1 })
                TextInspector.row(ctx, tr("text.stroke.width"), range: 0...100, get: { $0.strokeWidth / 0.3 * 100 }, set: { t, v in t.strokeWidth = v / 100 * 0.3 })
                InlineRow(label: tr("text.stroke.position")) {
                    SegmentedTabs(TextStrokePosition.allCases.map { ($0.rawValue, tr("text.stroke.position.\($0.rawValue)")) },
                                  selection: Binding.perceived(get: { (TextInspector.text(ctx)?.strokePosition ?? .outside).rawValue }, set: { v in
                                      guard let id = ctx.clip?.id, let p = TextStrokePosition(rawValue: v) else { return }
                                      ctx.store.updateText(id) { $0.strokePosition = p }
                                  }))
                    .testID("text.stroke.position")
                }
                if let t = TextInspector.text(ctx) {
                    ForEach(Array(t.extraStrokes.enumerated()), id: \.offset) { i, s in
                        WithPerceptionTracking {
                            HStack(spacing: 8) {
                                Text(verbatim: tr("text.stroke.layer", i + 2)).font(Theme.Fonts.row).foregroundStyle(IStyle.label)
                                    .frame(width: IStyle.labelWidth, alignment: .leading)
                                ColorSwatchButton(color: s.color, eyedropper: ctx.store) { col in
                                    guard let id = ctx.clip?.id else { return }
                                    ctx.store.updateText(id) { if i < $0.extraStrokes.count { $0.extraStrokes[i].color = col } }
                                }
                                TextInspector.row(ctx, "", range: 0...100, get: { i < $0.extraStrokes.count ? $0.extraStrokes[i].width / 0.4 * 100 : 0 },
                                                  set: { t, v in if i < t.extraStrokes.count { t.extraStrokes[i].width = v / 100 * 0.4 } })
                                SmallIconButton(symbol: "minus.circle", help: tr("text.stroke.remove")) {
                                    guard let id = ctx.clip?.id else { return }
                                    ctx.store.updateText(id) { if i < $0.extraStrokes.count { $0.extraStrokes.remove(at: i) } }
                                }
                            }
                        }
                    }
                    if t.extraStrokes.count < 3 {
                        PillButton(title: tr("text.stroke.add"), symbol: "plus") {
                            guard let id = ctx.clip?.id else { return }
                            ctx.store.updateText(id) { tt in
                                let w = max(tt.strokeWidth, tt.extraStrokes.map(\.width).max() ?? 0) + 0.08
                                tt.extraStrokes.append(TextStrokeLayer(color: tt.extraStrokes.isEmpty ? .white : .black, width: w))
                            }
                        }
                    }
                }
            }
        }
    }
}

struct TextBackgroundSection: View {
    let ctx: InspectorContext
    static func chrome(_ ctx: InspectorContext) -> InspectorSectionChrome {
        TextInspector.chrome(ctx, isOn: { $0.backgroundColor.a > 0 },
                             toggle: { t, on in
                                 if on { t.backgroundColor = t.backgroundColor == .clear ? .black : RGBA(t.backgroundColor.r, t.backgroundColor.g, t.backgroundColor.b, 1) }
                                 else { t.backgroundColor.a = 0 }
                             },
                             reset: { t in t.backgroundColor = .black; t.background = TextBackgroundStyle() })
    }
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 4) {
                TextInspector.colorRow(ctx, tr("inspector.color"), get: { RGBA($0.backgroundColor.r, $0.backgroundColor.g, $0.backgroundColor.b) },
                                       set: { t, c in t.backgroundColor = RGBA(c.r, c.g, c.b, max(t.backgroundColor.a, 0.01)) })
                InlineRow(label: tr("text.background.mode")) {
                    Dropdown(items: TextBackgroundMode.allCases.map { ($0, tr("text.background.mode.\($0.rawValue)")) },
                             selection: TextInspector.text(ctx)?.background.mode ?? .block) { m in
                        guard let id = ctx.clip?.id else { return }
                        ctx.store.updateText(id) { $0.background.mode = m }
                    }
                }
                TextInspector.row(ctx, tr("prop.opacity"), range: 0...100, format: Fmt.percentValue,
                                  get: { $0.backgroundColor.a * 100 }, set: { t, v in t.backgroundColor.a = max(v / 100, 0.01) })
                TextInspector.row(ctx, tr("text.background.radius"), range: 0...100, get: { $0.background.cornerRadius * 100 }, set: { $0.background.cornerRadius = $1 / 100 })
                TextInspector.row(ctx, tr("text.background.height"), range: 0...100, get: { $0.background.paddingY / 0.6 * 100 }, set: { $0.background.paddingY = $1 / 100 * 0.6 })
                TextInspector.row(ctx, tr("text.background.width"), range: 0...100, get: { $0.background.paddingX / 1.0 * 100 }, set: { $0.background.paddingX = $1 / 100 })
                InlineRow(label: tr("text.background.offset")) {
                    HStack(spacing: 14) {
                        ClipNumberField(ctx: ctx, prefix: "X", spec: RowSpec(range: -100...100, format: Fmt.int),
                                        get: { c, _ in if case .text(let t) = c.content { return t.background.offset.x * 100 }; return 0 },
                                        set: { c, v, _ in if case .text(var t) = c.content { t.background.offset.x = v / 100; c.content = .text(t) } }, gestureName: "cmd.text")
                        ClipNumberField(ctx: ctx, prefix: "Y", spec: RowSpec(range: -100...100, format: Fmt.int),
                                        get: { c, _ in if case .text(let t) = c.content { return -t.background.offset.y * 100 }; return 0 },
                                        set: { c, v, _ in if case .text(var t) = c.content { t.background.offset.y = -v / 100; c.content = .text(t) } }, gestureName: "cmd.text")
                    }
                }
            }
        }
    }
}

struct TextGlowSection: View {
    let ctx: InspectorContext
    static func chrome(_ ctx: InspectorContext) -> InspectorSectionChrome {
        TextInspector.chrome(ctx, isOn: { $0.glow != nil },
                             toggle: { t, on in t.glow = on ? (t.glow ?? TextGlowStyle(color: t.color == .white ? RGBA(hex: 0x57BECB) : t.color)) : nil },
                             reset: { t in t.glow = TextGlowStyle(color: RGBA(hex: 0x57BECB)) })
    }
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 4) {
                TextInspector.colorRow(ctx, tr("inspector.color"), get: { $0.glow?.color ?? .white }, set: { $0.glow?.color = $1 })
                InlineRow(label: tr("text.glow.mode")) {
                    Dropdown(items: TextGlowMode.allCases.map { ($0, tr("text.glow.mode.\($0.rawValue)")) },
                             selection: TextInspector.text(ctx)?.glow?.mode ?? .outer) { m in
                        guard let id = ctx.clip?.id else { return }
                        ctx.store.updateText(id) { $0.glow?.mode = m }
                    }
                }
                TextInspector.row(ctx, tr("text.glow.intensity"), range: 0...100, get: { ($0.glow?.intensity ?? 0) * 100 }, set: { $0.glow?.intensity = $1 / 100 })
                TextInspector.row(ctx, tr("text.glow.range"), range: 0...100, get: { ($0.glow?.radius ?? 0) / 0.6 * 100 }, set: { $0.glow?.radius = $1 / 100 * 0.6 })
            }
        }
    }
}

struct TextShadowSection: View {
    let ctx: InspectorContext
    static func chrome(_ ctx: InspectorContext) -> InspectorSectionChrome {
        TextInspector.chrome(ctx, isOn: { $0.shadowColor.a > 0 },
                             toggle: { t, on in t.shadowColor = on ? (t.shadowColor.a > 0 ? t.shadowColor : RGBA(0, 0, 0, 0.8)) : RGBA(t.shadowColor.r, t.shadowColor.g, t.shadowColor.b, 0) },
                             reset: { t in t.shadowColor = RGBA(0, 0, 0, 0.8); t.shadow = TextShadowStyle() })
    }
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 4) {
                TextInspector.colorRow(ctx, tr("inspector.color"), get: { RGBA($0.shadowColor.r, $0.shadowColor.g, $0.shadowColor.b) },
                                       set: { t, c in t.shadowColor = RGBA(c.r, c.g, c.b, max(t.shadowColor.a, 0.01)) })
                TextInspector.row(ctx, tr("prop.opacity"), range: 0...100, format: Fmt.percentValue,
                                  get: { $0.shadowColor.a * 100 }, set: { $0.shadowColor.a = max($1 / 100, 0.01) })
                TextInspector.row(ctx, tr("text.shadow.blur"), range: 0...100, get: { $0.shadow.blur / 0.5 * 100 }, set: { $0.shadow.blur = $1 / 100 * 0.5 })
                TextInspector.row(ctx, tr("text.shadow.distance"), range: 0...100, get: { $0.shadow.distance / 0.4 * 100 }, set: { $0.shadow.distance = $1 / 100 * 0.4 })
                TextInspector.row(ctx, tr("text.shadow.angle"), range: -180...180, format: Fmt.degrees1, origin: 0,
                                  get: { $0.shadow.angle > 180 ? $0.shadow.angle - 360 : $0.shadow.angle }, set: { $0.shadow.angle = $1 })
                ToggleLine(label: tr("text.shadow.3d"), isOn: TextInspector.binding(ctx, get: { $0.shadow.extrude }, set: { $0.shadow.extrude = $1 }, default: false))
            }
        }
    }
}

struct TextCurveSection: View {
    let ctx: InspectorContext
    static func chrome(_ ctx: InspectorContext) -> InspectorSectionChrome {
        TextInspector.chrome(ctx, isOn: { $0.curve != 0 || $0.path != nil },
                             toggle: { t, on in if on { t.curve = 0.3 } else { t.curve = 0; t.path = nil } },
                             reset: { t in t.curve = 0.3; t.path = nil })
    }
    static let shapes: [TextPathShape.Kind?] = [nil, .circle, .wave, .arch, .spiral]
    var body: some View {
        WithPerceptionTracking {
            let t = TextInspector.text(ctx)
            VStack(alignment: .leading, spacing: 4) {
                InlineRow(label: tr("text.curve.shape")) {
                    Dropdown(items: Self.shapes.map { ($0?.rawValue ?? "arc", tr("text.curve.shape.\($0?.rawValue ?? "arc")")) },
                             selection: t?.path?.kind.rawValue ?? "arc") { k in
                        guard let id = ctx.clip?.id else { return }
                        ctx.store.updateText(id) { tt in
                            if let kind = TextPathShape.Kind(rawValue: k) { tt.path = TextPathShape(kind, amount: tt.path?.amount ?? 0.5) }
                            else { tt.path = nil; if tt.curve == 0 { tt.curve = 0.3 } }
                        }
                    }
                }
                if t?.path == nil {
                    TextInspector.row(ctx, tr("text.curve.amount"), range: -100...100, origin: 0, get: { $0.curve * 100 }, set: { $0.curve = $1 / 100 })
                } else {
                    TextInspector.row(ctx, tr("text.curve.amount"), range: 0...100, get: { ($0.path?.amount ?? 0) * 100 }, set: { $0.path?.amount = $1 / 100 })
                }
            }
        }
    }
}

// MARK: - Bubble / Effects sub-tabs

struct TextBubbleSection: View {
    let ctx: InspectorContext
    var body: some View {
        WithPerceptionTracking {
            let cur = TextInspector.text(ctx)?.bubbleID
            VStack(alignment: .leading, spacing: 10) {
                TileGrid {
                    Tile(title: tr("anim.none"), selected: cur == nil) { ctx.store.applyBubble(nil) } content: {
                        Image(systemName: "nosign").font(.system(size: 26, weight: .light)).foregroundStyle(Color(white: 0.75))
                    }
                    ForEach(Registries.textBubbles.all) { d in
                        WithPerceptionTracking {
                            Tile(title: tr(d.nameKey), selected: cur == d.id) { ctx.store.applyBubble(d) } content: {
                                TextPreviewImage(key: "bubble:\(d.id)", content: TextPreviewImage.bubble(d), fontPx: 30, padding: 6)
                            }
                        }
                    }
                }
                if cur != nil {
                    TextInspector.colorRow(ctx, tr("text.bubble.color"), get: { t in t.bubbleColor ?? Registries.textBubbles[t.bubbleID ?? ""]?.fill ?? .white },
                                           set: { $0.bubbleColor = $1 })
                }
            }
        }
    }
}

/// Text ▸ Templates (OB-10, was "Effects"): the word-art library (same as the asset panel's Text effects), searchable,
/// grouped; for captions the first category is "Caption" (the caption templates, C4).
struct TextEffectsSection: View {
    let ctx: InspectorContext
    var body: some View {
        WithPerceptionTracking {
            let ui = TextUIState.shared
            let cur = TextInspector.text(ctx)?.styleID
            let q = ui.effectSearch.trimmingCharacters(in: .whitespaces).lowercased()
            VStack(alignment: .leading, spacing: 10) {
                SearchField(text: Binding.perceived(get: { ui.effectSearch }, set: { ui.effectSearch = $0 }), placeholder: tr("text.effects.search"))
                if TextInspector.isCaption(ctx) {
                    CaptionTemplatesSection(ctx: ctx, query: q)
                }
                ForEach(BuiltinTextStyles.effectGroups, id: \.self) { g in
                    WithPerceptionTracking {
                        let items = Registries.textStyles(.effect).filter { $0.groupKey == g && (q.isEmpty || $0.displayName.lowercased().contains(q) || tr(g).lowercased().contains(q)) }
                        if !items.isEmpty {
                            Text(verbatim: tr(g)).font(.system(size: 12, weight: .medium)).foregroundStyle(IStyle.caption)
                            TileGrid {
                                ForEach(items) { d in
                                    WithPerceptionTracking {
                                        Tile(title: d.displayName, selected: cur == d.id) { ctx.store.applyTextStyle(d) } content: {
                                            TextPreviewImage(key: "fx:\(d.id)", content: TextPreviewImage.style(d, sample: "ART"), fontPx: 40, padding: 4)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct SearchField: View {
    @Binding var text: String
    let placeholder: String
    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(IStyle.caption)
                TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 12))
                if !text.isEmpty {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(IStyle.caption).onTapGesture { text = "" }
                }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(IStyle.field, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.08)))
        }
    }
}
