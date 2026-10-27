import SwiftUI
import AppKit
import Perception
import ValseCore
import ValseEngine

// Quick cut (TL-048, docs/QUICK_CUT.md §1): toolbar button, in-window popover, open / close / apply flows.

extension EditorStore {
    /// Opens the Quick cut popover for the current selection (nothing selected = every audio / video clip).
    public func openQuickCut() {
        guard timelineUI.quickCut == nil else { return }
        timelineUI.quickCut = QuickCutSession(store: self)
        QuickCutEvents.shared.install(self)
    }

    public func closeQuickCut() { timelineUI.quickCut?.close() }

    public func toggleQuickCut() { if timelineUI.quickCut == nil { openQuickCut() } else { closeQuickCut() } }

    /// Background analysis of newly imported media (called by the import flow).
    func prefetchQuickCut(_ assets: [MediaAsset]) { QuickCutPrefetch.start(assets) }
}

/// Toolbar button: records its frame (the popover hangs from it) and shows the open state.
struct QuickCutButton: View {
    let store: EditorStore
    let isOpen: Bool
    var body: some View {
        WithPerceptionTracking {
            QuickCutIconButton(active: isOpen, help: tr("quickcut.tooltip")) { store.toggleQuickCut() }
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { store.timelineUI.quickCutButtonFrame = $0 }
                .testID("toolbar.quickCut")
        }
    }
}

/// Hosts the popover in the editor window (EditorView overlay): a real NSPopover is a separate window, which the
/// offscreen UI tests can neither snapshot nor click. Clicks outside it close it (QuickCutEvents) without being eaten,
/// so the player's play button keeps working while it is open.
struct QuickCutOverlay: View {
    let store: EditorStore
    var body: some View {
        WithPerceptionTracking {
            if let s = store.timelineUI.quickCut {
                GeometryReader { g in
                    WithPerceptionTracking {
                        let o = g.frame(in: .global).origin
                        let b = store.timelineUI.quickCutButtonFrame.offsetBy(dx: -o.x, dy: -o.y)
                        let w = QuickCutPopover.width
                        // whole points (crisp text, stable snapshots); above the button, inside the window
                        let x = min(max(8, (b.midX - w / 2).rounded(.down)), max(8, g.size.width - w - 8))
                        QuickCutPopover(session: s, store: store)
                            .fixedSize()
                            .padding(.leading, x)
                            .frame(width: g.size.width, height: max(0, (b.minY - 4).rounded(.down)), alignment: .bottomLeading)
                    }
                }
            }
        }
    }
}

struct QuickCutPopover: View {
    @Perception.Bindable var session: QuickCutSession
    let store: EditorStore
    static let width: CGFloat = 300

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: session.scopeText).font(Theme.Fonts.hint).foregroundStyle(Theme.textSecondary)
                    .testID("quickcut.scope")
                Text(loc: "quickcut.title").font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.textPrimary)
                HStack(spacing: 8) {
                    InspectorSlider(unit: session.unit, onBegin: {}, onChange: { session.setUnit($0) }, onEnd: {})
                        .testID("quickcut.slider")
                    QuickCutValueField(session: session).testID("quickcut.field")
                }
                Text(verbatim: session.summaryText).font(Theme.Fonts.row.monospacedDigit())
                    .foregroundStyle(session.canApply ? Theme.textPrimary : Theme.textSecondary)
                    .testID("quickcut.summary")
                if session.isAnalysing {
                    VStack(alignment: .leading, spacing: 4) {
                        GeometryReader { g in
                            WithPerceptionTracking {
                                ZStack(alignment: .leading) {
                                    Capsule().fill(IStyle.track)
                                    Capsule().fill(Theme.accent).frame(width: g.size.width * CGFloat(session.progress))
                                }
                            }
                        }
                        .frame(height: 3)
                        Text(verbatim: session.progressText).font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
                            .monospacedDigit()
                    }
                    .testID("quickcut.progress")
                }
                HStack {
                    Spacer()
                    Button(tr("quickcut.apply")) { session.apply() }
                        .buttonStyle(AccentButtonStyle())
                        .opacity(session.canApply ? 1 : 0.4)
                        .disabled(!session.canApply)
                        .testID("quickcut.apply")
                }
            }
            .padding(14)
            .frame(width: Self.width, alignment: .leading)
            .background(Theme.menu, in: RoundedRectangle(cornerRadius: 8))
            .valseFloatingCard(radius: 8, depth: 4)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { QuickCutEvents.shared.popoverFrame = $0 }
            .onExitCommand { session.close() }
            .testID("quickcut.popover")
        }
    }
}

