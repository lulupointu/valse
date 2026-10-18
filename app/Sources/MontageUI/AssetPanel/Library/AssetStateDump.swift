import Foundation
import MontageCore

/// `ui.assets` in the UI-test state dump (docs/TESTING.md): `{tab, nav: {tab: entry}, query: {tab: q},
/// count: {tab: n listed}, keyboardTab, cursor: {tab: id}, mediaSelection: [media ids], favorites: {ns: [ids]},
/// recents: {ns: [ids]}, rendering: [ids], playing, media: {layout, sort, ascending, filter}}`.
@MainActor
enum AssetStateDump {
    static func make(_ store: EditorStore) -> [String: Any] {
        let s = AssetPanelState.shared
        let lib = AssetLibraryStore.shared
        let p = MediaBrowserPrefs.shared
        return [
            "tab": store.activeAssetTab,
            "nav": s.nav,
            "query": s.query,
            "count": s.visibleCount,
            "keyboardTab": s.keyboardTab ?? NSNull(),
            "cursor": s.cursor,
            "mediaSelection": s.mediaSelection.map(\.description),
            "favorites": lib.favorites,
            "recents": lib.recents,
            "rendering": Array(AudioLibraryRendering.shared.busy).sorted() + AssetRenderingRegistry.extraBusy(),
            "playing": LibraryAudioPreview.shared.playingID ?? NSNull(),
            "media": ["layout": p.layout.rawValue, "sort": p.sort.rawValue, "ascending": p.ascending, "filter": p.filter.rawValue] as [String: Any],
        ]
    }
}

/// Other libraries (stock) report their in-flight renders here for the state dump.
@MainActor
enum AssetRenderingRegistry {
    static var providers: [() -> [String]] = [{ Array(StockLibraryState.shared.rendering) }]
    static func extraBusy() -> [String] { providers.flatMap { $0() }.sorted() }
}
