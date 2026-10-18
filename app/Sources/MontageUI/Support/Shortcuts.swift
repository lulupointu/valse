import AppKit
import MontageCore

/// Keyboard shortcuts (CapCut bindings, UX.md §8.2). Menu-bound commands (⌘Z, ⇧⌘Z, ⌘S, ⌘O, ⌘I, ⌘E, ⌘N) live in the
/// app menu; everything else is dispatched here by an app-level key monitor (skipped while a text field has focus).
/// Add a shortcut: append one entry to `ShortcutRegistry.builtins` (it also appears in the shortcut list).
public struct Shortcut: Identifiable {
    public enum Key: Equatable { case char(Character), space, left, right, up, down, delete, home, end, escape }
    public let id: String
    public let titleKey: String
    public let key: Key
    public let modifiers: NSEvent.ModifierFlags
    public let action: @MainActor (EditorStore) -> Void
    /// When false the key falls through to the next shortcut with the same binding (or to the responder chain),
    /// e.g. arrows nudge on the canvas only while it has focus.
    public let isEnabled: @MainActor (EditorStore) -> Bool

    public init(_ id: String, _ titleKey: String, _ key: Key, _ modifiers: NSEvent.ModifierFlags = [],
                isEnabled: @escaping @MainActor (EditorStore) -> Bool = { _ in true },
                action: @escaping @MainActor (EditorStore) -> Void) {
        self.id = id; self.titleKey = titleKey; self.key = key; self.modifiers = modifiers; self.action = action
        self.isEnabled = isEnabled
    }

    /// Display string, e.g. "⌘B".
    public var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        switch key {
        case .char(let c): s += String(c).uppercased()
        case .space: s += "Space"
        case .left: s += "←"
        case .right: s += "→"
        case .up: s += "↑"
        case .down: s += "↓"
        case .delete: s += "⌫"
        case .home: s += "Home"
        case .end: s += "End"
        case .escape: s += "esc"
        }
        return s
    }
}

@MainActor
public enum ShortcutRegistry {
    public private(set) static var all: [Shortcut] = builtins
    public static func register(_ s: Shortcut) { all.removeAll { $0.id == s.id }; all.append(s); Keymap.shared.registryChanged() }

