import SwiftUI
import AppKit
import Perception
import ValseCore
import ValseEngine

/// A responder that takes some keys itself before the app shortcuts (`ShortcutRegistry.handle` lets them through).
@MainActor
protocol KeyFocusOwner: AnyObject {
    /// Handles the key when it is one of its own (before the app shortcuts). Returns true when handled.
    func handleOwnedKey(_ e: NSEvent) -> Bool
}

/// The caption editor's focused text view and list (UI test dump: `ui.captionEditor.caret`).
@MainActor
enum CaptionTextRegistry {
    static weak var current: CaptionNSTextView?
    static weak var list: CaptionListKeyNSView?
    static weak var listClip: NSClipView?
    static var caret: Int? {
        guard let tv = current, tv.window?.firstResponder === tv else { return nil }
        return tv.selectedRange().location
    }
    /// Selected length in the focused caption (UI tests: a simple click selects nothing, CAP-UX2-JUMP).
    static var selectionLength: Int {
        guard let tv = current, tv.window?.firstResponder === tv else { return 0 }
        return tv.selectedRange().length
    }
    /// Text views of the caption rows on screen, by clip id.
    static let views = NSMapTable<NSString, CaptionNSTextView>.strongToWeakObjects()
    static func view(_ id: ClipID) -> CaptionNSTextView? { views.object(forKey: id.description as NSString) }
    /// Caption texts on screen that show a selection (CAP-UX2-SELECTION: only the edited one may).
    static var rowsWithSelection: Int {
        (views.objectEnumerator()?.allObjects as? [CaptionNSTextView] ?? []).filter { $0.window != nil && $0.selectedRange().length > 0 }.count
    }
    /// The last clicked caption text and its window y at the click (UI tests: `clickDrift`).
    static weak var clicked: CaptionNSTextView?
    static var clickedY: CGFloat = 0
    static func noteClick(_ tv: CaptionNSTextView) { clicked = tv; clickedY = tv.windowY() }
    /// How far the clicked caption moved on screen since the click (-1: none / gone).
    static var clickDrift: Double {
        guard let tv = clicked, tv.window != nil else { return -1 }
        return Double(abs(tv.windowY() - clickedY))
    }
}

