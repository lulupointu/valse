import SwiftUI
import AppKit
import MontageCore
import MontageEngine
import Perception

// MARK: - A. Top bar: language tabs · Export ▾ · Delete all

struct CaptionTopBar: View {
    let store: EditorStore
    let track: Track

    var body: some View {
        WithPerceptionTracking {
            let ed = store.captionEditor
            let tl = store.project.timeline
            let tracks = CaptionOps.captionTracks(tl).map { tl.tracks[$0] }
            let lang = CaptionLanguages.inSentence(track.captionLanguage)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                                WithPerceptionTracking {
                                    CaptionLanguageChip(store: store, track: t, index: i, isActive: t.id == track.id)
                                }
                            }
                            CaptionAddLanguageButton(store: store, track: track)
                        }
                        .padding(.vertical, 1)
                    }
                    Spacer(minLength: 4)
                    CaptionExportMenu(store: store, language: lang)
                    SmallIconButton(symbol: "trash", help: tr("capedit.deleteAll", lang), size: 12) { ed.confirmDeleteAll = true }
                        .testID("captions.deleteAll")
                }
                .padding(.horizontal, 12).frame(height: 40)
                if ed.showAddLanguage { CaptionAddLanguageCard(store: store, sourceTrack: track) }
                if ed.confirmDeleteAll {
                    CaptionConfirmRow(message: tr("capedit.deleteAll.confirm", track.clips.count, lang), action: tr("capedit.delete"),
                                      destructive: true, testID: "captions.deleteAll") {
                        ed.confirmDeleteAll = false
                    } confirm: {
                        ed.confirmDeleteAll = false
                        store.captionDeleteLanguage(track.id)
                    }
                }
            }
        }
    }
}

/// One language tab. Right-click: Shown in video ✓ · Change language… · Delete … captions.
struct CaptionLanguageChip: View {
    let store: EditorStore
    let track: Track
    let index: Int
    let isActive: Bool

    var body: some View {
        WithPerceptionTracking {
            let name = CaptionLanguages.name(track.captionLanguage)
            Button { store.captionSelectLanguage(track.id) } label: {
                HStack(spacing: 4) {
                    if track.isHidden { Image(systemName: "eye.slash").font(.system(size: 9)) }
                    Text(verbatim: name).font(.system(size: 12, weight: isActive ? .semibold : .medium)).lineLimit(1)
                }
                .foregroundStyle(isActive ? Theme.onAccent : Theme.textPrimary)
                .padding(.horizontal, 10).frame(height: 24)
                .background(isActive ? Theme.accent : Theme.control, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(track.isHidden ? tr("capedit.lang.hiddenHelp", CaptionLanguages.inSentence(track.captionLanguage)) : "")
            .contextMenu {
                Button((track.isHidden ? "" : "✓ ") + tr("capedit.lang.shown")) { store.captionSetShown(track.id, !track.isHidden ? false : true) }
                Menu(tr("capedit.lang.change")) {
                    ForEach(CaptionLanguages.all, id: \.self) { code in
                        Button(CaptionLanguages.title(code)) { store.captionSetLanguage(track.id, code) }
                    }
                }
                Divider()
                Button(tr("capedit.deleteAll", CaptionLanguages.inSentence(track.captionLanguage))) { store.captionEditor.activeTrackID = track.id; store.captionEditor.confirmDeleteAll = true }
            }
            .accessibilityLabel(Text(verbatim: name))
            .accessibilityValue(Text(verbatim: track.isHidden ? tr("capedit.lang.hidden") : tr("capedit.lang.shown")))
            .testID("captions.lang.\(index)")
        }
    }
}

/// Export ▾: click = the active language in the last used format; menu: SRT VTT ASS TXT LRC · All languages….
struct CaptionExportMenu: View {
    let store: EditorStore
    let language: String
    var body: some View {
        WithPerceptionTracking {
            Menu {
                ForEach(CaptionFormat.allCases, id: \.self) { f in
                    WithPerceptionTracking {
                        Button(f.rawValue.uppercased()) { store.captionExport(format: f) }
                    }
                }
                Divider()
                Button(tr("capedit.export.all")) { store.captionExportAllLanguages() }
            } label: {
                Text(loc: "capedit.export").font(.system(size: 12, weight: .medium))
            } primaryAction: {
                store.captionExport(format: CaptionExportPrefs.lastFormat)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help(tr("capedit.export.help", language, CaptionExportPrefs.lastFormat.rawValue.uppercased()))
            .testID("captions.export")
        }
    }
}

enum CaptionExportPrefs {
    static var lastFormat: CaptionFormat {
        get { UserDefaults.standard.string(forKey: "captionEditor.exportFormat").flatMap(CaptionFormat.init(rawValue:)) ?? .srt }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "captionEditor.exportFormat") }
    }
}

/// Inline "Are you sure?" row (delete all, re-split): in the panel, so keyboard and tests reach it.
struct CaptionConfirmRow: View {
    let message: String
    let action: String
    var destructive = false
    let testID: String
    let cancel: () -> Void
    let confirm: () -> Void
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: message).font(Theme.Fonts.row).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Spacer()
                    PillButton(title: tr("capedit.cancel"), action: cancel).testID("\(testID).cancel")
                    PillButton(title: action, accent: !destructive, action: confirm).testID("\(testID).confirm")
                }
            }
            .padding(10)
            .background(destructive ? Theme.danger.opacity(0.18) : Theme.Valse.raised, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
    }
}

