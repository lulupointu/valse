import SwiftUI
import AppKit
import MontageCore
import MontageEngine
import MontageAI

/// Inspector ▸ Captions tab (UX_AI §1.4, TX-019/023/037): every caption as an editable row; click = seek; Enter splits
/// at the cursor, ⌫ at the start merges up, ⌦ at the end merges down, ⌘↩ inserts a line break. Top: find & replace,
/// highlight keywords, bilingual translation; footer: Apply to all captions.
enum CaptionsInspector {
    @MainActor static let tabs: [InspectorTab] = [
        InspectorTab(id: "captions", titleKey: "inspector.tab.captions", order: 1,
                     footer: { ctx, _ in
                         guard let id = ctx.clip?.id else { return nil }
                         return AnyView(PillButton(title: tr("captions.applyToAll")) { ctx.store.applyCaptionStyleToAll(from: id) })
                     },
                     appliesTo: { $0.kind == .text && ($0.clip?.isCaption ?? false) }),
    ]
    @MainActor static let sections: [InspectorSection] = [
        InspectorSection(id: "captions.list", tab: "captions", order: 0, titleKey: nil) { AnyView(CaptionListSection(ctx: $0)) },
    ]
}

struct CaptionListSection: View {
    let ctx: InspectorContext
    @State private var query = ""
    @State private var replacement = ""
    @State private var showReplace = false
    @State private var target = "en"

    var body: some View {
        let store = ctx.store
        let caps = CaptionOps.captions(in: store.project.timeline)
        let hits = Set(CaptionOps.search(query, in: store.project.timeline))
        let translated = caps.contains { $0.caption?.translation != nil }
        VStack(alignment: .leading, spacing: 10) {
            // find & replace
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(IStyle.caption)
                TextField(tr("captions.find"), text: $query).textFieldStyle(.plain).font(Theme.Fonts.row)
                if !query.isEmpty {
                    Text(verbatim: tr("captions.results", hits.count)).font(Theme.Fonts.hint).foregroundStyle(IStyle.caption)
                }
                SmallIconButton(symbol: "arrow.left.arrow.right", help: tr("captions.replace"), active: showReplace) { showReplace.toggle() }
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(IStyle.field, in: RoundedRectangle(cornerRadius: 4))
            if showReplace {
                HStack(spacing: 6) {
                    TextField(tr("captions.replaceWith"), text: $replacement).textFieldStyle(.plain).font(Theme.Fonts.row)
                        .padding(.horizontal, 8).frame(height: 28).background(IStyle.field, in: RoundedRectangle(cornerRadius: 4))
                    PillButton(title: tr("captions.replaceAll"), enabled: !query.isEmpty) { store.replaceInCaptions(query, with: replacement) }
                }
            }
            // keywords + bilingual
            HStack(spacing: 8) {
                PillButton(title: tr("captions.highlightKeywords"), symbol: "highlighter") { store.highlightKeywords() }
                Spacer()
                if store.ai.translating { ProgressView().controlSize(.small) }
            }
            HStack(spacing: 8) {
                Text(loc: "captions.translateTo").font(Theme.Fonts.row).foregroundStyle(IStyle.label)
                Dropdown(items: CaptionLanguages.codes.map { ($0, CaptionLanguages.title($0)) }, selection: target) { target = $0 }
                    .frame(width: 150)
                PillButton(title: tr("captions.translate"), enabled: !store.ai.translating) { store.translateCaptions(to: target, display: .bilingual) }
            }
            if translated {
                HStack(spacing: 8) {
                    SegmentedTabs([("bilingual", tr(CaptionDisplay.bilingual.nameKey)), ("translationOnly", tr(CaptionDisplay.translationOnly.nameKey)),
                                          ("original", tr(CaptionDisplay.original.nameKey))],
                                  selection: Binding(get: { caps.first?.caption?.effectiveDisplay.rawValue ?? "original" },
                                                     set: { store.setCaptionDisplay(CaptionDisplay(rawValue: $0) ?? .original) }))
                    SmallIconButton(symbol: "trash", help: tr("captions.removeTranslation")) { store.clearCaptionTranslations() }
                }
            }
            HintText(text: tr("captions.shortcutsHint"))
            Rectangle().fill(Theme.separator).frame(height: 1)
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(caps.enumerated()), id: \.element.id) { i, c in
                    CaptionRow(store: store, index: i + 1, clip: c, selected: store.selection.contains(c.id), highlighted: hits.contains(c.id))
                }
            }
        }
        .background(TranslationHost(store: store))
    }
}