/// One caption's text (CAP-EDITOR-UX). Native NSTextView: a click puts the caret where it lands. Every keystroke
/// updates the model live (typing burst = one undo step, `EditorStore.captionTyped`); the text is reloaded from the
/// model whenever it changes outside a burst (undo, replace, merge), so a stale string never overwrites an edit.
struct CaptionTextField: NSViewRepresentable {
    let store: EditorStore
    let clipID: ClipID
    /// Model text (an input, so SwiftUI calls `updateNSView` when it changes).
    let text: String
    let isActive: Bool
    let rightToLeft: Bool
    /// Search matches in this caption (UTF-16 ranges) and the current one.
    let highlights: [NSRange]
    let current: NSRange?
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> CaptionNSTextView {
        let tv = CaptionNSTextView()
        tv.delegate = context.coordinator
        tv.coordinator = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = false          // the project's undo stack (EditorStore.undo) is the only one
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: 13)
        tv.textColor = NSColor(Theme.textPrimary)
        tv.insertionPointColor = NSColor(Theme.accentText)
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        // SwiftUI sizes the view (sizeThatFits measures offscreen): a self-resizing text view fed back into SwiftUI's
        // layout and spun the main thread (CAP-UX2-CRASH)
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = []
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.heightTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.string = text
        tv.setAccessibilityIdentifier("captions.text.\(clipID)")
        CaptionTextRegistry.views.setObject(tv, forKey: clipID.description as NSString)
        return tv
    }

    func updateNSView(_ tv: CaptionNSTextView, context: Context) {
        let c = context.coordinator
        c.parent = self
        CaptionTextRegistry.views.setObject(tv, forKey: clipID.description as NSString)
        tv.setAccessibilityLabel(accessibilityLabel)
        tv.placeholder = tr("capedit.placeholder")
        if tv.baseWritingDirection != (rightToLeft ? .rightToLeft : .leftToRight) {
            tv.baseWritingDirection = rightToLeft ? .rightToLeft : .leftToRight
            tv.alignment = rightToLeft ? .right : .natural
        }
        // reload from the model unless this view is the one typing it (its string is already the newer one)
        if tv.string != text, !(store.captionEditor.typingID == clipID && tv.window?.firstResponder === tv), !tv.hasMarkedText() {
            let sel = tv.selectedRange()
            tv.string = text
            let len = (text as NSString).length
            tv.setSelectedRange(NSRange(location: min(sel.location, len), length: 0))
            tv.needsDisplay = true
        }
        tv.applyHighlights(highlights, current: current)
        c.tracking.run { [weak c, weak tv] in
            guard let c, let tv else { return }
            if let req = c.parent.store.captionEditor.focus, req.id == c.parent.clipID { tv.scheduleFocus(req) }
        }
    }

    /// Measured offscreen (`CaptionTextMeasure`), never by resizing the live text view: SwiftUI proposes several widths
    /// per pass, and re-laying out the live view at each one resized it, which invalidated SwiftUI's layout again — a
    /// main-thread layout storm in the caption list (CAP-UX2-CRASH, owner's 0.4.0 hang of 2026-10-27).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: CaptionNSTextView, context: Context) -> CGSize? {
        let w = max(proposal.width ?? 240, 40)
        return CGSize(width: w, height: CaptionTextMeasure.height(tv.string, width: w, font: tv.font ?? .systemFont(ofSize: 13)))
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CaptionTextField
        let tracking = RepresentableTracking()
        init(_ p: CaptionTextField) { parent = p }
        var store: EditorStore { parent.store }
        var id: ClipID { parent.clipID }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            store.captionTyped(id, tv.string)
        }

        /// A click in the text (before AppKit places the caret): a row that wasn't active becomes active; paused, the
        /// playhead jumps to the caption and the timeline shows it. A click in the active row only moves the caret.
        func willClick(_ tv: CaptionNSTextView, focusedByThisClick: Bool) {
            store.endCaptionTyping()
            // a click in the caption being edited only moves the caret
            guard focusedByThisClick || !(store.captionEditor.editingID == id && tv.window?.firstResponder === tv) else { return }
            store.captionActivate(id, seek: true)
        }

        func didBecomeFirstResponder() { store.captionEditingBegan(id) }
        func didResignFirstResponder() { store.captionEditingEnded(id) }

        /// The editor keys (CAP-EDITOR-UX §3). Returns true when handled.
        func handle(_ e: NSEvent, in tv: CaptionNSTextView) -> Bool {
            let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
            let sel = tv.selectedRange()
            let len = (tv.string as NSString).length
            let atStart = sel.length == 0 && sel.location == 0
            let atEnd = sel.length == 0 && sel.location >= len
            switch (e.keyCode, mods) {
            case (36, []), (76, []):                                   // ↩ split / next / new
                store.captionReturn(id, caret: sel.location); return true
            case (36, .shift), (36, .option), (76, .shift), (76, .option):   // line break inside the caption
                tv.insertText("\n", replacementRange: sel); return true
            case (36, .command), (76, .command):                       // ⌘↩ replay line
                store.captionReplay(id); return true
            case (48, []):                                             // Tab / ⇧Tab
                store.captionMove(from: id, 1, caret: .end); return true
            case (48, .shift):
                store.captionMove(from: id, -1, caret: .end); return true
            case (126, []):                                            // ↑ on the first line → previous caption
                let l = tv.caretLine()
                guard l.first, CaptionOps.neighbour(of: id, -1, in: store.project.timeline) != nil else { store.endCaptionTyping(); return false }
                store.captionMove(from: id, -1, caret: .x(l.x, lastLine: true)); return true
            case (125, []):                                            // ↓ on the last line → next caption
                let l = tv.caretLine()
                guard l.last, CaptionOps.neighbour(of: id, 1, in: store.project.timeline) != nil else { store.endCaptionTyping(); return false }
                store.captionMove(from: id, 1, caret: .x(l.x, lastLine: false)); return true
            case (123, []):                                            // ← at 0 → end of the previous caption
                guard atStart, CaptionOps.neighbour(of: id, -1, in: store.project.timeline) != nil else { store.endCaptionTyping(); return false }
                store.captionMove(from: id, -1, caret: .end); return true
            case (124, []):                                            // → at the end → start of the next one
                guard atEnd, CaptionOps.neighbour(of: id, 1, in: store.project.timeline) != nil else { store.endCaptionTyping(); return false }
                store.captionMove(from: id, 1, caret: .offset(0)); return true
            case (51, []):                                             // ⌫ at 0 → merge into the previous caption
                guard atStart, CaptionOps.neighbour(of: id, -1, in: store.project.timeline) != nil else { return false }
                store.captionMergeIntoPrevious(id); return true
            case (117, []):                                            // ⌦ at the end → merge the next one in
                guard atEnd, CaptionOps.neighbour(of: id, 1, in: store.project.timeline) != nil else { return false }
                store.captionMergeNext(id, caret: sel.location); return true
            case (51, [.command, .shift]):                             // ⇧⌘⌫ delete this caption
                store.captionDelete(id, focusNext: true); return true
            case (34, [.command, .option]):                            // ⌥⌘I / ⌥⌘O start / end to the playhead
                store.captionSetEdgeToPlayhead(id, start: true); return true
            case (31, [.command, .option]):
                store.captionSetEdgeToPlayhead(id, start: false); return true
            case (6, .command):                                        // ⌘Z / ⇧⌘Z on the project's stack
                store.undo(); return true
            case (6, [.command, .shift]):
                store.redo(); return true
            case (53, []):                                             // Esc: stop editing, the list keeps the keys
                store.endCaptionTyping()
                if let list = CaptionTextRegistry.list, list.window === tv.window { tv.window?.makeFirstResponder(list) }
                else { tv.window?.makeFirstResponder(nil) }
                return true
            default:
                return CaptionEditorKeys.search(e, store: store)
            }
        }
    }
}

