import AppKit
import MontageEngine

/// OB-11: keys that belong to the focused text field, not to editor shortcuts.
///
/// AppKit offers arrow / Home / End keys (function keys) to the menu bar's key equivalents before the first responder
/// sees them, even without ⌘, so View ▸ Previous frame (←) stepped the playhead while the caret should have moved —
/// and a menu item disabled behind a modal swallowed the key. While a text field or text view is editing, these keys
/// are delivered straight to its window instead (the app key monitor calls `route` first).
@MainActor
public enum TextFieldKeys {
    /// ← → ↓ ↑, Home, End, Page Up, Page Down.
    static let caretKeyCodes: Set<UInt16> = [123, 124, 125, 126, 115, 119, 116, 121]

    /// Whether `e` is a caret-movement key for the focused text of its window (no ⌘ / ⌃: those stay menu shortcuts).
    /// `window` = the event's window (a parameter for unit tests: synthetic events of an unordered window have none).
    public static func isTextEditingKey(_ e: NSEvent, window: NSWindow?) -> Bool {
        guard e.type == .keyDown || e.type == .keyUp, caretKeyCodes.contains(e.keyCode),
              e.modifierFlags.intersection([.command, .control]).isEmpty else { return false }
        return window?.firstResponder is NSText
    }

    /// Delivers a caret key to the focused text (bypassing menu key equivalents). Returns true when it did.
    @discardableResult
    public static func route(_ e: NSEvent, window: NSWindow? = nil) -> Bool {
        guard let w = window ?? e.window, isTextEditingKey(e, window: w) else { return false }
        if NumericFieldKeys.handle(e, window: w) { return true }
        w.sendEvent(e)
        return true
    }
}

/// OB-11: ↑ / ↓ in a focused numeric field step its value (⇧ = 10 steps), one undoable edit per press, clamped by the
/// field's own `step` closure. The focused field registers its step closure; a local key monitor (re-installed on each
/// focus so it runs before older monitors, the UI test driver's key routing included) handles the keys.
@MainActor
public enum NumericFieldKeys {
    private static var active: (token: UUID, step: (Int) -> Void)?
    private static var monitor: Any?

    /// A numeric field is focused and takes ↑ / ↓ (UI test state `ui.numericFieldKeys`).
    public static var isActive: Bool { active != nil }

    /// Steps per press: ±1, ⇧ ±10.
    nonisolated static func steps(keyCode: UInt16, shift: Bool) -> Int? {
        let k = shift ? 10 : 1
        switch keyCode {
        case 126: return k
        case 125: return -k
        default: return nil
        }
    }

    static func focus(_ token: UUID, step: @escaping (Int) -> Void) {
        active = (token, step)
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let box = UncheckedSendable(e)
            let handled = MainActor.assumeIsolated { NumericFieldKeys.handle(box.value) }
            return handled ? nil : e
        }
    }

    /// The field re-rendered with a new value: its step closure captures it.
    static func update(_ token: UUID, step: @escaping (Int) -> Void) {
        if active?.token == token { active = (token, step) }
    }

    static func blur(_ token: UUID) {
        guard active?.token == token else { return }
        active = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    /// Handles ↑ / ↓ (keyDown) for the registered field while its text is being edited.
    static func handle(_ e: NSEvent, window: NSWindow? = nil) -> Bool {
        guard e.type == .keyDown, let a = active, (window ?? e.window)?.firstResponder is NSText else { return false }
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        guard mods.subtracting(.shift).isEmpty, let n = steps(keyCode: e.keyCode, shift: mods.contains(.shift)) else { return false }
        a.step(n)
        return true
    }
}