struct CaptionRow: View {
    let store: EditorStore
    let index: Int
    let clip: Clip
    let selected: Bool
    let highlighted: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(index)").font(.system(size: 11, weight: .semibold)).foregroundStyle(selected ? Theme.accent : IStyle.caption)
                    .onTapGesture(count: 2) { store.seek(to: clip.start); store.togglePlay() }
                    .help(tr("captions.playFrom"))
            }
            .frame(width: 22, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "\(Self.stamp(clip.start)) – \(Self.stamp(clip.end))")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(IStyle.caption)
                CaptionTextField(text: CaptionOps.mainText(clip), keywords: keywordWords,
                                 onFocus: { store.selection = [clip.id]; store.seek(to: clip.start) },
                                 onCommit: { store.setCaptionText(clip.id, $0) },
                                 onSplit: { text, offset in store.setCaptionText(clip.id, text); store.splitCaption(clip.id, at: offset) },
                                 onMergeUp: { text in store.setCaptionText(clip.id, text); store.mergeCaption(clip.id, withPrevious: true) },
                                 onMergeDown: { text in store.setCaptionText(clip.id, text); store.mergeCaption(clip.id, withPrevious: false) })
                    .frame(minHeight: 22)
                if let tr = clip.caption?.translation {
                    Text(verbatim: tr).font(Theme.Fonts.hint).foregroundStyle(IStyle.caption)
                }
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 6)
        .background(selected ? Theme.accentDim.opacity(0.35) : (highlighted ? IStyle.warning.opacity(0.15) : .clear), in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { store.selection = [clip.id]; store.seek(to: clip.start) }
    }

    /// "01:02.35"
    static func stamp(_ t: Time) -> String {
        let cs = Int((t.seconds * 100).rounded())
        return String(format: "%02d:%02d.%02d", cs / 6000, cs / 100 % 60, cs % 100)
    }

    var keywordWords: Set<String> { Set(clip.caption?.words.filter(\.keyword).map { CaptionText.normalize($0.text) } ?? []) }
}

/// Multi-line caption editor with CapCut's caption-list keys.
struct CaptionTextField: NSViewRepresentable {
    let text: String
    var keywords: Set<String> = []
    let onFocus: () -> Void
    let onCommit: (String) -> Void
    let onSplit: (String, Int) -> Void
    let onMergeUp: (String) -> Void
    let onMergeDown: (String) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let f = FocusTextField(string: text)
        f.isBordered = false; f.drawsBackground = false; f.focusRingType = .none
        f.font = .systemFont(ofSize: 12); f.textColor = NSColor(white: 0.9, alpha: 1)
        f.usesSingleLineMode = false; f.cell?.wraps = true; f.cell?.isScrollable = false
        f.lineBreakMode = .byWordWrapping
        f.maximumNumberOfLines = 0
        f.delegate = context.coordinator
        f.onFocus = { context.coordinator.parent.onFocus() }
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.currentEditor() == nil, f.stringValue != text { f.stringValue = text }
        f.textColor = keywords.isEmpty ? NSColor(white: 0.9, alpha: 1) : NSColor(white: 0.9, alpha: 1)
        if !keywords.isEmpty, f.currentEditor() == nil {
            let a = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(white: 0.9, alpha: 1)])
            let ns = text as NSString
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { w, r, _, _ in
                if let w, keywords.contains(CaptionText.normalize(w)) {
                    a.addAttribute(.foregroundColor, value: NSColor(srgbRed: 0.95, green: 0.76, blue: 0.19, alpha: 1), range: r)
                }
            }
            f.attributedStringValue = a
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CaptionTextField
        init(_ p: CaptionTextField) { parent = p }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let f = obj.object as? NSTextField else { return }
            parent.onCommit(f.stringValue)
        }

        func control(_ control: NSControl, textView tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            let s = tv.string, r = tv.selectedRange()
            let len = (s as NSString).length
            switch sel {
            case #selector(NSResponder.insertNewline(_:)):
                if r.location == 0 || r.location >= len { control.window?.makeFirstResponder(nil); return true }   // exit editing
                let offset = s.distance(from: s.startIndex, to: String.Index(utf16Offset: r.location, in: s))
                parent.onSplit(s, offset)
                return true
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                tv.insertText("\n", replacementRange: r)
                return true
            case #selector(NSResponder.deleteBackward(_:)) where r.location == 0 && r.length == 0:
                parent.onMergeUp(s); return true
            case #selector(NSResponder.deleteForward(_:)) where r.location >= len && r.length == 0:
                parent.onMergeDown(s); return true
            default:
                return false
            }
        }
    }
}

final class FocusTextField: NSTextField {
    var onFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }
}

extension EditorStore {
    /// Highlight keywords (TX-022): on-device keyword extraction (Foundation Models when available, else statistics).
    public func highlightKeywords() {
        let caps = CaptionOps.captions(in: project.timeline)
        guard !caps.isEmpty else { return }
        let texts = caps.map(CaptionOps.mainText)
        let lang = caps.first?.caption?.language ?? L10n.shared.language
        Task {
            let keys = await KeywordExtractor.keywords(texts, language: lang)
            if perform(Edit("cmd.captionKeywords") { p in _ = CaptionOps.markKeywords(keys, in: &p.timeline) }) {
                showToast(tr("captions.keywordsDone", keys.count))
            }
        }
    }
}
