import AppKit
import Observation
import MontageCore

/// A key + modifiers, as stored in the keymap (`keymap.json`) and compared with key events.
nonisolated public struct KeyBinding: Codable, Hashable, Sendable {
    /// "a"…"z", digits, punctuation, or a named key: space, left, right, up, down, delete, home, end, escape.
    public var key: String
    /// Raw value of the NSEvent.ModifierFlags subset ⌃⌥⇧⌘.
    public var modifiers: UInt

    public static let relevantModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    public init(key: String, modifiers: NSEvent.ModifierFlags = []) {
        self.key = key.lowercased()
        self.modifiers = modifiers.intersection(Self.relevantModifiers).rawValue
    }

    public init(_ k: Shortcut.Key, _ modifiers: NSEvent.ModifierFlags = []) {
        let name: String
        switch k {
        case .char(let c): name = String(c)
        case .space: name = "space"
        case .left: name = "left"
        case .right: name = "right"
        case .up: name = "up"
        case .down: name = "down"
        case .delete: name = "delete"
        case .home: name = "home"
        case .end: name = "end"
        case .escape: name = "escape"
        }
        self.init(key: name, modifiers: modifiers)
    }

    public var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    public var shortcutKey: Shortcut.Key {
        switch key {
        case "space": return .space
        case "left": return .left
        case "right": return .right
        case "up": return .up
        case "down": return .down
        case "delete": return .delete
        case "home": return .home
        case "end": return .end
        case "escape": return .escape
        default: return .char(key.first ?? " ")
        }
    }

    /// Binding of a key event (nil for modifier-only events).
    @MainActor public init?(event e: NSEvent) {
        guard let k = ShortcutRegistry.key(for: e) else { return nil }
        self.init(k, e.modifierFlags)
    }

    /// Key-cap glyphs, e.g. "⇧⌘B", "Space", "⌫".
    public var display: String {
        let m = modifierFlags
        var s = ""
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        switch key {
        case "space": s += "Space"
        case "left": s += "←"
        case "right": s += "→"
        case "up": s += "↑"
        case "down": s += "↓"
        case "delete": s += "⌫"
        case "home": s += "Home"
        case "end": s += "End"
        case "escape": s += "esc"
        default: s += key.uppercased()
        }
        return s
    }

    /// `NSMenuItem.keyEquivalent` for this key.
    public var menuKeyEquivalent: String {
        func f(_ code: Int) -> String { String(UnicodeScalar(UInt32(code)).map(Character.init) ?? " ") }
        switch key {
        case "space": return " "
        case "left": return f(NSLeftArrowFunctionKey)
        case "right": return f(NSRightArrowFunctionKey)
        case "up": return f(NSUpArrowFunctionKey)
        case "down": return f(NSDownArrowFunctionKey)
        case "delete": return "\u{8}"
        case "home": return f(NSHomeFunctionKey)
        case "end": return f(NSEndFunctionKey)
        case "escape": return "\u{1b}"
        default: return key
        }
    }
}

nonisolated public enum ShortcutCategory: String, CaseIterable, Sendable {
    case timeline, player, basic, other
    public var nameKey: String { "keymap.category.\(rawValue)" }
}

/// One rebindable command: a `ShortcutRegistry` shortcut (handled by the key monitor) or an app menu command
/// (handled by the menu bar, `isMenuCommand`).
nonisolated public struct KeymapEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let titleKey: String
    public let category: ShortcutCategory
    public let defaultBinding: KeyBinding?
    public let isMenuCommand: Bool
}

/// Shortcut layouts (SE-003): CapCut (the registry defaults), Final Cut Pro and Premiere Pro, plus the user's edits.
nonisolated public enum KeymapPreset: String, Codable, CaseIterable, Sendable {
    case capcut, finalCut, premiere
    public var nameKey: String { "keymap.preset.\(rawValue)" }

    /// Bindings that differ from CapCut (nil = unbound in that layout).
    var changes: [String: KeyBinding?] {
        func b(_ k: String, _ m: NSEvent.ModifierFlags = []) -> KeyBinding { KeyBinding(key: k, modifiers: m) }
        switch self {
        case .capcut: return [:]
        case .finalCut:
            return [
                "split": b("b", .command), "splitAll": b("b", [.command, .shift]),
                "deleteLeft": b("[", .option), "deleteRight": b("]", .option),
                "selectLeft": nil, "selectRight": nil,
                "zoomFit": b("z", .shift), "magnet": b("p"),
                "toggleClip": b("v"), "group": b("g", .option), "ungroup": b("g", [.option, .shift]),
                "previewAxis": b("s"), "snapping": b("n"), "speedPanel": b("r", .command),
                "extractAudio": b("s", [.control, .shift]), "duplicate": b("d", .command),
                "playerFullscreen": b("f", [.shift, .command]), "markerColor": b("m", .option),
                "nextMarker": b("'", .control), "prevMarker": b(";", .control),
            ]
        case .premiere:
            return [
                "split": b("k", .command), "splitAll": b("k", [.command, .shift]),
                "splitMode": b("c"), "selectMode": b("v"), "toggleClip": b("e", [.shift]),
                "zoomFit": b("\\"), "magnet": nil, "snapping": b("s"), "previewAxis": nil,
                "selectLeft": nil, "selectRight": nil,
                "nextCut": b("down"), "prevCut": b("up"),
                "group": b("g", .command), "ungroup": b("g", [.command, .shift]),
                "speedPanel": b("r", .command), "nextMarker": b("m", [.shift]), "prevMarker": b("m", [.command, .shift]),
                "playerFullscreen": b("`", .control), "linkage": b("l", .command), "linkageBacktick": nil,
                "duplicate": nil, "extractAudio": nil,
            ]
        }
    }
}

