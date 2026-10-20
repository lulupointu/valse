import SwiftUI
import MontageCore
import MontageEffects
import Perception

// Text finisher rows: number / timer / date counters (TX-039), "Separate text template" (TX-032) and template language
// variants (TX-033). Sections are registered in `TextInspector.sections`.

@MainActor
extension EditorStore {
    /// "Separate text template" (TX-032): splits a template clip into one clip per layer (text slots and shapes), each
    /// on its own track above, same timing — then every part moves, scales, times and animates on its own. One undo step.
    @discardableResult
    func separateTextTemplate(_ id: ClipID) -> [ClipID] {
        guard let c = project.timeline.clip(id), case .text(let t) = c.content, let inst = t.template,
              let d = Registries.textTemplates[inst.templateID] else { return [] }
        let shown = d.layers.indices.filter(inst.showsLayer)
        guard shown.count >= 2 else { showToast(tr("text.separate.single")); return [] }
        let newIDs = shown.dropFirst().map { _ in ClipID() }
        let ok = edit("cmd.separateTemplate") { p in
            guard var first = p.timeline.clip(id), case .text(var ft) = first.content else { return }
            let original = first
            for (li, nid) in zip(shown.dropFirst(), newIDs) {
                var part = original
                part.id = nid
                var pt = ft
                pt.template?.layers = [li]
                part.content = .text(pt)
                try TimelineOps.insert(part, into: &p, target: .newTrack)
            }
            ft.template?.layers = [shown[0]]
            first.content = .text(ft)
            p.timeline[clip: id] = first
        }
        guard ok else { return [] }
        selection = [id]
        showToast(tr("text.separate.done", shown.count))
        return [id] + newIDs
    }

    /// Template language (TX-033): rewrites the template's default slot texts in `language` (en / fr); slots the user
    /// typed over are kept.
    func setTemplateLanguage(_ id: ClipID, _ language: String) {
        guard let c = project.timeline.clip(id), case .text(let t) = c.content, let inst = t.template,
              let d = Registries.textTemplates[inst.templateID] else { return }
        let table = L10n.shared.strings(for: language)
        let defaults = Set(L10n.supportedLanguages.flatMap { lang in
            let tb = L10n.shared.strings(for: lang)
            return d.slotKeys.indices.compactMap { i in tb[d.slotKeys[i]].map { "\(i)|\($0)" } }
        })
        updateText(id, nameKey: "cmd.templateLanguage") { tt in
            for i in d.slotKeys.indices {
                let cur = TextTemplateDescriptor.text(slot: i, of: tt, descriptor: d)
                guard defaults.contains("\(i)|\(cur)") || cur.isEmpty, let v = table[d.slotKeys[i]] else { continue }
                if i == 0 { tt.string = v; tt.runs = [] } else {
                    var texts = tt.template?.texts ?? []
                    while texts.count < i { texts.append(TextTemplateDescriptor.text(slot: texts.count + 1, of: tt, descriptor: d)) }
                    texts[i - 1] = v
                    tt.template?.texts = texts
                }
            }
            tt.template?.language = language
        }
    }
}

/// Template clip extras: [Separate] (TX-032) and the Language dropdown (TX-033), under the slot fields.
struct TextTemplateToolsSection: View {
    let ctx: InspectorContext
    var body: some View {
        WithPerceptionTracking {
            if let clip = ctx.clip, case .text(let t) = clip.content, let inst = t.template {
                let d = Registries.textTemplates[inst.templateID]
                let parts = d.map { $0.layers.indices.filter(inst.showsLayer).count } ?? 0
                VStack(alignment: .leading, spacing: 8) {
                    InlineRow(label: tr("text.template.language")) {
                        Dropdown(items: L10n.supportedLanguages.map { ($0, tr("text.template.language.\($0)")) },
                                 selection: inst.language ?? L10n.shared.language) { ctx.store.setTemplateLanguage(clip.id, $0) }
                            .testID("text.template.language")
                    }
                    HStack {
                        PillButton(title: tr("text.separate"), enabled: parts >= 2) { ctx.store.separateTextTemplate(clip.id) }
                            .testID("text.template.separate")
                        Spacer()
                    }
                    HintText(text: tr(parts >= 2 ? "text.separate.hint" : "text.separate.single"))
                }
            }
        }
    }
}

// MARK: - Counter

/// Text ▸ Basic ▸ ☐ Counter (TX-039): Type (Number / Timer / Date), From, To, decimals, separator, prefix / suffix,
/// count duration and ease-out. The value replaces the displayed text, frame by frame.
struct TextCounterSection: View {
    let ctx: InspectorContext

    static func chrome(_ ctx: InspectorContext) -> InspectorSectionChrome {
        TextInspector.chrome(ctx, isOn: { $0.counter != nil }, toggle: { t, on in t.counter = on ? (t.counter ?? TextCounter()) : nil },
                             reset: { t in if let k = t.counter?.kind { t.counter = TextCounter.defaults(k) } })
    }

    var counter: TextCounter? { TextInspector.text(ctx)?.counter }

    func set(_ body: @escaping (inout TextCounter) -> Void) {
        guard let id = ctx.clip?.id else { return }
        ctx.store.updateText(id, nameKey: "cmd.textCounter") { t in
            var k = t.counter ?? TextCounter()
            body(&k)
            t.counter = k
        }
    }

