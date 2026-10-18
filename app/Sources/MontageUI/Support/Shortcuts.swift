import AppKit
import MontageCore

/// Keyboard shortcuts (CapCut bindings, UX.md §8.2). Menu-bound commands (⌘Z, ⇧⌘Z, ⌘S, ⌘O, ⌘I, ⌘E, ⌘N) live in the
/// app menu; everything else is dispatched here by an app-level key monitor (skipped while a text field has focus).
/// Add a shortcut: append one entry to `ShortcutRegistry.builtins` (it also appears in the shortcut list).
public struct Shortcut: Identifiable {
    public enum Key: Equatable { case char(Character), space, left, right, up, down, delete, home, end }
    public let id: String
    public let titleKey: String
    public let key: Key
    public let modifiers: NSEvent.ModifierFlags
    public let action: @MainActor (EditorStore) -> Void

    public init(_ id: String, _ titleKey: String, _ key: Key, _ modifiers: NSEvent.ModifierFlags = [], action: @escaping @MainActor (EditorStore) -> Void) {
        self.id = id; self.titleKey = titleKey; self.key = key; self.modifiers = modifiers; self.action = action
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
        }
        return s
    }
}

@MainActor
public enum ShortcutRegistry {
    public private(set) static var all: [Shortcut] = builtins
    public static func register(_ s: Shortcut) { all.removeAll { $0.id == s.id }; all.append(s) }

    static let builtins: [Shortcut] = [
        Shortcut("playPause", "shortcut.playPause", .space) { $0.togglePlay() },
        Shortcut("shuttleBack", "shortcut.shuttleBack", .char("j")) { $0.shuttle("j") },
        Shortcut("shuttleStop", "shortcut.shuttleStop", .char("k")) { $0.shuttle("k") },
        Shortcut("shuttleForward", "shortcut.shuttleForward", .char("l")) { $0.shuttle("l") },
        Shortcut("split", "shortcut.split", .char("b"), .command) { $0.split() },
        Shortcut("delete", "shortcut.delete", .delete) { $0.deleteSmart() },
        Shortcut("deleteLeft", "shortcut.deleteLeft", .char("q")) { $0.deleteLeftRight(.head) },
        Shortcut("deleteRight", "shortcut.deleteRight", .char("w")) { $0.deleteLeftRight(.tail) },
        Shortcut("prevFrame", "shortcut.prevFrame", .left) { $0.step(frames: -1) },
        Shortcut("nextFrame", "shortcut.nextFrame", .right) { $0.step(frames: 1) },
        Shortcut("prevFrames", "shortcut.prevFrames", .left, .shift) { $0.step(frames: -10) },
        Shortcut("nextFrames", "shortcut.nextFrames", .right, .shift) { $0.step(frames: 10) },
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
    ] + TimelineShortcuts.all

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
        default:
            guard let c = e.charactersIgnoringModifiers?.lowercased().first else { return nil }
            return .char(c)
        }
    }

    /// Returns true if the event was handled.
    public static func handle(_ e: NSEvent, store: EditorStore) -> Bool {
        if let responder = e.window?.firstResponder, responder is NSText || responder is NSTextView { return false }
        guard let k = key(for: e) else { return false }
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        guard let s = all.first(where: { $0.key == k && $0.modifiers == mods }) else { return false }
        s.action(store)
        return true
    }
}
