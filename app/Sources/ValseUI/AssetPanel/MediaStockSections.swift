import SwiftUI
import ValseCore
import ValseEngine

/// Media ▸ Library ▾ sections (MI-023 local substitute, MI-026): colours, gradients, animated backgrounds,
/// countdowns, green-screen elements — all generated locally (`StockLibrary`).
extension MediaLibraryItems {
    static func stockSections(_ store: EditorStore) -> [LibrarySection] {
        let used = store.usedMediaIDs
        let usedURLs = Set(store.mediaBin.media.filter { used.contains($0.id) }.map(\.url.standardizedFileURL))
        let rendering = StockLibraryState.shared.rendering
        return StockLibrary.categories.map { cat in
            LibrarySection(id: "stock.\(cat)", title: tr("library.cat.\(cat)"),
                           items: StockLibrary.items(in: cat).map { stockItem($0, store: store, usedURLs: usedURLs, rendering: rendering) },
                           group: tr("media.nav.library"))
        }
    }

    static func stockItem(_ i: StockItem, store: EditorStore, usedURLs: Set<URL>, rendering: Set<String>) -> LibraryItem {
        let art: LibraryArt
        if case .solid(let c) = i.kind { art = .color(c) }
        else { art = .async(key: "stock.\(i.id)", load: { await StockLibrary.thumbnail(i, height: 144) }, placeholder: "sparkles.rectangle.stack") }
        return LibraryItem(id: "stock.\(i.id)", title: tr(i.nameKey), keywords: i.tags + [tr("library.cat.\(i.category)")],
                           badge: i.isVideo ? Timecode.shortDuration(Time(i.duration)) : nil, art: art,
                           hoverFrames: i.isVideo ? { await StockLibrary.previewFrames(i, count: 12, height: 144) } : nil,
                           payload: DragPayload.stock(i.id),
                           added: usedURLs.contains(StockLibrary.fileURL(i).standardizedFileURL),
                           busy: rendering.contains(i.id),
                           add: { [weak store] in store?.addStockItem(i) },
                           click: { [weak store] in store?.previewStock(i) })
    }

    /// Timeline drop of a Library card.
    static let stockDropHandler: LibraryDropHandlers.Handler = { s, store, time, target in
        guard let id = DragPayload.parseStock(s), let i = StockLibrary[id] else { return false }
        store.addStockItem(i, at: time, target: target)
        AssetLibraryStore.shared.noteUsed("media", "stock.\(id)")
        return true
    }

    static let stockDropDuration: LibraryDropHandlers.Duration = { s, _ in
        guard let id = DragPayload.parseStock(s), let i = StockLibrary[id] else { return nil }
        return Time(i.isVideo ? i.duration : 3)
    }
}
