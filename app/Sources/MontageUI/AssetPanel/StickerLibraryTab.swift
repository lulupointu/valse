import SwiftUI
import CoreGraphics
import MontageCore
import MontageEffects
import MontageEngine

// Stickers tab (ST-001/002/008, UX.md §3.6): Favorites + categories (emoji groups, callouts, arrows, decorations,
// shapes), search, 86 pt cards that wiggle on hover, ☆ / ⊕, double-click or drag to add (3 s sticker clip).

/// Sticker catalogue: groups in display order, search (names + tags), favourites — unit-tested.
enum StickerCatalog {
    static let groupOrder = ["emoji", "gestures", "love", "celebration", "animals", "food", "nature", "objects", "symbols",
                             "callouts", "arrows", "decor", "shapes"].map { "sticker.group.\($0)" }

    static func groups() -> [String] {
        var seen: [String] = []
        for s in Registries.stickers.all where !seen.contains(s.groupKey) { seen.append(s.groupKey) }
        return groupOrder.filter(seen.contains) + seen.filter { !groupOrder.contains($0) }
    }

    static func nav() -> [(id: String, titleKey: String)] {
        [(EffectLibraryCatalog.favoritesNav, "fxlib.favorites")] + groups().map { ($0, $0) }
    }

    static func entries(nav: String, favorites: Set<String>) -> [StickerDescriptor] {
        let all = Registries.stickers.all
        return nav == EffectLibraryCatalog.favoritesNav ? all.filter { favorites.contains($0.id) } : all.filter { $0.groupKey == nav }
    }

    static func search(_ query: String) -> [StickerDescriptor] {
        let q = EffectLibraryCatalog.fold(query)
        guard !q.isEmpty else { return Registries.stickers.all }
        return Registries.stickers.all.filter { s in
            let hay = [tr(s.nameKey), tr(s.groupKey)] + s.tags
            return q.split(separator: " ").allSatisfy { term in hay.contains { EffectLibraryCatalog.fold($0).contains(term) } }
        }
    }
}

/// Vector sticker card images (Core Graphics, cheap; cached).
@MainActor
enum StickerThumbnails {
    static var cache: [String: CGImage] = [:]
    static func image(_ s: StickerDescriptor) -> CGImage? {
        guard case .vector(let layers) = s.source else { return nil }
        if let i = cache[s.id] { return i }
        let img = VectorStickerRenderer.image(layers, px: 144)
        cache[s.id] = img
        return img
    }
}

struct StickerLibraryTab: View {
    let store: EditorStore
    @State private var nav = ""
    @State private var query = ""
    private var favorites: EffectFavorites { EffectFavorites.shared }

    var body: some View {
        let navItems = StickerCatalog.nav()
        let current = nav.isEmpty ? (navItems.dropFirst().first?.id ?? navItems[0].id) : nav
        let searching = !EffectLibraryCatalog.fold(query).isEmpty
        let items = searching ? StickerCatalog.search(query) : StickerCatalog.entries(nav: current, favorites: favorites.ids)
        HStack(spacing: 0) {
            SubNav(items: navItems.map { ($0.id, tr($0.titleKey)) }, selection: Binding(get: { current }, set: { nav = $0; query = "" }))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    TextField(tr("fxlib.search.stickers"), text: $query).textFieldStyle(.plain).font(.system(size: 12))
                }
                .padding(.horizontal, 10).frame(height: 28)
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.08)))
                .padding(.horizontal, 12)
                Text(verbatim: searching ? tr("fxlib.results") : tr(navItems.first { $0.id == current }?.titleKey ?? current))
                    .font(.system(size: 13)).foregroundStyle(Theme.textPrimary).padding(.horizontal, 12)
                if items.isEmpty {
                    EmptyState(symbol: searching ? "magnifyingglass" : "star", title: tr(searching ? "fxlib.noResults" : "fxlib.favorites.empty"))
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 70, maximum: 86), spacing: 10)], spacing: 12) {
                            ForEach(items) { s in StickerCard(sticker: s) { store.addGeneratorClip(.sticker(id: s.id)) } }
                        }
                        .padding(.horizontal, 12).padding(.bottom, 12)
                    }
                }
            }
            .padding(.top, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct StickerCard: View {
    let sticker: StickerDescriptor
    let add: () -> Void
    @State private var hover = false
    private var favorites: EffectFavorites { EffectFavorites.shared }

    var body: some View {
        let fav = favorites.contains(sticker.id)
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 6).fill(Theme.segmentSelected)
                .overlay {
                    Group {
                        if case .emoji(let e) = sticker.source { Text(verbatim: e).font(.system(size: 34)) }
                        else if let img = StickerThumbnails.image(sticker) { Image(decorative: img, scale: 2).resizable().scaledToFit().padding(12) }
                        else { Image(systemName: "face.smiling").font(.system(size: 22)).foregroundStyle(Theme.textTertiary) }
                    }
                    .scaleEffect(hover ? 1.12 : 1)
                    .rotationEffect(.degrees(hover ? -6 : 0))
                    .animation(hover ? .easeInOut(duration: 0.45).repeatForever(autoreverses: true) : .easeOut(duration: 0.15), value: hover)
                }
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(hover ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1.5))
            if hover {
                HStack(spacing: 4) {
                    RoundBadge(symbol: fav ? "star.fill" : "star", tint: fav ? Color(hex: 0xF5C542) : .white, fill: Color.black.opacity(0.55),
                               help: tr(fav ? "fxlib.removeFavorite" : "fxlib.addFavorite")) { favorites.toggle(sticker.id) }
                    RoundBadge(symbol: "plus", tint: .white, fill: Theme.accent, help: tr("asset.addToTrack"), action: add)
                }
                .padding(4)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2, perform: add)
        .onDrag { NSItemProvider(object: DragPayload.sticker(sticker.id) as NSString) }
        .contextMenu {
            Button(tr(fav ? "fxlib.removeFavorite" : "fxlib.addFavorite")) { favorites.toggle(sticker.id) }
            Button(tr("asset.addToTrack"), action: add)
        }
        .help(tr(sticker.nameKey))
    }
}