/// Search shortcuts shared by the caption text, the list and the search field (⌘F ⌘G ⇧⌘G ⌥⌘F).
@MainActor
enum CaptionEditorKeys {
    static func search(_ e: NSEvent, store: EditorStore) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let ed = store.captionEditor
        switch (e.keyCode, mods) {
        case (3, .command): ed.searchFocusToken += 1; return true
        case (3, [.command, .option]): ed.showReplace.toggle(); ed.searchFocusToken += 1; return true
        case (5, .command): store.captionStepMatch(1); return true
        case (5, [.command, .shift]): store.captionStepMatch(-1); return true
        default: return false
        }
    }
}

final class CaptionNSTextView: NSTextView {
    weak var coordinator: CaptionTextField.Coordinator?
    var placeholder = ""
    private var appliedHighlights: [NSRange] = []
    private var appliedCurrent: NSRange?
    private var pendingFocus: UUID?

    /// The window makes the text view first responder BEFORE delivering the click's mouseDown: remember that click.
    private var focusingClick: TimeInterval?

    /// A click activates its row only once the button is released (CAP-UX2-JUMP): AppKit's text tracking loop runs on
    /// an unchanged layout, so a simple click places the caret and never drags a selection. The activation itself never
    /// moves the clicked text either (`CaptionEditorState.stripAbove`).
    override func mouseDown(with event: NSEvent) {
        let fresh = focusingClick == event.timestamp
        focusingClick = nil
        CaptionTextRegistry.noteClick(self)
        super.mouseDown(with: event)
        if let c = coordinator { MainActor.assumeIsolated { c.willClick(self, focusedByThisClick: fresh) } }
    }