/// The user keymap: preset + per-command overrides, persisted in `~/Library/Application Support/Montage/keymap.json`.
/// `ShortcutRegistry.handle` and the menu bar read `binding(for:)`, so a rebind takes effect immediately.
@MainActor @Observable
public final class Keymap {
    public static let shared = Keymap(url: MontagePaths.supportDirectory.appendingPathComponent("keymap.json"))

    struct Stored: Codable, Equatable {
        var preset: KeymapPreset = .capcut
        var bindings: [String: KeyBinding] = [:]
        var unbound: Set<String> = []
    }

    public private(set) var preset: KeymapPreset = .capcut
    /// User edits on top of the preset (nil value = explicitly unbound).
    public private(set) var overrides: [String: KeyBinding?] = [:]
    /// Bumped on every change (menu bar rebuild).
    public private(set) var revision = 0
    @ObservationIgnored let url: URL?
    @ObservationIgnored private var effectiveCache: [String: KeyBinding?] = [:]

    public init(url: URL?) {
        self.url = url
        if let url, let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Stored.self, from: d) {
            preset = s.preset
            overrides = s.bindings.mapValues { Optional($0) }
            for u in s.unbound { overrides[u] = .some(nil) }
        }
        rebuildCache()
    }

    public static let didChange = Notification.Name("MontageKeymapDidChange")
    /// The shortcut editor is recording a key: shortcuts don't fire.
    public static var isRecording = false

    // MARK: Entries

    /// App menu commands (handled by the menu bar). Titles are the menu item titles.
    public static let menuCommands: [KeymapEntry] = {
        func m(_ id: String, _ key: String?, _ mods: NSEvent.ModifierFlags = .command, _ cat: ShortcutCategory = .basic) -> KeymapEntry {
            KeymapEntry(id: id, titleKey: id, category: cat, defaultBinding: key.map { KeyBinding(key: $0, modifiers: mods) }, isMenuCommand: true)
        }
        return [
            m("menu.new", "n"), m("menu.open", "o"), m("menu.import", "i"), m("menu.export", "e"),
            m("menu.save", "s"), m("menu.undo", "z"), m("menu.redo", "z", [.command, .shift]),
            m("menu.settings", ","), m("menu.home", nil), m("menu.importProject", nil), m("menu.packProject", nil),
            m("menu.projectSettings", nil), m("menu.versions", nil), m("menu.relink", nil),
            m("menu.shortcuts", "k", [.command, .option]), m("menu.quit", "q"), m("menu.hide", "h"),
            m("menu.minimize", "m", .command, .other), m("menu.fullscreen", "f", [.command, .control], .other),
            m("menu.exportFrame", nil, .command, .other),
            m("menu.freeze", nil, .command, .timeline), m("menu.reverse", nil, .command, .timeline),
            m("menu.mirror", nil, .command, .timeline), m("menu.rotate", nil, .command, .timeline),
            m("menu.renderPreview", nil, .command, .timeline),
        ]
    }()

    /// Context-dependent bindings that deliberately share a key with another command and fall through when disabled
    /// (arrows nudge only while the canvas has focus, esc exits full screen only in full screen). Not rebindable.
    static let contextualIDs: Set<String> = ["nudgeUp", "nudgeDown", "nudgeUpMany", "nudgeDownMany", "exitPlayerFullscreen",
                                              "cancelEyedropper", "exitPreview"]

    static let playerIDs: Set<String> = ["playPause", "playerFullscreen", "exitPlayerFullscreen", "playerZoomIn", "playerZoomOut",
                                         "playerZoomFit", "rulers", "guides", "shuttleBack", "shuttleStop", "shuttleForward",
                                         "nudgeUp", "nudgeDown", "nudgeUpMany", "nudgeDownMany"]
    static let basicIDs: Set<String> = ["copy", "cut", "paste", "copyAttributes", "pasteAttributes", "delete", "duplicate",
                                        "selectAll", "deselect"]

    public static func category(of s: Shortcut) -> ShortcutCategory {
        if playerIDs.contains(s.id) { return .player }
        if basicIDs.contains(s.id) { return .basic }
        return .timeline
    }

    /// Shortcuts that repeat another entry's title (e.g. ⌘= and ⌘+ for Zoom in): bound by default, hidden from the
    /// editor, and disabled once the user rebinds the primary entry.
    static func aliasPrimaries() -> [String: String] {
        var firstByTitle: [String: String] = [:]
        var out: [String: String] = [:]
        for s in ShortcutRegistry.all {
            if let p = firstByTitle[s.titleKey] { out[s.id] = p } else { firstByTitle[s.titleKey] = s.id }
        }
        return out
    }

    /// Every editable entry (aliases folded into their primary).
    public var entries: [KeymapEntry] {
        let aliases = Self.aliasPrimaries()
        let reg = ShortcutRegistry.all.filter { aliases[$0.id] == nil && !Self.contextualIDs.contains($0.id) }.map {
            KeymapEntry(id: $0.id, titleKey: $0.titleKey, category: Self.category(of: $0),
                        defaultBinding: KeyBinding($0.key, $0.modifiers), isMenuCommand: false)
        }
        return reg + Self.menuCommands
    }

    public func entries(in c: ShortcutCategory) -> [KeymapEntry] { entries.filter { $0.category == c } }

    // MARK: Bindings

    /// Binding in the current preset, before user edits.
    public func presetBinding(_ id: String) -> KeyBinding? {
        if let change = preset.changes[id] { return change }
        if let s = ShortcutRegistry.all.first(where: { $0.id == id }) { return KeyBinding(s.key, s.modifiers) }
        return Self.menuCommands.first { $0.id == id }?.defaultBinding
    }

    /// Effective binding (user edit ▸ preset ▸ default); nil = unbound.
    public func binding(for id: String) -> KeyBinding? {
        if let cached = effectiveCache[id] { return cached }
        return computeBinding(id)
    }

    private func computeBinding(_ id: String) -> KeyBinding? {
        if Self.contextualIDs.contains(id), let s = ShortcutRegistry.all.first(where: { $0.id == id }) { return KeyBinding(s.key, s.modifiers) }
        if let o = overrides[id] { return o }
        if let primary = Self.aliasPrimaries()[id] {
            // an alias follows its primary: unchanged primary → alias keeps its own default; edited → alias off
            if overrides[primary] != nil || preset.changes[primary] != nil { return nil }
        }
        return presetBinding(id)
    }

    private func rebuildCache() {
        var c: [String: KeyBinding?] = [:]
        for s in ShortcutRegistry.all { c[s.id] = .some(computeBinding(s.id)) }
        for m in Self.menuCommands { c[m.id] = .some(computeBinding(m.id)) }
        effectiveCache = c
    }

    /// True if `s` should fire for this key + modifiers.
    public func matches(_ s: Shortcut, _ b: KeyBinding) -> Bool { binding(for: s.id) == b }

    /// Entries (excluding `id` and its aliases) already using `b`.
    public func conflicts(for b: KeyBinding, excluding id: String) -> [KeymapEntry] {
        let aliases = Self.aliasPrimaries()
        return entries.filter { e in
            guard e.id != id else { return false }
            if binding(for: e.id) == b { return true }
            // an alias of e holding the binding counts as e
            return aliases.contains { $0.value == e.id && $0.key != id && binding(for: $0.key) == b }
        }
    }

    public var isModified: Bool { !overrides.isEmpty }

    /// A shortcut was registered at runtime.
    func registryChanged() { rebuildCache() }

    // MARK: Editing (the shortcut editor stages edits on a copy, then `adopt`s it on Save)

    public func set(_ id: String, _ b: KeyBinding?) {
        if b == presetBinding(id) && Self.aliasPrimaries()[id] == nil { overrides[id] = nil } else { overrides[id] = .some(b) }
        changed()
    }

    /// Binds `b` to `id`, unbinding every conflicting entry ("Override").
    public func assign(_ b: KeyBinding, to id: String) {
        for c in conflicts(for: b, excluding: id) { overrides[c.id] = .some(nil) }
        set(id, b)
    }

    public func reset(_ id: String) { overrides[id] = nil; changed() }

    public func resetAll() { overrides = [:]; changed() }

    public func selectPreset(_ p: KeymapPreset) { preset = p; overrides = [:]; changed() }

    /// Copy for staged editing.
    public func copy() -> Keymap {
        let k = Keymap(url: nil)
        k.preset = preset; k.overrides = overrides
        k.rebuildCache()
        return k
    }

    /// Takes over a staged copy's state and saves.
    public func adopt(_ other: Keymap) {
        preset = other.preset; overrides = other.overrides
        changed()
    }

    private func changed() {
        rebuildCache()
        revision += 1
        if url != nil {
            save()
            NotificationCenter.default.post(name: Keymap.didChange, object: nil)
        }
    }

    func save() {
        guard let url else { return }
        var s = Stored(preset: preset)
        for (k, v) in overrides { if let v { s.bindings[k] = v } else { s.unbound.insert(k) } }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .prettyPrinted]
        try? e.encode(s).write(to: url, options: .atomic)
    }
}
