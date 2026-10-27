import SwiftUI
import AppKit
import ValseCore
import ValseEffects
import ValseEngine
import Perception

/// Inspector ▸ Captions (CAP-EDITOR-UX, owner sketch 2026-10-27): a full-height section with its own scroll view.
/// Pinned on top: language tabs + Export + Delete all (A), Split options (B), search / replace (C); then the caption
/// list (D, the only part that scrolls) and a footer (E). Shown for selected captions, or nothing selected in a
/// project with captions (CAP-UX2-TAB).
struct CaptionEditorSection: View {
    let ctx: InspectorContext

    var body: some View {
        WithPerceptionTracking {
            let store = ctx.store
            if let ti = store.captionEditorTrackIndex, ti < store.project.timeline.tracks.count {
                let track = store.project.timeline.tracks[ti]
                VStack(spacing: 0) {
                    CaptionTopBar(store: store, track: track)
                    CaptionEditorDivider()
                    CaptionSplitOptions(store: store, track: track)
                    CaptionEditorDivider()
                    CaptionSearchBar(store: store, track: track)
                    CaptionEditorDivider()
                    // an empty language ("Empty, same timing"): the card above its (editable, empty) rows
                    if CaptionLanguages.isEmptyLanguage(track) { CaptionEmptyCard(store: store, track: track) }
                    CaptionList(store: store, track: track)
                    CaptionEditorDivider()
                    CaptionTimingBar(store: store, track: track)
                    CaptionEditorDivider()
                    CaptionFooter(store: store, track: track)
                }
                .testID("captions.editor")
            } else {
                CaptionEmptyCard(store: store, track: nil).frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

struct CaptionEditorDivider: View {
    var body: some View { Rectangle().fill(Theme.separator).frame(height: 1) }
}

/// Time stamps of the caption editor ("0:05.8", "0:05.80").
enum CaptionStamp {
    static func short(_ t: Time) -> String {
        let s = max(t.seconds, 0)
        let m = Int(s) / 60
        return String(format: "%d:%04.1f", m, s - Double(m * 60))
    }
    static func precise(_ t: Time) -> String {
        let s = max(t.seconds, 0)
        let m = Int(s) / 60
        return String(format: "%d:%05.2f", m, s - Double(m * 60))
    }
    /// VoiceOver label of a row: "Caption 12, 0:05.8 to 0:07.1".
    static func accessibility(index: Int, _ c: Clip) -> String {
        tr("capedit.row.a11y", index, short(c.start), short(c.end))
    }
}

// MARK: - D. List

/// The caption list: a lazy stack in the editor's own scroll view; rows keep their height when activated (buttons
/// live in a reserved trailing column), the list scrolls only on explicit reveals (timeline selection, search steps,
/// playback follow), never when a caption starts being edited.
struct CaptionList: View {
    let store: EditorStore
    let track: Track

    var body: some View {
        WithPerceptionTracking {
            let _ = CaptionTextMeasure.noteListBody()
            let ed = store.captionEditor
            let matches = store.captionMatches()
            let current = matches.isEmpty ? nil : matches[min(ed.matchIndex, matches.count - 1)]
            let byClip = Dictionary(grouping: matches, by: \.clipID)
            let active = store.captionActiveID
            let rtl = CaptionLanguages.isRightToLeft(track.captionLanguage)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(track.clips.enumerated()), id: \.element.id) { i, c in
                            WithPerceptionTracking {
                                CaptionRow(store: store, index: i + 1, clip: c, text: CaptionOps.text(c)?.string ?? "",
                                           isActive: c.id == active, isLast: i == track.clips.count - 1, rightToLeft: rtl,
                                           rule: track.captionSplit,
                                           highlights: (byClip[c.id] ?? []).map { NSRange(location: $0.range.location, length: $0.range.length) },
                                           current: current?.clipID == c.id ? current.map { NSRange(location: $0.range.location, length: $0.range.length) } : nil)
                                    .equatable()
                                    .id(c.id)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                    .background(CaptionScrollProbe(store: store))
                }
                .background(CaptionListKeyView(store: store))
                .onChange(of: ed.reveal) { r in
                    guard let r else { return }
                    ed.allowListScroll()
                    proxy.scrollTo(r.id)   // anchor nil = the minimal scroll that shows the row
                }
            }
            .frame(maxHeight: .infinity)
            .testID("captions.list")
        }
    }
}

/// One caption: start-time gutter · editable text · ↻ + 🗑 (reserved column). The active row has the accent fill, a
/// 3 pt bar; the now-playing row a ▸ in the gutter. Its height depends only on its text (the timing controls are in the
/// pinned `CaptionTimingBar`, CAP-UX2-TIMINGBAR): activating a row never moves any row.
struct CaptionRow: View, Equatable {
    let store: EditorStore
    let index: Int
    let clip: Clip
    let text: String
    let isActive: Bool
    let isLast: Bool
    let rightToLeft: Bool
    let rule: CaptionSplitRule?
    let highlights: [NSRange]
    let current: NSRange?
    @State private var hover = false

    static func == (a: CaptionRow, b: CaptionRow) -> Bool {
        a.store === b.store && a.index == b.index && a.clip == b.clip && a.text == b.text && a.isActive == b.isActive
            && a.isLast == b.isLast && a.rightToLeft == b.rightToLeft && a.rule == b.rule && a.highlights == b.highlights
            && a.current == b.current
    }

    var body: some View {
        WithPerceptionTracking {
            let _ = CaptionTextMeasure.noteRowBody()
            let playing = store.captionNowPlaying.id == clip.id
            let over = CaptionOps.overLimit(text, rule: rule)
            HStack(alignment: .top, spacing: 8) {
                gutter(playing: playing, over: over)
                CaptionTextField(store: store, clipID: clip.id, text: text, isActive: isActive, rightToLeft: rightToLeft,
                                 highlights: highlights, current: current,
                                 accessibilityLabel: CaptionStamp.accessibility(index: index, clip))
                    .frame(minHeight: 20)
                    .opacity(playing && !isActive ? 1 : (isActive ? 1 : 0.92))
                buttons
            }
            .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 8)
            .background(isActive ? Theme.accentDim.opacity(0.55) : (hover ? Theme.Valse.raised : .clear))
            .overlay(alignment: .leading) { if isActive { Rectangle().fill(Theme.accent).frame(width: 3) } }
            .overlay(alignment: .bottom) { if !isLast { DashedLine().stroke(Theme.separator, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(height: 1) } }
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            // gutter / empty area: like a click in the text, caret at the end
            .onTapGesture {
                if !isActive, let tv = CaptionTextRegistry.view(clip.id) { CaptionTextRegistry.noteClick(tv) }
                store.captionActivate(clip.id, seek: true)
                store.captionFocus(clip.id, caret: .end)
            }
            .contextMenu { menu }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: CaptionStamp.accessibility(index: index, clip)))
            .accessibilityAction(named: Text(verbatim: tr("capedit.replay"))) { store.captionReplay(clip.id) }
            .accessibilityAction(named: Text(verbatim: tr("capedit.insertAfter"))) { store.captionInsertAfter(clip.id) }
            .accessibilityAction(named: Text(verbatim: tr("captions.delete"))) { store.captionDelete(clip.id, focusNext: false) }
            .testID("captions.row.\(index)")
        }
    }

    /// Badge text + tooltip of a caption that does not fit the split rule (CAP-UX2-BADGE).
    static func badge(_ o: CaptionOverLimit) -> (label: String, help: String) {
        switch o {
        case .lineTooLong(let n, let m): return (tr("capedit.over.chars", n, m), tr("capedit.over.help.line", n, m))
        case .tooLong(let n, let m, let lines, let per): return (tr("capedit.over.chars", n, m), tr("capedit.over.help.caption", n, lines, per))
        case .tooManyLines(let l, let m): return (tr("capedit.over.lines", l, m), tr("capedit.over.help.lines", l, m))
        }
    }

    func gutter(playing: Bool, over: CaptionOverLimit?) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 2) {
                Text(verbatim: "▸").font(.system(size: 9)).foregroundStyle(Theme.accentText).opacity(playing ? 1 : 0)
                    .accessibilityLabel(Text(verbatim: tr("capedit.nowPlaying"))).accessibilityHidden(!playing)
                Text(verbatim: CaptionStamp.short(clip.start)).font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(isActive || playing ? Theme.textPrimary : IStyle.caption)
            }
            if let over {
                let b = Self.badge(over)
                Text(verbatim: b.label).font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.warning).lineLimit(1).minimumScaleFactor(0.75)
                    .help(b.help)
                    .accessibilityLabel(Text(verbatim: b.help))
                    .testID("captions.over.\(index)")
            }
        }
        .frame(width: 60, alignment: .trailing)
        .padding(.top, 2)
        .testID(playing ? "captions.nowPlaying" : "captions.gutter.\(index)")
    }

    var buttons: some View {
        HStack(spacing: 4) {
            rowButton("arrow.counterclockwise", tr("capedit.replay")) {
                store.captionReplay(clip.id, keepPlaying: NSEvent.modifierFlags.contains(.option))
            }.testID("captions.replay.\(index)")
            rowButton("plus", tr("capedit.insertAfter")) { store.captionInsertAfter(clip.id) }.testID("captions.add.\(index)")
            rowButton("trash", tr("captions.delete")) { store.captionDelete(clip.id, focusNext: store.captionEditor.editingID == clip.id) }
                .testID("captions.delete.\(index)")
        }
        .opacity(isActive ? 1 : (hover ? 0.6 : 0))
        .allowsHitTesting(isActive || hover)
        .frame(width: 80, alignment: .trailing)
    }

    @ViewBuilder var menu: some View {
        Button(tr("capedit.setStart")) { store.captionSetEdgeToPlayhead(clip.id, start: true) }
        Button(tr("capedit.setEnd")) { store.captionSetEdgeToPlayhead(clip.id, start: false) }
        Divider()
        Button(tr("capedit.mergeNext")) { store.captionMergeNext(clip.id, caret: (text as NSString).length) }.disabled(isLast)
        Button(tr("capedit.splitAtCaret")) {
            if let tv = CaptionTextRegistry.current, tv.coordinator?.id == clip.id { store.captionReturn(clip.id, caret: tv.selectedRange().location) }
        }
        Divider()
        Button(tr("captions.delete")) { store.captionDelete(clip.id, focusNext: false) }
    }

    func rowButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                .frame(width: 24, height: 24).background(Theme.buttonSecondary, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(verbatim: help))
    }
}