    static let builtins: [Shortcut] = [
        Shortcut("playPause", "shortcut.playPause", .space) { $0.togglePlay() },
        Shortcut("shuttleBack", "shortcut.shuttleBack", .char("j")) { $0.shuttle("j") },
        Shortcut("shuttleStop", "shortcut.shuttleStop", .char("k")) { $0.shuttle("k") },
        Shortcut("shuttleForward", "shortcut.shuttleForward", .char("l")) { $0.shuttle("l") },
        Shortcut("split", "shortcut.split", .char("b"), .command) { $0.split() },
        Shortcut("delete", "shortcut.delete", .delete) { $0.deleteSmart() },
        Shortcut("deleteLeft", "shortcut.deleteLeft", .char("q")) { $0.deleteLeftRight(.head) },
        Shortcut("deleteRight", "shortcut.deleteRight", .char("w")) { $0.deleteLeftRight(.tail) },
        // ←/→ step frames; on the focused canvas with a selection they nudge the layer (1 px, ⇧ 10 px) like ↑/↓.
        Shortcut("prevFrame", "shortcut.prevFrame", .left) { $0.arrow(dx: -1, dy: 0, big: false) },
        Shortcut("nextFrame", "shortcut.nextFrame", .right) { $0.arrow(dx: 1, dy: 0, big: false) },
        Shortcut("prevFrames", "shortcut.prevFrames", .left, .shift) { $0.arrow(dx: -1, dy: 0, big: true) },
        Shortcut("nextFrames", "shortcut.nextFrames", .right, .shift) { $0.arrow(dx: 1, dy: 0, big: true) },
        Shortcut("nudgeUp", "shortcut.nudgeUp", .up, isEnabled: { $0.canvasNudgeEnabled }) { $0.arrow(dx: 0, dy: -1, big: false) },
        Shortcut("nudgeDown", "shortcut.nudgeDown", .down, isEnabled: { $0.canvasNudgeEnabled }) { $0.arrow(dx: 0, dy: 1, big: false) },
        Shortcut("nudgeUpMany", "shortcut.nudgeUp", .up, .shift, isEnabled: { $0.canvasNudgeEnabled }) { $0.arrow(dx: 0, dy: -1, big: true) },
        Shortcut("nudgeDownMany", "shortcut.nudgeDown", .down, .shift, isEnabled: { $0.canvasNudgeEnabled }) { $0.arrow(dx: 0, dy: 1, big: true) },
        // Player (UX.md §8.2 "Player")
        Shortcut("playerFullscreen", "shortcut.playerFullscreen", .char("f"), [.shift, .command]) { $0.togglePlayerFullscreen() },
        Shortcut("exitPlayerFullscreen", "shortcut.exitFullscreen", .escape, isEnabled: { $0.playerUI.isFullscreen }) { $0.setPlayerFullscreen(false) },
        Shortcut("cancelEyedropper", "shortcut.cancelEyedropper", .escape, isEnabled: { $0.canvasEyedropper != nil }) { $0.endCanvasColorPick() },
        Shortcut("exitPreview", "shortcut.exitPreview", .escape, isEnabled: { $0.isPreviewing && !$0.playerUI.isFullscreen }) { $0.exitPreview() },
        Shortcut("playerZoomIn", "shortcut.playerZoomIn", .char("+"), [.option, .shift]) { $0.zoomPlayer(by: 1.25) },
        Shortcut("playerZoomInEq", "shortcut.playerZoomIn", .char("="), [.option, .shift]) { $0.zoomPlayer(by: 1.25) },
        Shortcut("playerZoomOut", "shortcut.playerZoomOut", .char("_"), [.option, .shift]) { $0.zoomPlayer(by: 0.8) },
        Shortcut("playerZoomOutMinus", "shortcut.playerZoomOut", .char("-"), [.option, .shift]) { $0.zoomPlayer(by: 0.8) },
        Shortcut("playerZoomFit", "shortcut.playerZoomFit", .char("z"), [.option, .shift]) { $0.resetPlayerZoom() },
        Shortcut("rulers", "shortcut.rulers", .char("r"), [.option, .command]) { $0.playerUI.showRulers.toggle() },
        Shortcut("guides", "shortcut.guides", .char(";"), .command) { $0.playerUI.showGuides.toggle() },
        Shortcut("home", "shortcut.home", .home) { $0.seek(to: .zero) },
        Shortcut("end", "shortcut.end", .end) { $0.seek(to: $0.project.duration) },
        Shortcut("zoomIn", "shortcut.zoomIn", .char("="), .command) { $0.zoomTimeline(by: 1.25) },
        Shortcut("zoomInPlus", "shortcut.zoomIn", .char("+"), .command) { $0.zoomTimeline(by: 1.25) },
        Shortcut("zoomOut", "shortcut.zoomOut", .char("-"), .command) { $0.zoomTimeline(by: 1 / 1.25) },
        Shortcut("zoomInBare", "shortcut.zoomIn", .char("=")) { $0.zoomTimeline(by: 1.25) },
        Shortcut("zoomInBarePlus", "shortcut.zoomIn", .char("+")) { $0.zoomTimeline(by: 1.25) },
        Shortcut("zoomOutBare", "shortcut.zoomOut", .char("-")) { $0.zoomTimeline(by: 1 / 1.25) },
        Shortcut("magnet", "shortcut.magnet", .char("p")) { $0.setOption(.magnet(!$0.project.timeline.mainTrackMagnet)) },
        Shortcut("snapping", "shortcut.snapping", .char("n")) { $0.setOption(.snapping(!$0.project.timeline.snapping)) },
        Shortcut("selectAll", "shortcut.selectAll", .char("a"), .command) { $0.selectAll() },
        Shortcut("deselect", "shortcut.deselect", .char("x"), .option) { $0.deselectAll() },
    ] + TimelineShortcuts.all + KeyframeShortcuts.all

    static func key(for e: NSEvent) -> Shortcut.Key? {
        switch e.keyCode {
        case 49: return .space
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        case 51, 117: return .delete
        case 115: return .home
        case 119: return .end
        case 53: return .escape
        default:
            guard let c = e.charactersIgnoringModifiers?.lowercased().first else { return nil }
            return .char(c)
        }
    }

    /// Returns true if the event was handled.
    public static func handle(_ e: NSEvent, store: EditorStore) -> Bool {
        if let responder = e.window?.firstResponder, responder is NSText || responder is NSTextView { return false }
        if Keymap.isRecording { return false }
        guard let k = key(for: e) else { return false }
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        if AssetPanelState.shared.handleKey(k, modifiers: mods) { return true }   // asset grid keyboard navigation (W13)
        // effective bindings come from the user keymap (Settings ▸ Shortcuts; defaults = the entries below)
        let b = KeyBinding(k, mods)
        guard let s = all.first(where: { Keymap.shared.matches($0, b) && $0.isEnabled(store) }) else { return false }
        s.action(store)
        return true
    }
}