    override func becomeFirstResponder() -> Bool {
        if let e = NSApp.currentEvent, e.type == .leftMouseDown { focusingClick = e.timestamp }
        let ok = super.becomeFirstResponder()
        if ok, let c = coordinator {
            MainActor.assumeIsolated {
                CaptionTextRegistry.current = self
                c.didBecomeFirstResponder()
            }
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        // CAP-UX2-SELECTION: a caption that stops being edited keeps no selection highlight. Collapsed before resigning:
        // changing the selection afterwards brings the (macOS 14+) insertion indicator back on a view that isn't editing.
        let sel = selectedRange()
        if sel.length > 0 { setSelectedRange(NSRange(location: sel.location, length: 0)) }
        let ok = super.resignFirstResponder()
        if ok, let c = coordinator { MainActor.assumeIsolated { c.didResignFirstResponder() } }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        if let c = coordinator, MainActor.assumeIsolated({ c.handle(event, in: self) }) { return }
        super.keyDown(with: event)
    }

    /// ⌘ keys reach the focused caption before the menu (⌘Z must undo on the project's stack, ⌘↩ replay…).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown, event.modifierFlags.contains(.command),
              let c = coordinator else { return super.performKeyEquivalent(with: event) }
        let codes: Set<UInt16> = [36, 76, 6, 34, 31, 3, 5, 51]
        guard codes.contains(event.keyCode) else { return super.performKeyEquivalent(with: event) }
        if MainActor.assumeIsolated({ c.handle(event, in: self) }) { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Edit ▸ Undo / Redo while a caption is focused: the project's stack.
    @objc func undo(_ sender: Any?) { if let c = coordinator { MainActor.assumeIsolated { c.store.undo() } } }
    @objc func redo(_ sender: Any?) { if let c = coordinator { MainActor.assumeIsolated { c.store.redo() } } }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) || item.action == #selector(redo(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, let id = pendingFocus { pendingFocus = nil; applyFocusNow(id) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, !placeholder.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: NSColor(Theme.textTertiary)]
            (placeholder as NSString).draw(at: NSPoint(x: textContainerOrigin.x, y: textContainerOrigin.y), withAttributes: attrs)
        }
    }

    // MARK: Focus

    func scheduleFocus(_ req: CaptionFocusRequest) {
        guard pendingFocus != req.token else { return }
        pendingFocus = req.token
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, self.pendingFocus == req.token else { return }
            self.pendingFocus = nil
            self.applyFocusNow(req.token)
        }
    }

    private func applyFocusNow(_ token: UUID) {
        MainActor.assumeIsolated {
            guard let c = coordinator, let req = c.store.captionEditor.focus, req.token == token, let w = window else { return }
            c.store.captionEditor.focus = nil
            if w.firstResponder !== self { w.makeFirstResponder(self) }
            let len = (string as NSString).length
            let loc: Int
            switch req.caret {
            case .offset(let o): loc = min(max(o, 0), len)
            case .end: loc = len
            case .x(let x, let lastLine): loc = index(atX: x, lastLine: lastLine)
            }
            setSelectedRange(NSRange(location: loc, length: 0))
            scrollRangeToVisible(NSRange(location: loc, length: 0))
        }
    }

    // MARK: Geometry

    /// Whether the caret is on the first / last visual line, and its x.
    func caretLine() -> (first: Bool, last: Bool, x: CGFloat) {
        guard let lm = layoutManager, let tc = textContainer else { return (true, true, 0) }
        let len = (string as NSString).length
        guard len > 0, lm.numberOfGlyphs > 0 else { return (true, true, 0) }
        lm.ensureLayout(for: tc)
        let loc = selectedRange().location
        if loc >= len, string.hasSuffix("\n") {
            return (false, true, 0)   // on the empty line after a trailing line break
        }
        let gi = lm.glyphIndexForCharacter(at: min(loc, len - 1))
        let frag = lm.lineFragmentRect(forGlyphAt: gi, effectiveRange: nil)
        let first = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let last = lm.lineFragmentRect(forGlyphAt: lm.numberOfGlyphs - 1, effectiveRange: nil)
        let g = lm.boundingRect(forGlyphRange: NSRange(location: gi, length: 1), in: tc)
        let x = loc >= len ? g.maxX : g.minX
        return (frag.minY <= first.minY + 0.5, frag.minY >= last.minY - 0.5, x)
    }

    /// Character index nearest to x on the first / last visual line.
    func index(atX x: CGFloat, lastLine: Bool) -> Int {
        guard let lm = layoutManager, let tc = textContainer, lm.numberOfGlyphs > 0 else { return 0 }
        lm.ensureLayout(for: tc)
        let frag = lm.lineFragmentRect(forGlyphAt: lastLine ? lm.numberOfGlyphs - 1 : 0, effectiveRange: nil)
        var f: CGFloat = 0
        let i = lm.characterIndex(for: NSPoint(x: x, y: frag.midY), in: tc, fractionOfDistanceBetweenInsertionPoints: &f)
        let len = (string as NSString).length
        let r = f > 0.5 ? i + 1 : i
        // never land after the line break of the line we aimed at
        if r > 0, r <= len, (string as NSString).character(at: r - 1) == 10, !lastLine { return r - 1 }
        return min(r, len)
    }

    // MARK: Search highlights (temporary attributes: the text is never modified)

    func applyHighlights(_ ranges: [NSRange], current: NSRange?) {
        guard ranges != appliedHighlights || current != appliedCurrent, let lm = layoutManager else { return }
        appliedHighlights = ranges; appliedCurrent = current
        let len = (string as NSString).length
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: len))
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: len))
        for r in ranges where NSMaxRange(r) <= len {
            let isCurrent = r == current
            lm.addTemporaryAttribute(.backgroundColor, value: NSColor(Theme.warning).withAlphaComponent(isCurrent ? 1 : 0.45), forCharacterRange: r)
            if isCurrent { lm.addTemporaryAttribute(.foregroundColor, value: NSColor(Theme.onAccent), forCharacterRange: r) }
        }
    }

    /// Window y of the text (UI tests: `ui.captionEditor.clickDrift`, the clicked caption must not move).
    func windowY() -> CGFloat { convert(bounds.origin, to: nil).y }
}