// MARK: - B. Split options

struct CaptionSplitOptions: View {
    let store: EditorStore
    let track: Track

    var body: some View {
        WithPerceptionTracking {
            let ed = store.captionEditor
            let lang = CaptionLanguages.inSentence(track.captionLanguage)
            VStack(alignment: .leading, spacing: 6) {
                Button { ed.splitOpen.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: ed.splitOpen ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold))
                            .frame(width: 12)
                        Text(loc: "capedit.split.title").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text(verbatim: track.captionSplit.map(CaptionSplitLabels.summary) ?? tr("capedit.split.asGenerated"))
                            .font(Theme.Fonts.hint).foregroundStyle(IStyle.caption).lineLimit(1)
                    }
                    .foregroundStyle(Theme.textPrimary).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .testID("captions.split")
                if ed.splitOpen {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(CaptionSplitRule.presets.enumerated()), id: \.offset) { i, r in
                            WithPerceptionTracking {
                                radio(CaptionSplitLabels.preset(r), on: track.captionSplit == r && !ed.showCustomRule, id: "captions.split.\(i)") {
                                    ed.showCustomRule = false; ed.pendingRule = r
                                }
                            }
                        }
                        let custom = track.captionSplit.map { !CaptionSplitRule.presets.contains($0) } ?? false
                        radio(tr("capedit.split.custom"), on: custom || ed.showCustomRule, id: "captions.split.custom") {
                            ed.customRule = track.captionSplit ?? ed.customRule; ed.showCustomRule = true
                        }
                        if ed.showCustomRule { customEditor(ed) }
                    }
                    .padding(.leading, 18)
                    if let r = ed.pendingRule {
                        CaptionConfirmRow(message: tr("capedit.split.confirm", track.clips.count, lang, CaptionSplitLabels.summary(r)),
                                          action: tr("capedit.split.apply"), testID: "captions.split") {
                            ed.pendingRule = nil
                        } confirm: {
                            ed.pendingRule = nil; ed.showCustomRule = false
                            store.captionResplit(r)
                        }
                        .padding(.horizontal, -12)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    func customEditor(_ ed: CaptionEditorState) -> some View {
        HStack(spacing: 8) {
            stepper(tr("capedit.split.chars"), ed.customRule.charsPerLine, 8...60, id: "chars") { ed.customRule = CaptionSplitRule(charsPerLine: $0, lines: ed.customRule.lines) }
            stepper(tr("capedit.split.lines"), ed.customRule.lines, 1...3, id: "lines") { ed.customRule = CaptionSplitRule(charsPerLine: ed.customRule.charsPerLine, lines: $0) }
            PillButton(title: tr("capedit.split.apply")) { ed.pendingRule = ed.customRule }.testID("captions.split.custom.apply")
        }
        .padding(.leading, 22).padding(.vertical, 4)
    }

    func stepper(_ label: String, _ v: Int, _ range: ClosedRange<Int>, id: String, _ set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: label).font(Theme.Fonts.hint).foregroundStyle(IStyle.caption)
            SmallIconButton(symbol: "minus", help: label, enabled: v > range.lowerBound, size: 10) { set(max(v - 1, range.lowerBound)) }
                .testID("captions.split.\(id).minus")
            Text(verbatim: "\(v)").font(Theme.Fonts.numeric).frame(minWidth: 18)
            SmallIconButton(symbol: "plus", help: label, enabled: v < range.upperBound, size: 10) { set(min(v + 1, range.upperBound)) }
                .testID("captions.split.\(id).plus")
        }
    }

    func radio(_ title: String, on: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().stroke(on ? Theme.accent : IStyle.iconDim, lineWidth: 1.5).frame(width: 13, height: 13)
                    if on { Circle().fill(Theme.accent).frame(width: 7, height: 7) }
                }
                Text(verbatim: title).font(Theme.Fonts.row).foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .frame(height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .testID(id)
    }
}

enum CaptionSplitLabels {
    /// "2 lines · 32 characters per line"
    static func summary(_ r: CaptionSplitRule) -> String {
        r.lines == 1 ? tr("capedit.split.rule.one", r.charsPerLine) : tr("capedit.split.rule", r.lines, r.charsPerLine)
    }
    static func preset(_ r: CaptionSplitRule) -> String {
        r == CaptionSplitRule.presets[0] ? summary(r) + " " + tr("capedit.split.shorts") : summary(r)
    }
}

// MARK: - C. Search & replace (pinned)