struct DashedLine: Shape {
    func path(in r: CGRect) -> Path { Path { p in p.move(to: CGPoint(x: r.minX, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY)) } }
}

/// Pinned under the list, above the footer (CAP-UX2-TIMINGBAR): timing of the active caption, start ‹ › → end ‹ ›
/// (1 frame per click, 10 with ⇧; an edge pushes into the neighbour, CAP-UX2-PUSH), duration, reading speed. With no
/// active caption the controls are disabled and a placeholder shows; the bar keeps its height either way, so the
/// list never resizes.
struct CaptionTimingBar: View {
    let store: EditorStore
    let track: Track
    static let height: CGFloat = 34

    var body: some View {
        WithPerceptionTracking {
            let clip = store.captionActiveID.flatMap { id in track.clips.first { $0.id == id } }
            HStack(spacing: 6) {
                nudge("start", clip.map { CaptionStamp.precise($0.start) }, helpKey: "capedit.start") { d in
                    if let id = store.captionActiveID { store.captionNudge(id, startFrames: d) }
                }
                Text(verbatim: "→").font(.system(size: 11)).foregroundStyle(Theme.textSecondary).opacity(clip == nil ? 0.4 : 1)
                nudge("end", clip.map { CaptionStamp.precise($0.end) }, helpKey: "capedit.end") { d in
                    if let id = store.captionActiveID { store.captionNudge(id, endFrames: d) }
                }
                Spacer(minLength: 4)
                if let clip {
                    let text = CaptionOps.text(clip)?.string ?? ""
                    Text(verbatim: tr("capedit.duration", String(format: "%.1f", clip.duration.seconds))
                         + " · " + tr("capedit.cps", Int(CaptionOps.charsPerSecond(text, duration: clip.duration).rounded())))
                        .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        .testID("captions.timing.duration")
                } else {
                    Text(loc: "capedit.timing.placeholder").font(.system(size: 10.5)).foregroundStyle(IStyle.caption)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .testID("captions.timing.placeholder")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: Self.height)
            .testID("captions.timing")
        }
    }

    func nudge(_ id: String, _ value: String?, helpKey: String, _ step: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 1) {
            arrow("chevron.left", tr("capedit.nudgeEarlier", tr(helpKey)), enabled: value != nil) {
                step(NSEvent.modifierFlags.contains(.shift) ? -10 : -1)
            }
            .testID("captions.timing.\(id).minus")
            Text(verbatim: value ?? "–:––.––").font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(value == nil ? Theme.textTertiary : Theme.textPrimary)
                .frame(minWidth: 40)
            arrow("chevron.right", tr("capedit.nudgeLater", tr(helpKey)), enabled: value != nil) {
                step(NSEvent.modifierFlags.contains(.shift) ? 10 : 1)
            }
            .testID("captions.timing.\(id).plus")
        }
        .padding(.horizontal, 2).frame(height: 20)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 4))
        .opacity(value == nil ? 0.5 : 1)
    }

    func arrow(_ symbol: String, _ help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textSecondary)
                .frame(width: 16, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled).help(help).accessibilityLabel(Text(verbatim: help))
    }
}