    var body: some View {
        WithPerceptionTracking {
            let k = counter ?? TextCounter()
            let on = counter != nil
            VStack(alignment: .leading, spacing: 4) {
                InlineRow(label: tr("counter.kind"), enabled: on) {
                    Dropdown(items: TextCounter.Kind.allCases.map { ($0, tr($0.nameKey)) }, selection: k.kind) { kind in
                        set { c in let pre = c.prefix, suf = c.suffix; c = TextCounter.defaults(kind); if kind == .number { c.prefix = pre; c.suffix = suf } }
                    }
                    .testID("counter.kind")
                }
                switch k.kind {
                case .number, .timer:
                    InlineRow(label: tr("counter.from"), enabled: on) {
                        CounterNumberField(value: k.from, decimals: k.kind == .number ? k.decimals : 0) { v in set { $0.from = v } }.testID("counter.from")
                    }
                    InlineRow(label: tr("counter.to"), enabled: on) {
                        CounterNumberField(value: k.to, decimals: k.kind == .number ? k.decimals : 0) { v in set { $0.to = v } }.testID("counter.to")
                    }
                    InlineRow(label: tr("counter.decimals"), enabled: on) {
                        Dropdown(items: (k.kind == .number ? [0, 1, 2, 3] : [0, 2]).map { ($0, String($0)) }, selection: k.decimals) { v in set { $0.decimals = v } }
                            .frame(width: 80)
                    }
                case .date:
                    InlineRow(label: tr("counter.from"), enabled: on) {
                        CounterDateField(days: k.from) { v in set { $0.from = v } }
                    }
                    InlineRow(label: tr("counter.to"), enabled: on) {
                        CounterDateField(days: k.to) { v in set { $0.to = v } }
                    }
                    InlineRow(label: tr("counter.dateFormat"), enabled: on) {
                        Dropdown(items: TextCounter.DateFormat.allCases.map { ($0, tr($0.nameKey)) }, selection: k.dateFormat) { v in set { $0.dateFormat = v } }
                    }
                }
                if k.kind == .number {
                    ToggleLine(label: tr("counter.separator"), isOn: Binding.perceived(get: { k.thousandsSeparator }, set: { v in set { $0.thousandsSeparator = v } }), enabled: on)
                    InlineRow(label: tr("counter.prefix"), enabled: on) {
                        CounterTextField(text: k.prefix) { v in set { $0.prefix = v } }.testID("counter.prefix")
                    }
                    InlineRow(label: tr("counter.suffix"), enabled: on) {
                        CounterTextField(text: k.suffix) { v in set { $0.suffix = v } }.testID("counter.suffix")
                    }
                }
                InlineRow(label: tr("counter.duration"), enabled: on) {
                    Dropdown(items: [0.25, 0.5, 0.8, 1.0].map { ($0, "\(Int($0 * 100)) %") }, selection: k.countFraction) { v in set { $0.countFraction = v } }
                        .frame(width: 100)
                }
                ToggleLine(label: tr("counter.easeOut"), isOn: Binding.perceived(get: { k.easeOut }, set: { v in set { $0.easeOut = v } }), enabled: on)
                HintText(text: tr("counter.hint"))
            }
        }
    }
}

/// Number field committing on Return / focus loss (one undo step).
struct CounterNumberField: View {
    let value: Double
    let decimals: Int
    let onCommit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        WithPerceptionTracking {
            TextField("", text: $text)
                .textFieldStyle(.plain).font(.system(size: 12)).multilineTextAlignment(.trailing)
                .padding(.horizontal, 8).frame(width: 110, height: 26)
                .background(IStyle.field, in: RoundedRectangle(cornerRadius: 4))
                .focused($focused)
                .onAppear { text = Self.format(value, decimals) }
                .onValueChange(of: value) { _, v in if !focused { text = Self.format(v, decimals) } }
                .onSubmit(commit)
                .onValueChange(of: focused) { _, f in if !f { commit() } }
        }
    }
    func commit() {
        let s = text.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\u{202F}", with: "")
        if let v = Double(s), v != value { onCommit(v) } else { text = Self.format(value, decimals) }
    }
    static func format(_ v: Double, _ d: Int) -> String { String(format: "%.\(max(d, 0))f", v) }
}

struct CounterTextField: View {
    let text: String
    let onCommit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        WithPerceptionTracking {
            TextField("", text: $draft)
                .textFieldStyle(.plain).font(.system(size: 12))
                .padding(.horizontal, 8).frame(width: 110, height: 26)
                .background(IStyle.field, in: RoundedRectangle(cornerRadius: 4))
                .focused($focused)
                .onAppear { draft = text }
                .onValueChange(of: text) { _, v in if !focused { draft = v } }
                .onSubmit { if draft != text { onCommit(draft) } }
                .onValueChange(of: focused) { _, f in if !f, draft != text { onCommit(draft) } }
        }
    }
}

/// Date picker over a day count since 2001-01-01 (UTC).
struct CounterDateField: View {
    let days: Double
    let onCommit: (Double) -> Void
    var body: some View {
        WithPerceptionTracking {
            DatePicker("", selection: Binding.perceived(
                get: { Date(timeIntervalSinceReferenceDate: days * 86_400) },
                set: { d in
                    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
                    let c = cal.dateComponents([.year, .month, .day], from: d)
                    onCommit(TextCounter.day(c.year ?? 2001, c.month ?? 1, c.day ?? 1))
                }), displayedComponents: .date)
                .labelsHidden().datePickerStyle(.field)
                .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                .frame(width: 130)
        }
    }
}
