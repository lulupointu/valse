import SwiftUI
import AppKit
import MontageCore
import MontageEffects
import MontageEngine

/// Inspector ▸ Captions (UX_AI.md §1.4, TX-019/037/024/022/023/025): every caption of the track with its index,
/// timestamps (nudgeable by a frame) and editable text. Click a row = jump there; double-click the number = play from it.
/// Keys inside a caption: Enter = split at the cursor (at the start / end: leave editing), ⌘Enter = new line,
/// ⌫ at the start = merge up, Fn-⌫ (forward delete) at the end = merge down.
struct CaptionEditorSection: View {
    let ctx: InspectorContext
    @Bindable private var ui = TextUIState.shared

    var body: some View {
        let store = ctx.store
        if let ti = store.activeCaptionTrackIndex, ti < store.project.timeline.tracks.count {
            let track = store.project.timeline.tracks[ti]
            let matches = ui.findText.isEmpty ? [] : CaptionOps.find(ui.findText, in: track, caseSensitive: ui.caseSensitive)
            let matchIDs = Set(matches.map(\.clipID))
            VStack(alignment: .leading, spacing: 8) {
                toolbar(track)
                if ui.showReplace { findBar(matches.count) }
                HintText(text: tr("captions.tip"))
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(track.clips.enumerated()), id: \.element.id) { i, c in
                        CaptionRow(store: store, index: i + 1, clip: c, isSelected: store.selection.contains(c.id),
                                   isMatch: matchIDs.contains(c.id), isFirst: i == 0, isLast: i == track.clips.count - 1,
                                   previousID: i > 0 ? track.clips[i - 1].id : nil)
                    }
                }
            }
        }
    }

    func toolbar(_ track: Track) -> some View {
        let store = ctx.store
        let hasTranslation = track.clips.contains { CaptionOps.text($0)?.caption?.translation != nil }
        return HStack(spacing: 6) {
            SmallIconButton(symbol: "magnifyingglass", help: tr("captions.find"), active: ui.showReplace, size: 13) { ui.showReplace.toggle() }
            Menu {
                Button(tr("captions.keywords.highlight")) { store.highlightCaptionKeywords() }
                Button(tr("captions.keywords.clear")) { store.clearCaptionKeywords() }
            } label: { Image(systemName: "highlighter").font(.system(size: 13)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(tr("captions.keywords"))
            Menu {
                ForEach([(16, 1), (24, 1), (24, 2), (32, 2), (42, 2)], id: \.0) { c, l in
                    Button(tr("captions.wrap.option", c, l)) { store.wrapCaptions(maxChars: c, maxLines: l) }
                }
            } label: { Image(systemName: "text.word.spacing").font(.system(size: 13)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(tr("captions.wrap"))
            if hasTranslation {
                Menu {
                    Button(tr("captions.bilingual.both")) { store.setBilingualDisplay(.both) }
                    Button(tr("captions.bilingual.translationOnly")) { store.setBilingualDisplay(.translationOnly) }
                } label: { Image(systemName: "character.bubble").font(.system(size: 13)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(tr("captions.bilingual"))
            }
            Spacer()
            Menu {
                ForEach(CaptionFormat.allCases, id: \.self) { f in
                    Button(f.rawValue.uppercased()) { store.chooseCaptionExport(format: f) }
                }
            } label: { Image(systemName: "square.and.arrow.up").font(.system(size: 13)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(tr("captions.export"))
            PillButton(title: tr("captions.applyAll")) { store.applyCaptionLookToAll() }
                .help(tr("captions.applyAll.help"))
        }
        .foregroundStyle(IStyle.icon)
    }

    func findBar(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SearchField(text: $ui.findText, placeholder: tr("captions.find.placeholder"))
                Text(verbatim: ui.findText.isEmpty ? "" : tr("captions.find.count", count)).font(Theme.Fonts.hint).foregroundStyle(IStyle.caption)
                SmallIconButton(symbol: "textformat", help: tr("captions.find.caseSensitive"), active: ui.caseSensitive) { ui.caseSensitive.toggle() }
            }
            HStack(spacing: 6) {
                TextField(tr("captions.replace.placeholder"), text: $ui.replaceText).textFieldStyle(.plain).font(.system(size: 12))
                    .padding(.horizontal, 10).frame(height: 28).background(IStyle.field, in: RoundedRectangle(cornerRadius: 4))
                PillButton(title: tr("captions.replaceAll"), enabled: count > 0) {
                    ctx.store.replaceAllInCaptions(ui.findText, with: ui.replaceText, caseSensitive: ui.caseSensitive)
                }
            }
        }
    }
}

struct CaptionRow: View {
    let store: EditorStore
    let index: Int
    let clip: Clip
    let isSelected: Bool
    let isMatch: Bool
    let isFirst: Bool
    let isLast: Bool
    let previousID: ClipID?

    var body: some View {
        let rate = store.project.settings.frameRate
        let frame = rate.frameDuration
        let t = CaptionOps.text(clip)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(verbatim: "\(index)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isSelected ? Theme.accent : IStyle.caption).frame(minWidth: 18, alignment: .leading)
                    .onTapGesture(count: 2) { store.seek(to: clip.start); if !store.transport.isPlaying { store.togglePlay() } }
                    .help(tr("captions.playFrom"))
                timeField(clip.start, rate: rate) { store.nudgeCaption(clip.id, start: frame * Double($0)) }
                Text(verbatim: "–").foregroundStyle(IStyle.caption)
                timeField(clip.end, rate: rate) { store.nudgeCaption(clip.id, end: frame * Double($0)) }
                Spacer()
                if let tr2 = t?.caption?.translation, !tr2.isEmpty {
                    Image(systemName: "character.bubble").font(.system(size: 10)).foregroundStyle(IStyle.caption).help(tr2)
                }
            }
            CaptionTextField(store: store, clipID: clip.id, previousID: previousID, isLast: isLast)
                .frame(minHeight: 22)
        }
        .padding(8)
        .background(isSelected ? Theme.accentDim.opacity(0.28) : (isMatch ? IStyle.curve.opacity(0.12) : IStyle.field),
                    in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { store.selection = [clip.id]; store.seek(to: clip.start) }
    }

    func timeField(_ t: Time, rate: FrameRate, nudge: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 2) {
            Text(verbatim: Self.stamp(t)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textSecondary)
            StepperButton(step: nudge).scaleEffect(0.8)
        }
        .help(tr("captions.nudge"))
    }

    /// "01:02.35"
    static func stamp(_ t: Time) -> String {
        let s = max(t.seconds, 0)
        return String(format: "%02d:%05.2f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
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
        tv.string = context.coordinator.current()
        return tv
    }

    func updateNSView(_ tv: CaptionNSTextView, context: Context) {
        context.coordinator.parent = self
        let s = context.coordinator.current()
        if tv.string != s, tv.window?.firstResponder !== tv { tv.string = s }
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

/// Captions ▸ Templates: karaoke / caption looks applied to every caption of the track.
struct CaptionTemplatesSection: View {
    let ctx: InspectorContext
    var body: some View {
        TileGrid {
            ForEach(Registries.captionTemplates.all) { d in
                Tile(title: tr(d.nameKey)) { ctx.store.applyCaptionTemplate(d) } content: {
                    TextPreviewImage(key: "captionTemplate:\(d.id)", content: Self.preview(d), fontPx: 30, padding: 4)
                }
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
