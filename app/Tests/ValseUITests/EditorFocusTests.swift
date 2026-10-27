import Testing
import Foundation
import AppKit
import SwiftUI
import ValseCore
@testable import ValseUI
import ValseTestSupport

/// BUG-SPACE-FOCUS: an opened project never starts with the keyboard in a text field (the media search field took it,
/// so Space typed a space instead of playing).
@MainActor @Suite(.serialized) struct EditorFocusTests {
    final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    /// Runs the main run loop until `done` holds (bounded: a hang guard, not a timing assumption).
    @discardableResult
    func spin(until done: () -> Bool = { false }, limit: Double = 5) -> Bool {
        let deadline = Date().addingTimeInterval(limit)
        while Date() < deadline {
            if done() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return done()
    }

    /// Offscreen window (never activated) hosting the app's root view, like the app's own window.
    func window(_ app: AppModel) -> NSWindow {
        let w = KeyableWindow(contentRect: CGRect(x: -20000, y: -20000, width: 1400, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: RootView(app: app))
        w.contentView?.layoutSubtreeIfNeeded()
        return w
    }

    func close(_ w: NSWindow) { w.orderOut(nil); w.contentView = nil }

    func firstTextField(in v: NSView) -> NSTextField? {
        PanelFocus.firstView(in: v) { ($0 as? NSTextField)?.isEditable == true } as? NSTextField
    }

    @Test func editorShownWhenTheWindowFirstAppearsKeepsTheKeyboard() throws {
        // `--open` / new project window: the editor is on screen when the window is first ordered in. AppKit used to
        // make the first key view (the media search field) first responder.
        let app = AppModel(store: EditorStore())
        app.screen = .editor
        let w = window(app)
        defer { close(w) }
        let content = try #require(w.contentView)
        #expect(firstTextField(in: content) != nil, "the editor has a search field to steal focus")
        w.orderBack(nil)
        spin { w.firstResponder is EditorKeyAnchorView }
        #expect(w.firstResponder is EditorKeyAnchorView)
        #expect(!(w.firstResponder is NSText))
        #expect(w.initialFirstResponder is EditorKeyAnchorView)
    }

    @Test func openingAProjectFromHomeLeavesNoTextFieldFocused() throws {
        let app = AppModel(store: EditorStore())
        app.screen = .home
        let w = window(app)
        defer { close(w) }
        w.orderBack(nil)
        spin(limit: 0.3)
        app.showEditor()   // what Home / the switcher / recent projects call once the project is loaded
        spin { w.firstResponder is EditorKeyAnchorView }
        #expect(w.firstResponder is EditorKeyAnchorView)
    }

    @Test func aFocusedTextFieldLosesTheKeyboardWhenAProjectOpensButKeepsItOtherwise() throws {
        let app = AppModel(store: EditorStore())
        app.screen = .editor
        let w = window(app)
        defer { close(w) }
        w.orderBack(nil)
        spin { w.firstResponder is EditorKeyAnchorView }
        spin(limit: 0.3)   // the editor's deferred appearance claim has run
        // the user clicks into the search field: it keeps the keyboard (becoming key again does not take it away)
        let content = try #require(w.contentView)
        let field = try #require(firstTextField(in: content))
        #expect(w.makeFirstResponder(field))
        #expect(w.firstResponder is NSText)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: w)
        spin(limit: 0.2)
        #expect(w.firstResponder is NSText)
        // another project opens in this editor: Space must play, the field gives the keyboard back
        EditorKeyFocus.projectOpened()
        spin { w.firstResponder is EditorKeyAnchorView }
        #expect(w.firstResponder is EditorKeyAnchorView)
        // the window left without a responder (a click on the timeline ends editing) gets it back when it becomes key
        w.makeFirstResponder(nil)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: w)
        spin { w.firstResponder is EditorKeyAnchorView }
        #expect(w.firstResponder is EditorKeyAnchorView)
    }

    @Test func claimRules() {
        let w = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        #expect(EditorKeyFocus.shouldClaim(nil, in: w, includingText: false))
        #expect(EditorKeyFocus.shouldClaim(w, in: w, includingText: false))
        #expect(!EditorKeyFocus.shouldClaim(NSTextView(), in: w, includingText: false))
        #expect(EditorKeyFocus.shouldClaim(NSTextView(), in: w, includingText: true))
        #expect(!EditorKeyFocus.shouldClaim(NSView(), in: w, includingText: true))   // a view the user focused (player, timeline)
    }

    @Test func theAnchorNeverTakesClicksNorKeys() {
        let a = EditorKeyAnchorView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(a.hitTest(CGPoint(x: 10, y: 10)) == nil)
        #expect(a.acceptsFirstResponder)
        #expect(!a.isAccessibilityElement())
    }
}
