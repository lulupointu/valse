import AppKit
import SwiftUI

/// BUG-SPACE-FOCUS: the editor's keyboard starts on the editor, never in a text field, so Space plays at once.
///
/// Root cause: NSWindow picks its first responder by itself. The first time a window goes on screen it makes its
/// `initialFirstResponder` first responder, and when that is nil it takes the first view of the key-view loop that
/// accepts it: the media panel's search field (`AssetSearchField`), the first text field of the editor. Every editor
/// that is on screen when its window first shows (`--open`: a project opened from Finder / the Dock / File ▸ Open in
/// New Window, a relaunch on a project, UI tests) started with the caret in the search field, and the app key monitor
/// leaves keys to a focused text field, so Space typed a space instead of playing. AppKit can redo that pick while
/// the window itself is first responder, which is what Home → editor leaves once Home's views are gone.
///
/// Fix (one place): the editor hosts an invisible, click-through `EditorKeyAnchorView` that accepts first responder
/// and handles no key itself (keys go up the responder chain exactly as when the window was first responder). It is
/// the window's `initialFirstResponder`, and it takes the keyboard when the editor appears, when a project is opened
/// (`AppModel.enterEditor`: Home, project switcher, recent projects, new project) and when the window becomes key
/// with no responder. A text field the user clicks still focuses as before; Esc in the media search field or a click
/// on the timeline gives the keyboard back.
@MainActor
enum EditorKeyFocus {
    /// Gives the keyboard back to the editor of `window` (its anchor; the window itself when there is no editor).
    static func restore(in window: NSWindow?) {
        guard let window else { return }
        window.makeFirstResponder(anchor(in: window))
    }

    /// A project was opened in this process: its editor takes the keyboard (a text field focused before, on Home or in
    /// the project switcher, keeps nothing). Deferred one turn so the editor's views exist.
    static func projectOpened() {
        nextTurn {
            for w in NSApplication.shared.windows { anchor(in: w)?.claim(includingText: true) }
        }
    }

    /// Runs `work` on the next main run-loop turn (any mode; unlike `DispatchQueue.main.async`, also inside a nested
    /// run loop of a main-queue block, e.g. a test spinning the run loop).
    static func nextTurn(_ work: @escaping @Sendable @MainActor () -> Void) {
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { work() } }
    }

    static func anchor(in window: NSWindow) -> EditorKeyAnchorView? {
        window.contentView.flatMap { PanelFocus.firstView(in: $0) { $0 is EditorKeyAnchorView } } as? EditorKeyAnchorView
    }

    /// Whether the anchor should take the keyboard from `responder`: nobody has it (nil / the window itself), or
    /// (`includingText`, when the editor appears or a project opens) a text field took it on its own.
    static func shouldClaim(_ responder: NSResponder?, in window: NSWindow, includingText: Bool) -> Bool {
        guard let responder else { return true }
        if responder === window { return true }
        return includingText && responder is NSText
    }
}

/// Invisible keyboard home of the editor (see `EditorKeyFocus`).
final class EditorKeyAnchorView: NSView {
    private var keyObserver: NSObjectProtocol?

    override var acceptsFirstResponder: Bool { true }
    override var focusRingType: NSFocusRingType { get { .none } set {} }
    /// Never takes clicks: whatever is under it gets them.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = keyObserver { NotificationCenter.default.removeObserver(o); keyObserver = nil }
        guard let w = window else { return }
        w.initialFirstResponder = self
        claim(includingText: true)
        // SwiftUI may still be building the panels (and AppKit picking a text field) during this turn
        EditorKeyFocus.nextTurn { [weak self] in self?.claim(includingText: true) }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.claim(includingText: false) }
        }
    }

    /// Takes the keyboard when nobody (or, with `includingText`, a text field) has it.
    func claim(includingText: Bool) {
        guard let w = window, EditorKeyFocus.shouldClaim(w.firstResponder, in: w, includingText: includingText) else { return }
        w.makeFirstResponder(self)
    }
}

/// SwiftUI host of the anchor (EditorView's background).
struct EditorKeyAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> EditorKeyAnchorView { EditorKeyAnchorView() }
    func updateNSView(_ v: EditorKeyAnchorView, context: Context) {}
}