/// "0.5 s" field bound to the slider value: typing + Return commits (clamped, 1 decimal) and gives the keyboard back
/// (Space then plays the preview), Esc reverts and leaves the field, focus loss commits.
struct QuickCutValueField: View {
    @Perception.Bindable var session: QuickCutSession
    @State private var text = ""
    @FocusState private var focused: Bool

    private var display: String { QuickCutSession.seconds(session.value) + " s" }

    private func commit() {
        if let v = QuickCutSession.parse(text) { session.setValue(v) }
        text = display
    }

    var body: some View {
        WithPerceptionTracking {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.numeric)
                .multilineTextAlignment(.center)
                .focused($focused)
                .onSubmit { commit(); focused = false }
                .onExitCommand { text = display; focused = false }
                .padding(.horizontal, 6)
                .frame(width: 56, height: 24)
                .background(IStyle.field, in: RoundedRectangle(cornerRadius: 4))
                .onAppear { text = display }
                .onValueChange(of: display) { _, v in if !focused { text = v } }
                .onValueChange(of: focused) { _, f in if !f { commit() } }
                .accessibilityLabel(Text(loc: "quickcut.title"))
        }
    }
}

/// While the popover is open: Esc closes it (outside text fields; the value field closes it on Esc itself, see
/// `onExitCommand`), a click outside it and its button closes it and still goes through, except clicks in the
/// player (play / pause, scrubbing: the preview is what the user is listening to) and left clicks on the timeline
/// canvas (they only move the playhead there, see `TimelineView.quickCutMouseDown`).
@MainActor
final class QuickCutEvents {
    static let shared = QuickCutEvents()
    var popoverFrame: CGRect = .zero
    private var monitor: Any?
    private weak var store: EditorStore?

    func install(_ store: EditorStore) {
        self.store = store
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { e in
            let box = UncheckedSendable(e)
            let consumed = MainActor.assumeIsolated { QuickCutEvents.shared.handle(box.value) }
            return consumed ? nil : e
        }
    }

    private func uninstall() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        popoverFrame = .zero
    }

    /// True = consumed.
    private func handle(_ e: NSEvent) -> Bool {
        guard let store, let session = store.timelineUI.quickCut else { uninstall(); return false }
        if e.type == .keyDown {
            guard e.keyCode == 53 else { return false }
            if let r = e.window?.firstResponder, r is NSText || r is NSTextView { return false }
            session.close()
            uninstall()
            return true
        }
        guard let window = e.window, let content = window.contentView else { return false }
        let p = content.convert(e.locationInWindow, from: nil)
        let top = CGPoint(x: p.x, y: content.isFlipped ? p.y : content.bounds.height - p.y)   // SwiftUI global space
        if popoverFrame.contains(top) || store.timelineUI.quickCutButtonFrame.contains(top) { return false }
        // a left click on the timeline itself only moves the playhead (TimelineView.quickCutMouseDown): stay open
        if e.type == .leftMouseDown, Self.hitsTimeline(e, in: content) { return false }
        if let player = PanelFocus.shared.host(.player), player.window === window {
            let local = player.convert(e.locationInWindow, from: nil)
            if player.bounds.contains(local) { return false }
        }
        session.close()
        uninstall()
        return false
    }

    /// The view under the event is the timeline canvas (or inside it); the toolbar above it doesn't count.
    static func hitsTimeline(_ e: NSEvent, in content: NSView) -> Bool {
        var v = content.hitTest(content.superview?.convert(e.locationInWindow, from: nil) ?? e.locationInWindow)
        while let x = v {
            if x is TimelineView { return true }
            v = x.superview
        }
        return false
    }
}
