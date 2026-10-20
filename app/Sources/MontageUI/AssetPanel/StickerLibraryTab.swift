import SwiftUI
import CoreGraphics
import MontageCore
import MontageEffects
import MontageEngine
import Perception

// Stickers tab (ST-001/002/008, UX.md §3.6): Favorites + categories (emoji groups, callouts, arrows, decorations,
// shapes), search, 86 pt cards that wiggle on hover, ☆ / ⊕, double-click or drag to add (3 s sticker clip).

/// Sticker catalogue: groups in display order, search (names + tags), favourites — unit-tested.
enum StickerCatalog {
    static let groupOrder = ["emoji", "gestures", "love", "celebration", "animals", "food", "nature", "objects", "symbols",
                             "callouts", "arrows", "decor", "shapes"].map { "sticker.group.\($0)" }

    /// "Yours" (ST-003): imported custom stickers + the Import card; always listed right after Favorites.
    static let yoursNav = UserStickerLibrary.groupKey

    static func groups() -> [String] {
        var seen: [String] = []
        for s in Registries.stickers.all where !seen.contains(s.groupKey) && s.groupKey != yoursNav { seen.append(s.groupKey) }
        return groupOrder.filter(seen.contains) + seen.filter { !groupOrder.contains($0) }
    }

    /// "Recent" (ST-010): stickers added to the timeline, most recent first (`AssetLibraryStore` namespace "stickers").
    static let recentNav = "asset.nav.recent"
    static let recentsNamespace = "stickers"
    /// Rail entries before the categories (Favorites · Recent · Yours).
    static let leadingNavCount = 3

    static func nav() -> [(id: String, titleKey: String)] {
        [(EffectLibraryCatalog.favoritesNav, "fxlib.favorites"), (recentNav, recentNav), (yoursNav, yoursNav)] + groups().map { ($0, $0) }
    }

    /// Sort of a sticker list (ST-010): catalogue order, favourites first, or recently used first.
    enum Sort: String, CaseIterable { case standard, favorites, recent }