// MARK: - E. Footer

struct CaptionFooter: View {
    let store: EditorStore
    let track: Track
    @State private var showKeys = false

    var body: some View {
        WithPerceptionTracking {
            let n = track.clips.count
            HStack(spacing: 8) {
                Text(verbatim: n == 1 ? tr("capedit.count.one") : tr("capedit.count", n))
                    .font(Theme.Fonts.hint).foregroundStyle(IStyle.caption).testID("captions.count")
                Spacer()
                Button { showKeys.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle").font(.system(size: 11))
                        Text(loc: "capedit.shortcuts").font(Theme.Fonts.hint)
                    }
                    .foregroundStyle(IStyle.caption).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fittedPopover(isPresented: $showKeys, arrowEdge: .top) { CaptionShortcutsCard() }
                .testID("captions.shortcuts")
                if store.captionEditor.followSuspended {
                    PillButton(title: tr("capedit.follow"), symbol: "arrow.down", accent: true) { store.captionResumeFollow() }
                        .testID("captions.follow")
                }
            }
            .padding(.horizontal, 12).frame(height: 34)
        }
    }
}

/// ⓘ Shortcuts popover (replaces the old one-line hint).
struct CaptionShortcutsCard: View {
    static let rows: [(String, String)] = [
        ("↩", "capedit.key.split"), ("⇧↩", "capedit.key.lineBreak"), ("⌘↩", "capedit.replay"),
        ("⇥ / ⇧⇥", "capedit.key.nextPrev"), ("⌫", "capedit.key.mergeUp"), ("⌦", "capedit.key.mergeDown"),
        ("⇧⌘⌫", "captions.delete"), ("⌥⌘I / ⌥⌘O", "capedit.key.setEdges"), ("⌘Z / ⇧⌘Z", "capedit.key.undo"),
        ("⌘F · ⌘G", "capedit.key.search"), ("esc", "capedit.key.escape"),
    ]
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Self.rows, id: \.1) { k, key in
                    WithPerceptionTracking {
                        HStack(spacing: 10) {
                            Text(verbatim: k).font(.system(size: 11.5, weight: .semibold).monospaced()).foregroundStyle(Theme.textPrimary)
                                .frame(width: 96, alignment: .leading)
                            Text(loc: key).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
            .padding(14)
        }
    }
}

// MARK: - Empty states

/// "No captions yet" (no caption track) or an empty language: Generate from speech · Import a file · Type a script.
struct CaptionEmptyCard: View {
    let store: EditorStore
    let track: Track?

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 10) {
                Text(loc: track == nil ? "capedit.empty.title" : "capedit.emptyLanguage.title")
                    .font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.textPrimary)
                HintText(text: tr("capedit.empty.hint"))
                HStack(spacing: 8) {
                    PillButton(title: tr("capedit.generate"), accent: true) { store.openAutoCaptions(language: track?.captionLanguage) }
                        .testID("captions.empty.generate")
                    PillButton(title: tr("capedit.importFile")) { store.chooseCaptionFileToImport() }.testID("captions.empty.import")
                    PillButton(title: tr("capedit.typeScript")) { store.openScriptCaptions() }.testID("captions.empty.script")
                }
                if let track {
                    PillButton(title: tr("capedit.deleteLanguage")) { store.captionDeleteLanguage(track.id) }.testID("captions.empty.delete")
                }
            }
            .padding(14)
            .testID("captions.empty")
        }
    }
}