struct CaptionSearchBar: View {
    let store: EditorStore
    let track: Track

    var body: some View {
        WithPerceptionTracking {
            let ed = store.captionEditor
            let n = store.captionMatches().count
            let lang = CaptionLanguages.inSentence(track.captionLanguage)
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(IStyle.caption)
                        CaptionSearchField(store: store, placeholder: tr("capedit.search.placeholder", lang))
                            .frame(height: 18)
                            .testID("captions.search")
                        if !ed.findText.isEmpty {
                            Text(verbatim: n == 0 ? "0" : tr("capedit.find.count", min(ed.matchIndex, n - 1) + 1, n))
                                .font(Theme.Fonts.hint.monospacedDigit()).foregroundStyle(n == 0 ? Theme.warning : IStyle.caption).fixedSize()
                                .testID("captions.search.count")
                            SmallIconButton(symbol: "chevron.up", help: tr("capedit.find.previous"), enabled: n > 0, size: 10) { store.captionStepMatch(-1) }
                                .testID("captions.search.previous")
                            SmallIconButton(symbol: "chevron.down", help: tr("capedit.find.next"), enabled: n > 0, size: 10) { store.captionStepMatch(1) }
                                .testID("captions.search.next")
                        }
                    }
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(IStyle.field, in: RoundedRectangle(cornerRadius: 4))
                    SmallIconButton(symbol: "textformat", help: tr("captions.find.caseSensitive"), active: ed.caseSensitive) { ed.caseSensitive.toggle() }
                        .testID("captions.search.case")
                    SmallIconButton(symbol: "arrow.left.arrow.right", help: tr("capedit.replace.toggle"), active: ed.showReplace, size: 12) { ed.showReplace.toggle() }
                        .testID("captions.replace")
                }
                if ed.showReplace {
                    HStack(spacing: 6) {
                        TextField(tr("capedit.replace.placeholder"), text: Binding.perceived(get: { ed.replaceText }, set: { ed.replaceText = $0 }))
                            .textFieldStyle(.plain).font(.system(size: 12))
                            .padding(.horizontal, 10).frame(height: 28).background(IStyle.field, in: RoundedRectangle(cornerRadius: 4))
                            .testID("captions.replace.field")
                        PillButton(title: tr("capedit.replace"), enabled: n > 0) { store.captionReplaceCurrent() }.testID("captions.replace.one")
                        PillButton(title: tr("captions.replaceAll"), enabled: n > 0) { store.captionReplaceAll() }.testID("captions.replace.all")
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}

/// The search field: typing updates the query at once (no debounce: the list is not filtered, only highlighted);
/// Enter / ⇧Enter = next / previous match, Esc clears (a second Esc goes to the list), ⌘G / ⇧⌘G step.
struct CaptionSearchField: NSViewRepresentable {
    let store: EditorStore
    let placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(store) }

    func makeNSView(context: Context) -> CaptionSearchNSField {
        let f = CaptionSearchNSField()
        f.isBordered = false; f.drawsBackground = false; f.focusRingType = .none
        f.font = .systemFont(ofSize: 12)
        f.textColor = NSColor(Theme.textPrimary)
        f.delegate = context.coordinator
        f.store = store
        f.cell?.lineBreakMode = .byTruncatingTail
        f.cell?.usesSingleLineMode = true
        return f
    }

    func updateNSView(_ f: CaptionSearchNSField, context: Context) {
        let c = context.coordinator
        c.store = store
        f.store = store
        f.placeholderString = placeholder
        c.tracking.run { [weak f, weak c] in
            guard let f, let c else { return }
            let ed = c.store.captionEditor
            if f.stringValue != ed.findText, f.currentEditor() == nil { f.stringValue = ed.findText }
            let token = ed.searchFocusToken
            if token != c.focusToken {
                c.focusToken = token
                DispatchQueue.main.async { f.window?.makeFirstResponder(f); f.currentEditor()?.selectAll(nil) }
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var store: EditorStore
        let tracking = RepresentableTracking()
        var focusToken = 0
        init(_ s: EditorStore) { store = s; focusToken = s.captionEditor.searchFocusToken }

        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSTextField else { return }
            store.captionEditor.findText = f.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.insertNewline(_:)):
                store.captionStepMatch(NSEvent.modifierFlags.contains(.shift) ? -1 : 1); return true
            case #selector(NSResponder.cancelOperation(_:)):
                if !store.captionEditor.findText.isEmpty {
                    store.captionEditor.findText = ""; (control as? NSTextField)?.stringValue = ""
                } else if let list = CaptionTextRegistry.list {
                    control.window?.makeFirstResponder(list)
                }
                return true
            default: return false
            }
        }
    }
}

final class CaptionSearchNSField: NSTextField {
    weak var store: EditorStore?
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if currentEditor() != nil, let s = store, MainActor.assumeIsolated({ CaptionEditorKeys.search(e, store: s) }) { return true }
        return super.performKeyEquivalent(with: e)
    }
}
