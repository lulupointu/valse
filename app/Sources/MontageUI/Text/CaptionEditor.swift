import SwiftUI
import AppKit
import MontageCore
import MontageEffects
import MontageEngine
import Perception

/// Inspector ▸ Captions (UX_AI.md §1.4, TX-019/037/024/022/023/025; C4 follows CapCut [17]): a search field and the
/// caption tools, then one numbered row per caption with its text, edited in place. Hovering a row shows ＋ (add a
/// caption after it) and 🗑 (delete it); timing is edited on the timeline. Click a row = jump there; double-click the
/// number = play from it. Keys inside a caption: Enter = split at the cursor (at the start / end: leave editing),
/// ⌘Enter = new line, ⌫ at the start = merge up, Fn-⌫ (forward delete) at the end = merge down.
struct CaptionEditorSection: View {
    let ctx: InspectorContext
    @Perception.Bindable private var ui = TextUIState.shared

    var body: some View {
        WithPerceptionTracking {
            let store = ctx.store
            if let ti = store.activeCaptionTrackIndex, ti < store.project.timeline.tracks.count {
                let track = store.project.timeline.tracks[ti]
                let matches = ui.findText.isEmpty ? [] : CaptionOps.find(ui.findText, in: track, caseSensitive: ui.caseSensitive)
                let matchIDs = Set(matches.map(\.clipID))
                VStack(alignment: .leading, spacing: 8) {
                    toolbar(track, matches: matches.count)
                    if ui.showReplace { replaceBar(matches.count) }
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(track.clips.enumerated()), id: \.element.id) { i, c in
                            WithPerceptionTracking {
                                CaptionRow(store: store, index: i + 1, clip: c, isSelected: store.selection.contains(c.id),
                                           isMatch: matchIDs.contains(c.id), isFirst: i == 0, isLast: i == track.clips.count - 1,
                                           previousID: i > 0 ? track.clips[i - 1].id : nil)
                            }
                        }
                    }
                    HintText(text: tr("captions.tip"))
                }
            }
        }
    }

    func toolbar(_ track: Track, matches: Int) -> some View {
        let store = ctx.store
        let hasTranslation = track.clips.contains { CaptionOps.text($0)?.caption?.translation != nil }
        return HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(IStyle.caption)
                TextField(tr("captions.find.placeholder"), text: $ui.findText).textFieldStyle(.plain).font(.system(size: 12))
                    .testID("captions.search")
                if !ui.findText.isEmpty {
                    Text(verbatim: tr("captions.find.count", matches)).font(Theme.Fonts.hint).foregroundStyle(IStyle.caption).fixedSize()
                }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(IStyle.field, in: RoundedRectangle(cornerRadius: 4))
            SmallIconButton(symbol: "arrow.left.arrow.right", help: tr("captions.replaceAll"), active: ui.showReplace, size: 12) { ui.showReplace.toggle() }
                .testID("captions.replace")
            Menu {
                Button(tr("captions.keywords.highlight")) { store.highlightKeywordsAI() }   // W10: on-device LLM, statistical fallback
                Button(tr("captions.keywords.clear")) { store.clearCaptionKeywords() }
                Divider()
                ForEach([(16, 1), (24, 1), (24, 2), (32, 2), (42, 2)], id: \.0) { c, l in
                    WithPerceptionTracking {
                        Button(tr("captions.wrap.option", c, l)) { store.wrapCaptions(maxChars: c, maxLines: l) }
                    }
                }
            } label: { Image(systemName: "highlighter").font(.system(size: 13)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(tr("captions.keywords"))
            // W10: on-device translation (Apple Translation) → bilingual captions
            Menu {
                ForEach(CaptionLanguages.codes, id: \.self) { code in
                    WithPerceptionTracking {
                        Button(CaptionLanguages.title(code)) { store.translateCaptions(to: code, display: .both) }
                    }
                }
                if hasTranslation {
                    Divider()
                    Button(tr("captions.bilingual.both")) { store.setBilingualDisplay(.both) }
                    Button(tr("captions.bilingual.translationOnly")) { store.setBilingualDisplay(.translationOnly) }
                    Button(tr("captions.removeTranslation")) { store.clearCaptionTranslations() }
                }
            } label: { Image(systemName: store.ai.translating ? "hourglass" : "globe").font(.system(size: 13)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(tr("captions.translateTo"))
            Menu {
                ForEach(CaptionFormat.allCases, id: \.self) { f in
                    WithPerceptionTracking {
                        Button(f.rawValue.uppercased()) { store.chooseCaptionExport(format: f) }
                    }
                }
            } label: { Image(systemName: "square.and.arrow.up").font(.system(size: 13)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(tr("captions.export"))
        }
        .foregroundStyle(IStyle.icon)
    }

    func replaceBar(_ count: Int) -> some View {
        HStack(spacing: 6) {
            TextField(tr("captions.replace.placeholder"), text: $ui.replaceText).textFieldStyle(.plain).font(.system(size: 12))
                .padding(.horizontal, 10).frame(height: 28).background(IStyle.field, in: RoundedRectangle(cornerRadius: 4))
            SmallIconButton(symbol: "textformat", help: tr("captions.find.caseSensitive"), active: ui.caseSensitive) { ui.caseSensitive.toggle() }
            PillButton(title: tr("captions.replaceAll"), enabled: count > 0) {
                ctx.store.replaceAllInCaptions(ui.findText, with: ui.replaceText, caseSensitive: ui.caseSensitive)
            }
        }
    }
}

/// One caption: number · text (editable in place) · on hover ＋ / 🗑 (CapCut [17]).
struct CaptionRow: View {
    let store: EditorStore
    let index: Int
    let clip: Clip
    let isSelected: Bool
    let isMatch: Bool
    let isFirst: Bool
    let isLast: Bool
    let previousID: ClipID?
    @State private var hover = false

    var body: some View {
        WithPerceptionTracking {
            let t = CaptionOps.text(clip)
            HStack(alignment: .center, spacing: 10) {
                Text(verbatim: "\(index)").font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(isSelected ? Theme.accent : IStyle.caption).frame(minWidth: 20, alignment: .leading)
                    .onTapGesture(count: 2) { store.seek(to: clip.start); if !store.transport.isPlaying { store.togglePlay() } }
                    .help(CaptionRow.playFromHelp(clip.start))   // U1-5: "… from 00:00:03"
                CaptionTextField(store: store, clipID: clip.id, previousID: previousID, isLast: isLast)
                    .frame(minHeight: 20)
                if let sp = t?.caption?.speaker, !sp.isEmpty { SpeakerChip(store: store, speaker: sp) }   // AI-005
                if let tr2 = t?.caption?.translation, !tr2.isEmpty {
                    Image(systemName: "character.bubble").font(.system(size: 10)).foregroundStyle(IStyle.caption).help(tr2)
                }
                HStack(spacing: 6) {
                    rowButton("plus", tr("captions.addAfter")) { store.addCaption(after: clip.id) }.testID("captions.add.\(index)")
                    rowButton("trash", tr("captions.delete")) { store.deleteCaption(clip.id) }.testID("captions.delete.\(index)")
                }
                .opacity(hover || isSelected ? 1 : 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 9)
            .background(isSelected ? Theme.accentDim.opacity(0.28) : (isMatch ? IStyle.curve.opacity(0.12) : (hover ? Color.white.opacity(0.04) : .clear)))
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1).padding(.horizontal, 4) }
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { store.selection = [clip.id]; store.seek(to: clip.start) }
            .testID("captions.row.\(index)")
        }
    }

    /// Tooltip of the caption number: where a double-click starts playback. U1-5: the owner read "Double-cliquez pour
    /// lire à partir de" (the pill cut the rest of the line off) as a missing time; it now ends with the start time.
    static func playFromHelp(_ start: Time) -> String {
        tr("captions.playFromTime", Timecode.string(start, rate: .fps30, style: .seconds, dropFrame: false, showFrames: false))
    }

    func rowButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                .frame(width: 26, height: 26).background(Theme.buttonSecondary, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(verbatim: help))
    }

    /// "01:02.35"
    static func stamp(_ t: Time) -> String {
        let s = max(t.seconds, 0)
        return String(format: "%02d:%05.2f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }
}

/// Text ▸ Basic, captions only: "Apply to all main captions" (CapCut [11], on by default). When on, every style edit
/// made on this caption restyles the other captions of its track in the same undo step (`CaptionStyleSync`).
struct ApplyToAllCaptionsRow: View {
    let ctx: InspectorContext
    @Perception.Bindable private var ui = TextUIState.shared
    var body: some View {
        WithPerceptionTracking {
            Button { ui.applyToAllCaptions.toggle() } label: {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 3).fill(ui.applyToAllCaptions ? Theme.accent : Theme.stepper)
                        if ui.applyToAllCaptions { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white) }
                    }
                    .frame(width: 16, height: 16)
                    Text(loc: "captions.applyAllMain").font(Theme.Fonts.row).foregroundStyle(IStyle.label)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("captions.applyAllMain.help"))
            .padding(.top, 2).padding(.bottom, 4)
            .testID("captions.applyAllMain")
        }
    }
}

/// One caption's text with the CapCut caption-editing keys.
struct CaptionTextField: NSViewRepresentable {
    let store: EditorStore
    let clipID: ClipID
    let previousID: ClipID?
    let isLast: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> CaptionNSTextView {
        let tv = CaptionNSTextView()
        tv.delegate = context.coordinator
        tv.coordinator = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = false
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: 13)
        tv.textColor = NSColor(white: 0.92, alpha: 1)
        tv.insertionPointColor = NSColor(Theme.accent)
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        // later changes come through updateNSView (RepresentableTracking); this first read needn't be tracked
        tv.string = _PerceptionLocals.$skipPerceptionChecking.withValue(true) { context.coordinator.current() }
        return tv
    }

    func updateNSView(_ tv: CaptionNSTextView, context: Context) {
        context.coordinator.parent = self
        let c = context.coordinator
        c.tracking.run { [weak c, weak tv] in
            guard let c, let tv else { return }
            let s = c.current()
            if tv.string != s, tv.window?.firstResponder !== tv { tv.string = s }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: CaptionNSTextView, context: Context) -> CGSize? {
        let w = proposal.width ?? 300
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
        tc.containerSize = NSSize(width: w, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        return CGSize(width: w, height: max(18, lm.usedRect(for: tc).height + 2))
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CaptionTextField
        let tracking = RepresentableTracking()
        init(_ p: CaptionTextField) { parent = p }
        func current() -> String { parent.store.project.timeline.clip(parent.clipID).flatMap(CaptionOps.text)?.string ?? "" }

        func commit(_ tv: NSTextView) {
            if tv.string != current() { parent.store.setCaptionText(parent.clipID, tv.string) }
        }

        func textDidEndEditing(_ n: Notification) { if let tv = n.object as? NSTextView { commit(tv) } }

        func textDidBeginEditing(_ n: Notification) {
            parent.store.selection = [parent.clipID]
        }

        /// Returns true when the key was handled.
        func handle(_ event: NSEvent, in tv: NSTextView) -> Bool {
            let sel = tv.selectedRange()
            let len = (tv.string as NSString).length
            switch event.keyCode {
            case 36, 76: // Return / Enter
                if event.modifierFlags.contains(.command) { tv.insertText("\n", replacementRange: sel); return true }
                commit(tv)
                if sel.location == 0 || sel.location >= len { tv.window?.makeFirstResponder(nil); return true }
                parent.store.splitCaption(parent.clipID, at: sel.location)
                tv.window?.makeFirstResponder(nil)
                return true
            case 51: // Delete (backspace) at the start → merge into the previous caption
                guard sel.location == 0, sel.length == 0, let prev = parent.previousID else { return false }
                commit(tv)
                tv.window?.makeFirstResponder(nil)
                parent.store.mergeCaptionWithNext(prev)
                return true
            case 117: // Fn-Delete (forward delete) at the end → merge the next caption into this one
                guard sel.location >= len, sel.length == 0, !parent.isLast else { return false }
                commit(tv)
                tv.window?.makeFirstResponder(nil)
                parent.store.mergeCaptionWithNext(parent.clipID)
                return true
            case 53: // Esc
                tv.string = current(); tv.window?.makeFirstResponder(nil); return true
            default:
                return false
            }
        }
    }
}

final class CaptionNSTextView: NSTextView {
    weak var coordinator: CaptionTextField.Coordinator?
    override func keyDown(with event: NSEvent) {
        if let c = coordinator, MainActor.assumeIsolated({ c.handle(event, in: self) }) { return }
        super.keyDown(with: event)
    }
}

/// Text ▸ Templates ▸ Caption (captions, C4 [18], OB-10: first category of the Templates sub-tab): karaoke / caption
/// looks, applied to every caption of the track ("Apply to all main captions" on) or only to the selected one. Their
/// spoken-word values are then editable in Text ▸ Spoken word.
struct CaptionTemplatesSection: View {
    let ctx: InspectorContext
    /// Lower-cased search text of the Templates sub-tab ("" = all).
    var query = ""
    var body: some View {
        WithPerceptionTracking {
            let cat = tr("text.templates.caption")
            let items = Registries.captionTemplates.all.filter {
                query.isEmpty || tr($0.nameKey).lowercased().contains(query) || cat.lowercased().contains(query) || tr($0.groupKey).lowercased().contains(query)
            }
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: cat).font(.system(size: 12, weight: .medium)).foregroundStyle(IStyle.caption)
                    TileGrid {
                        ForEach(items) { d in
                            WithPerceptionTracking {
                                Tile(title: tr(d.nameKey), testID: "captionTemplate.\(d.id)") { ctx.store.applyCaptionTemplate(d) } content: {
                                    TextPreviewImage(key: "captionTemplate:\(d.id)", content: Self.preview(d), fontPx: 30, padding: 4)
                                }
                            }
                        }
                    }
                }
                .testID("text.templates.caption")
            }
        }
    }

    static func preview(_ d: CaptionTemplateDescriptor) -> TextContent {
        var t = CaptionOps.defaultStyle()
        t.string = "Aa Bb"
        d.apply(&t)
        // show the highlighted look on the second word
        if let k = t.karaoke, k.mode != .singleWord {
            t.applyStyle(TextRunStyle(color: k.highlightColor, backgroundColor: k.boxColor), to: TextSpan(3, 2))
        }
        t.karaoke = nil
        t.fontSize = 0.1
        return t
    }
}