// MARK: - List focus (after Esc) and scroll watching

/// Takes the keyboard after Esc in a caption: ↑ ↓ move the active row, ↩ edits (caret at the end), ⌫ deletes,
/// Space plays / pauses, Esc gives the keys back to the timeline.
struct CaptionListKeyView: NSViewRepresentable {
    let store: EditorStore
    func makeNSView(context: Context) -> CaptionListKeyNSView {
        let v = CaptionListKeyNSView()
        v.store = store
        v.setAccessibilityIdentifier("captions.list.keys")
        CaptionTextRegistry.list = v
        return v
    }
    func updateNSView(_ v: CaptionListKeyNSView, context: Context) {
        v.store = store
        CaptionTextRegistry.list = v
    }
}

final class CaptionListKeyNSView: NSView, KeyFocusOwner {
    weak var store: EditorStore?
    private var scrollMonitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        if let s = store { MainActor.assumeIsolated { s.captionListFocusChanged(true) } }
        return true
    }

    override func resignFirstResponder() -> Bool {
        if let s = store { MainActor.assumeIsolated { s.captionListFocusChanged(false) } }
        return true
    }

    func handleOwnedKey(_ e: NSEvent) -> Bool { e.type == .keyDown && handle(e) }

    override func keyDown(with e: NSEvent) {
        if !handle(e) { super.keyDown(with: e) }
    }

    private func handle(_ e: NSEvent) -> Bool {
        guard let store else { return false }
        return MainActor.assumeIsolated { () -> Bool in
            let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
            if !mods.isEmpty { return CaptionEditorKeys.search(e, store: store) }
            switch e.keyCode {
            case 126: store.captionListStep(-1)
            case 125: store.captionListStep(1)
            case 36, 76: if let id = store.captionActiveID { store.captionFocus(id, caret: .end) }
            case 51, 117: if let id = store.captionActiveID { store.captionDelete(id, focusNext: false) }
            case 49: store.togglePlay()
            case 53: window?.makeFirstResponder(nil)
            default: return false
            }
            return true
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
        guard window != nil else { return }
        // a wheel / trackpad scroll over the caption list suspends playback auto-follow (CAP-EDITOR-UX §4)
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            let box = UncheckedSendable(e)
            MainActor.assumeIsolated {
                guard let self, let w = self.window, box.value.window === w, let store = self.store else { return }
                let p = self.convert(box.value.locationInWindow, from: nil)
                if self.bounds.contains(p), box.value.scrollingDeltaY != 0 {
                    store.captionEditor.allowListScroll()
                    store.captionListUserScrolled()
                }
            }
            return e
        }
    }
}

