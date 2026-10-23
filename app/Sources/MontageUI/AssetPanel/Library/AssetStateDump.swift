import Foundation
import MontageCore
import MontageEngine

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
            // bundled CC0 music/SFX library (MUS): similar-sounds panel, open license card
            "similar": AudioSimilarState.shared.dump,
            "licenseCard": LicenseCardState.shared.shownID ?? "",
            "online": OnlineAudioState.shared.dump,
            "library": ["music": ContentLibrary.availableMusic.count, "sfx": ContentLibrary.availableSFX.count] as [String: Any],
            // library / source preview (W2 `PlayerPreview`): time is relative to the previewed item
            "preview": ["active": store.isPreviewing, "kind": store.playerUI.preview?.kind.rawValue ?? "",
                        "item": store.playerUI.preview?.itemID ?? "",
                        "time": store.playerUI.preview.map { (store.playerUI.previewTime - $0.range.start).seconds } ?? 0,
                        "duration": store.playerUI.preview?.range.duration.seconds ?? 0] as [String: Any],
            // on-screen Media ▸ Library cards whose async picture has not landed yet (snapshots waitFor 0)
            "stockThumbsMissing": stockThumbsMissing(),
            "media": ["layout": p.layout.rawValue, "columns": s.layout["media"].map { $0.1 } ?? 0, "sort": p.sort.rawValue, "ascending": p.ascending, "filter": p.filter.rawValue] as [String: Any],
        ]
    }

    /// Stock cards on screen (`asset.tile.stock.<id>`) drawn with `LibraryArt.async` whose image isn't cached yet.
    static func stockThumbsMissing() -> Int {
        TestAnchors.shared.ids.filter { a in
            guard a.hasPrefix("asset.tile.stock."), let i = StockLibrary[String(a.dropFirst("asset.tile.stock.".count))] else { return false }
            if case .solid = i.kind { return false }
            return LibraryArtCache.shared.get("stock.\(i.id)") == nil
        }.count
    }
}

/// Other libraries (stock) report their in-flight renders here for the state dump.
@MainActor
enum AssetRenderingRegistry {
    static var providers: [() -> [String]] = [{ Array(StockLibraryState.shared.rendering) }]
    static func extraBusy() -> [String] { providers.flatMap { $0() }.sorted() }
}
