import SwiftUI
import AppKit
import MontageCore

/// Per-user asset-panel state shared by every tab (UX.md §3.1–3.2): favourites (☆ on cards → "Favorites" rail entry),
/// recently used items ("Recent"), and the panel's view preferences. Persisted in UserDefaults; ids are namespaced
/// per library (`"media"`, `"stock"`, `"music"`, `"sfx"`, `"effects"`, `"stickers"`, `"transitions"`…).
@MainActor @Observable
public final class AssetLibraryStore {
    public static let shared = AssetLibraryStore(defaults: AssetDefaults.session)
    static let favoritesKey = "montage.assets.favorites"
    static let recentsKey = "montage.assets.recents"
    public static let maxRecents = 30

    public private(set) var favorites: [String: [String]] = [:]
    public private(set) var recents: [String: [String]] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        favorites = (defaults.dictionary(forKey: Self.favoritesKey) as? [String: [String]]) ?? [:]
        recents = (defaults.dictionary(forKey: Self.recentsKey) as? [String: [String]]) ?? [:]
    }

    /// F3 (MI-024): namespaces of the Text tab's favourites (fonts, text effects, text templates).
    public static let fontsNamespace = "fonts", textEffectsNamespace = "textEffects", textTemplatesNamespace = "textTemplates"

    public func isFavorite(_ ns: String, _ id: String) -> Bool { favorites[ns]?.contains(id) ?? false }

    /// Favourites of a library, most recently starred first.
    public func favoriteIDs(_ ns: String) -> [String] { favorites[ns] ?? [] }

    public func toggleFavorite(_ ns: String, _ id: String) {
        var list = favorites[ns] ?? []
        if let i = list.firstIndex(of: id) { list.remove(at: i) } else { list.insert(id, at: 0) }
        favorites[ns] = list.isEmpty ? nil : list
        defaults.set(favorites, forKey: Self.favoritesKey)
    }

    /// Records a use (add to timeline / drop) — most recent first, deduplicated, capped.
    public func noteUsed(_ ns: String, _ id: String) {
        var list = recents[ns] ?? []
        list.removeAll { $0 == id }
        list.insert(id, at: 0)
        if list.count > Self.maxRecents { list.removeLast(list.count - Self.maxRecents) }
        recents[ns] = list
        defaults.set(recents, forKey: Self.recentsKey)
    }

    public func recentIDs(_ ns: String) -> [String] { recents[ns] ?? [] }

    public func clearRecents(_ ns: String) {
        recents[ns] = nil
        defaults.set(recents, forKey: Self.recentsKey)
    }
}

/// UserDefaults for asset-panel state: the user's defaults normally, a throwaway domain (emptied at launch) while
/// a UI test runs so scripts start from a clean, deterministic state and never touch the user's favourites.
@MainActor
enum AssetDefaults {
    static let uitestSuite = "com.montage.uitest.assets"
    static let session: UserDefaults = {
        guard TestAnchors.isEnabled, let d = UserDefaults(suiteName: uitestSuite) else { return .standard }
        d.removePersistentDomain(forName: uitestSuite)
        return d
    }()
}

/// Media tab view preferences (grid/list, sort, type filter), remembered per user.
@MainActor @Observable
public final class MediaBrowserPrefs {
    public static let shared = MediaBrowserPrefs(defaults: AssetDefaults.session)
    public enum Layout: String, CaseIterable, Sendable { case grid, list }
    public enum Sort: String, CaseIterable, Sendable { case imported, name, duration, size, type }
    public enum Filter: String, CaseIterable, Sendable { case all, video, image, audio }

    public var layout: Layout { didSet { save() } }
    public var sort: Sort { didSet { save() } }
    public var ascending: Bool { didSet { save() } }
    public var filter: Filter { didSet { save() } }
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        layout = Layout(rawValue: defaults.string(forKey: "montage.media.layout") ?? "") ?? .grid
        sort = Sort(rawValue: defaults.string(forKey: "montage.media.sort") ?? "") ?? .imported
        ascending = defaults.object(forKey: "montage.media.ascending") as? Bool ?? true
        filter = Filter(rawValue: defaults.string(forKey: "montage.media.filter") ?? "") ?? .all
    }

    private func save() {
        defaults.set(layout.rawValue, forKey: "montage.media.layout")
        defaults.set(sort.rawValue, forKey: "montage.media.sort")
        defaults.set(ascending, forKey: "montage.media.ascending")
        defaults.set(filter.rawValue, forKey: "montage.media.filter")
    }
}

/// Which rail entry / search each tab shows, kept across tab switches (and readable by the UI-test state dump).
@MainActor @Observable
public final class AssetPanelState {
    public static let shared = AssetPanelState()
    /// Tab id → selected rail entry.
    public var nav: [String: String] = [:]
    /// Tab id → committed (debounced) search query.
    public var query: [String: String] = [:]
    /// Tab id → number of items currently listed (state dump / tests).
    public var visibleCount: [String: Int] = [:]
    /// Keyboard focus: the tab whose grid owns the arrow keys (set by clicking a card, cleared by clicking elsewhere).
    public var keyboardTab: String?
    /// Tab id → highlighted item id (keyboard cursor; also the last clicked card).
    public var cursor: [String: String] = [:]
    /// Tab id → ordered ids of the listed items and the grid's column count (for ←/→/↑/↓).
    @ObservationIgnored var layout: [String: (ids: [String], columns: Int)] = [:]
    /// Tab id → actions for the keyboard cursor.
    @ObservationIgnored var actions: [String: (add: (String) -> Void, favorite: ((String) -> Void)?)] = [:]
    /// Media tab multi-selection (bin card ids).
    public var mediaSelection: [MediaID] = []

    func navBinding(_ tab: String, default d: String) -> Binding<String> {
        Binding(get: { self.nav[tab] ?? d }, set: { self.nav[tab] = $0 })
    }

    /// Arrow keys / Return / F while a tab's grid has keyboard focus. Returns true when handled.
    func handleKey(_ key: Shortcut.Key, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let tab = keyboardTab, modifiers.isDisjoint(with: [.command, .option, .control]),
              let l = layout[tab], !l.ids.isEmpty else { return false }
        let cur = cursor[tab].flatMap { l.ids.firstIndex(of: $0) }
        func move(_ d: Int) {
            let n = cur.map { min(max($0 + d, 0), l.ids.count - 1) } ?? 0
            cursor[tab] = l.ids[n]
        }
        switch key {
        case .left: move(-1)
        case .right: move(1)
        case .up: move(-max(1, l.columns))
        case .down: move(max(1, l.columns))
        case .char("\r"), .char("\u{3}"):
            guard let c = cur else { return false }
            actions[tab]?.add(l.ids[c])
        case .char("f"):
            guard let c = cur, let fav = actions[tab]?.favorite else { return false }
            fav(l.ids[c])
        case .escape:
            keyboardTab = nil
        default: return false
        }
        return true
    }
}