/// Lives inside the list's scroll view: watches its scroll position. A scroll nobody asked for (no reveal, no wheel,
/// no keep-in-place correction) is counted (`ui.captionEditor.unrequestedScrolls`): the list must never jump when a
/// caption starts being edited (owner requirement).
struct CaptionScrollProbe: NSViewRepresentable {
    let store: EditorStore
    func makeNSView(context: Context) -> CaptionScrollProbeView {
        let v = CaptionScrollProbeView()
        v.store = store
        return v
    }
    func updateNSView(_ v: CaptionScrollProbeView, context: Context) { v.store = store }
}

final class CaptionScrollProbeView: NSView {
    weak var store: EditorStore?
    private weak var observed: NSClipView?
    private var lastY: CGFloat = 0
    private var token: NSObjectProtocol?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let t = token { NotificationCenter.default.removeObserver(t); token = nil }
        guard window != nil, let clip = enclosingScrollView?.contentView else { return }
        observed = clip
        lastY = clip.bounds.origin.y
        CaptionTextRegistry.listClip = clip
        clip.postsBoundsChangedNotifications = true
        token = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrolled() }
        }
    }

    private func scrolled() {
        guard let clip = observed, let store else { return }
        let y = clip.bounds.origin.y
        defer { lastY = y }
        guard abs(y - lastY) > 0.5 else { return }
        store.captionEditor.noteListScroll()
    }
}

// MARK: - Offscreen measuring (CAP-UX2-CRASH)

/// Heights of caption texts, laid out in a private TextKit stack (the live text views are never resized to measure)
/// and cached by (text, width, font). `measuresLastSecond` / `layoutsLastSecond` let a UI test prove the list is not
/// re-measuring in a loop (`ui.captionEditor.measuresLastSecond`).
@MainActor
enum CaptionTextMeasure {
    private struct Key: Hashable { let text: String; let width: CGFloat; let font: String; let size: CGFloat }
    private static var cache: [Key: CGFloat] = [:]
    private static let storage = NSTextStorage()
    private static let container: NSTextContainer = {
        let tc = NSTextContainer(size: NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        let lm = NSLayoutManager()
        lm.addTextContainer(tc)
        storage.addLayoutManager(lm)
        return tc
    }()
    /// sizeThatFits calls / real TextKit layouts, time-stamped (the last second is what counts).
    private static var calls: [TimeInterval] = []
    private static var layouts: [TimeInterval] = []

    static func height(_ s: String, width: CGFloat, font: NSFont) -> CGFloat {
        let now = ProcessInfo.processInfo.systemUptime
        record(&calls, now)
        let key = Key(text: s, width: width, font: font.fontName, size: font.pointSize)
        if let h = cache[key] { return h }
        record(&layouts, now)
        let tc = container
        guard let lm = tc.layoutManager else { return 18 }
        tc.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        storage.setAttributedString(NSAttributedString(string: s.isEmpty ? " " : s, attributes: [.font: font]))
        lm.ensureLayout(for: tc)
        let h = max(18, ceil(lm.usedRect(for: tc).height) + 2)   // usedRect includes the line after a trailing break
        if cache.count > 4000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = h
        return h
    }

    private static func record(_ a: inout [TimeInterval], _ now: TimeInterval) {
        a.append(now)
        if a.count > 64, let i = a.firstIndex(where: { $0 >= now - 1 }), i > 0 { a.removeFirst(i) }
    }

    /// Body evaluations of the caption list (`listBodiesLastSecond`): stays near 0 while playing.
    private static var listBodies: [TimeInterval] = []
    static func noteListBody() { record(&listBodies, ProcessInfo.processInfo.systemUptime) }
    static var listBodiesLastSecond: Int { let t = ProcessInfo.processInfo.systemUptime - 1; return listBodies.filter { $0 >= t }.count }
    private static var rowBodies: [TimeInterval] = []
    static func noteRowBody() { record(&rowBodies, ProcessInfo.processInfo.systemUptime) }
    static var rowBodiesLastSecond: Int { let t = ProcessInfo.processInfo.systemUptime - 1; return rowBodies.filter { $0 >= t }.count }

    static var measuresLastSecond: Int { let t = ProcessInfo.processInfo.systemUptime - 1; return calls.filter { $0 >= t }.count }
    static var layoutsLastSecond: Int { let t = ProcessInfo.processInfo.systemUptime - 1; return layouts.filter { $0 >= t }.count }
}