    static func sorted(_ items: [StickerDescriptor], by sort: Sort, favorites: Set<String>, recents: [String]) -> [StickerDescriptor] {
        switch sort {
        case .standard: return items
        case .favorites:
            return items.filter { favorites.contains($0.id) } + items.filter { !favorites.contains($0.id) }
        case .recent:
            let rank = Dictionary(recents.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            let used = items.filter { rank[$0.id] != nil }.sorted { rank[$0.id]! < rank[$1.id]! }
            return used + items.filter { rank[$0.id] == nil }
        }
    }

    /// Registered stickers minus deleted custom ones (the registry can't unregister).
    static var available: [StickerDescriptor] {
        Registries.stickers.all.filter { s in
            if case .user(let id) = s.source { return UserStickerLibrary.shared.entry(id) != nil }
            return true
        }
    }

    static func entries(nav: String, favorites: Set<String>, recents: [String] = []) -> [StickerDescriptor] {
        let all = available
        if nav == recentNav { return recents.compactMap { id in all.first { $0.id == id } } }
        return nav == EffectLibraryCatalog.favoritesNav ? all.filter { favorites.contains($0.id) } : all.filter { $0.groupKey == nav }
    }

    static func search(_ query: String) -> [StickerDescriptor] {
        let q = EffectLibraryCatalog.fold(query)
        guard !q.isEmpty else { return available }
        return available.filter { s in
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
        // W5: animated (Lottie) stickers show their poster frame (LottieLibrary caches it)
        if case .lottie(let r, let b) = s.source { return b().url(forResource: r, withExtension: nil).flatMap { LottieLibrary.shared.thumbnail($0) } }
        if case .user(let id) = s.source { return UserStickerLibrary.shared.thumbnail(id) }   // ST-003 (cached by the library)
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
    @State private var selected: String?
    @State private var revision = 0   // bumps after importing / deleting custom stickers
    @State private var sort: StickerCatalog.Sort = .standard
    private var favorites: EffectFavorites { EffectFavorites.shared }

    var body: some View {
        WithPerceptionTracking {
            let _ = revision
            let navItems = StickerCatalog.nav()
            let current = nav.isEmpty ? (navItems.dropFirst(StickerCatalog.leadingNavCount).first?.id ?? navItems[0].id) : nav
            let yours = current == StickerCatalog.yoursNav
            let recentNav = current == StickerCatalog.recentNav
            let searching = !EffectLibraryCatalog.fold(query).isEmpty
            let recents = AssetLibraryStore.shared.recentIDs(StickerCatalog.recentsNamespace)
            let listed = searching ? StickerCatalog.search(query) : StickerCatalog.entries(nav: current, favorites: favorites.ids, recents: recents)
            let items = recentNav && !searching ? listed : StickerCatalog.sorted(listed, by: sort, favorites: favorites.ids, recents: recents)
            HStack(spacing: 0) {
                SubNav(items: navItems.map { ($0.id, tr($0.titleKey)) }, selection: Binding.perceived(get: { current }, set: { nav = $0; query = "" }))
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        TextField(tr("fxlib.search.stickers"), text: $query).textFieldStyle(.plain).font(.system(size: 12))
                    }
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(Theme.inset, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.08)))
                    .padding(.horizontal, 12)
                    .testID("asset.search")
                    HStack {
                        Text(verbatim: searching ? tr("fxlib.results") : tr(navItems.first { $0.id == current }?.titleKey ?? current))
                            .font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        if !recentNav || searching {
                            // ST-010 sort: Default · Favorites first · Recently used first
                            Menu {
                                ForEach(StickerCatalog.Sort.allCases, id: \.self) { s in
                                    WithPerceptionTracking {
                                        Button { sort = s } label: {
                                            if s == sort { Label(tr("sticker.sort.\(s.rawValue)"), systemImage: "checkmark") } else { Text(tr("sticker.sort.\(s.rawValue)")) }
                                        }
                                    }
                                }
                            } label: {
                                Image(systemName: "arrow.up.arrow.down").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .help(tr("sticker.sort"))
                            .testID("sticker.sort")
                        }
                    }
                    .padding(.horizontal, 12)
                    if items.isEmpty && !(yours && !searching) {
                        EmptyState(symbol: searching ? "magnifyingglass" : (recentNav ? "clock" : "star"),
                                   title: tr(searching ? "fxlib.noResults" : (recentNav ? "asset.empty.recent" : "fxlib.favorites.empty")))
                    } else {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 78, maximum: 96), spacing: 12)], spacing: 14) {
                                if yours && !searching {
                                    ImportStickerCard { store.importStickersWithPanel(); revision += 1 }.testID("sticker.import")
                                }
                                ForEach(items) { s in
                                    WithPerceptionTracking {
                                        StickerCard(sticker: s, selected: selected == s.id, select: { selected = s.id; store.previewSticker(s.id) },
                                                    add: {
                                                        selected = s.id; store.addGeneratorClip(.sticker(id: s.id))
                                                        AssetLibraryStore.shared.noteUsed(StickerCatalog.recentsNamespace, s.id)
                                                    },
                                                    remove: s.groupKey == StickerCatalog.yoursNav ? {
                                                        UserStickerLibrary.shared.remove(s.id); revision += 1
                                                    } : nil)
                                            .testID("asset.tile.\(s.id)")
                                    }
                                }
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
}

struct StickerCard: View {
    let sticker: StickerDescriptor
    let selected: Bool
    let select: () -> Void
    let add: () -> Void
    /// Custom stickers (Yours): "Delete" in the context menu.
    var remove: (() -> Void)? = nil
    @State private var hover = false
    private var favorites: EffectFavorites { EffectFavorites.shared }

    var body: some View {
        WithPerceptionTracking {
            let fav = favorites.contains(sticker.id)
            ZStack(alignment: .bottomTrailing) {
                Button(action: clicked) {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.segmentSelected)
                        .overlay {
                            Group {
                                if case .emoji(let e) = sticker.source { Text(verbatim: e).font(.system(size: 46)) }
                                else if let img = StickerThumbnails.image(sticker) { Image(decorative: img, scale: 2).resizable().scaledToFit().padding(12) }
                                else { Image(systemName: "face.smiling").font(.system(size: 22)).foregroundStyle(Theme.textTertiary) }
                            }
                            .scaleEffect(hover ? 1.12 : 1)
                            .rotationEffect(.degrees(hover ? -6 : 0))
                            .animation(hover ? .easeInOut(duration: 0.45).repeatForever(autoreverses: true) : .easeOut(duration: 0.15), value: hover)
                        }
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Theme.accent : (hover ? Theme.accent.opacity(0.6) : .clear),
                                                                           lineWidth: selected ? 2 : 1.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if hover || selected {
                    CardBadges(id: sticker.id, fav: fav, add: add)
                } else if fav {
                    Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Color(hex: 0xF5C542)).padding(5)
                        .allowsHitTesting(false)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onDrag { NSItemProvider(object: DragPayload.sticker(sticker.id) as NSString) }
            .contextMenu {
                Button(tr(fav ? "fxlib.removeFavorite" : "fxlib.addFavorite")) { favorites.toggle(sticker.id) }
                Button(tr("asset.addToTrack"), action: add)
                if let remove { Divider(); Button(tr("sticker.delete"), role: .destructive, action: remove) }
            }
            .help(tr(sticker.nameKey))
        }
    }

    private func clicked() {
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { add() } else { select() }
    }
}
