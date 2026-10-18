import SwiftUI
import CoreGraphics
import MontageCore
import MontageEffects
import MontageEngine

// Effects / Filters / Adjustment asset tabs (UX.md §3.1–3.2, 3.7, 3.9, 3.10): left sub-nav (Favorites, Trending /
// Featured, categories), search, 86 pt square cards rendered with the real effect on the procedural sample frame,
// hover plays the animated preview in place, ☆ favourite + ⊕ add on hover, double-click / ⊕ adds at the playhead,
// drag to the timeline (or onto a clip). Owned by W4; additive to the W13 asset-panel infrastructure.

/// Pure catalogue logic (sections, ordering, search) for one effect category — unit-tested.
enum EffectLibraryCatalog {
    static let favoritesNav = "fxlib.nav.favorites"
    static let curatedNav = "fxlib.nav.curated"

    static let groupOrder: [EffectCategory: [String]] = [
        .effect: ["basic", "blur", "lens", "motion", "glitch", "retro", "light", "dreamy", "bling", "party", "nature", "comic",
                  "distortion", "split", "frame", "body"].map { "effect.group.\($0)" },
        .filter: ["portrait", "life", "food", "landscape", "movies", "film", "retro", "bw", "night", "style", "creative"].map { "filter.group.\($0)" },
        .adjustment: ["adjust.group.basic", "adjust.group.color", "adjust.group.lut"],
    ]

    /// Entries that only make sense from the inspector (Auto adjust is computed from a frame).
    static let hiddenGroups: Set<String> = ["adjust.group.auto"]

    static func items(_ category: EffectCategory) -> [EffectDescriptor] {
        Registries.effects(in: category).filter { !hiddenGroups.contains($0.groupKey) }
    }

    /// Group keys in display order (known order first, then any other group in registry order).
    static func groups(_ category: EffectCategory) -> [String] {
        var seen: [String] = []
        for d in items(category) where !seen.contains(d.groupKey) { seen.append(d.groupKey) }
        let pref = groupOrder[category] ?? []
        return pref.filter(seen.contains) + seen.filter { !pref.contains($0) }
    }

    static func curated(_ category: EffectCategory) -> [String] {
        switch category {
        case .effect: return BuiltinEffects.trending
        case .filter: return BuiltinFilters.featured
        default: return []
        }
    }

    static func curatedTitleKey(_ category: EffectCategory) -> String { category == .filter ? "fxlib.featured" : "fxlib.trending" }

    /// Sub-nav entries: (id, title key).
    static func nav(_ category: EffectCategory) -> [(id: String, titleKey: String)] {
        var out: [(String, String)] = [(favoritesNav, "fxlib.favorites")]
        if !curated(category).isEmpty { out.append((curatedNav, curatedTitleKey(category))) }
        return out + groups(category).map { ($0, $0) }
    }

    static func entries(_ category: EffectCategory, nav: String, favorites: Set<String>) -> [EffectDescriptor] {
        let all = items(category)
        switch nav {
        case favoritesNav: return all.filter { favorites.contains($0.id) }
        case curatedNav: return curated(category).compactMap { id in all.first { $0.id == id } }
        default: return all.filter { $0.groupKey == nav }
        }
    }

    /// Case- and diacritic-insensitive match on the localized name, group, English tags and id.
    static func matches(_ d: EffectDescriptor, _ query: String) -> Bool {
        let q = fold(query)
        guard !q.isEmpty else { return true }
        let hay = [tr(d.nameKey), tr(d.groupKey), d.id.split(separator: ".").last.map(String.init) ?? ""] + d.tags
        return q.split(separator: " ").allSatisfy { term in hay.contains { fold($0).contains(term) } }
    }

    static func search(_ category: EffectCategory, _ query: String) -> [EffectDescriptor] {
        items(category).filter { matches($0, query) }
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespaces)
    }
}

/// Favourite effects/filters/adjustments (☆ on cards), persisted per user.
@MainActor @Observable
final class EffectFavorites {
    static let shared = EffectFavorites()
    static let defaultsKey = "montage.assets.favoriteEffects"
    private(set) var ids: Set<String>
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    func toggle(_ id: String) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        defaults.set(ids.sorted(), forKey: Self.defaultsKey)
    }
}

/// Card thumbnails rendered off-main by `EffectPreviewRenderer` (same shaders as preview/export): one still per
/// entry (LRU-bounded) and a short animated loop for the hovered card.
@MainActor @Observable
final class EffectThumbnails {
    static let shared = EffectThumbnails()
    static let pixels = 160
    static let frameCount = 16
    static let loopSeconds = 2.0
    nonisolated static let queue = DispatchQueue(label: "montage.fx-thumbnails", qos: .utility)

    private(set) var stills: [String: CGImage] = [:]
    private(set) var loops: [String: [CGImage]] = [:]
    @ObservationIgnored private var pending: Set<String> = []
    @ObservationIgnored private var stillOrder: [String] = []
    @ObservationIgnored private var loopOrder: [String] = []
    @ObservationIgnored let maxStills = 260
    @ObservationIgnored let maxLoops = 4

    struct Box: @unchecked Sendable { let images: [CGImage] }

    static func stillTime(_ d: EffectDescriptor) -> Double { d.category == .effect ? 0.9 : 0.0 }

    func still(_ d: EffectDescriptor) -> CGImage? {
        if let img = stills[d.id] { return img }
        let key = "s:" + d.id
        guard !pending.contains(key) else { return nil }
        pending.insert(key)
        let t = Self.stillTime(d), n = Self.pixels
        Self.queue.async {
            let img = EffectPreviewRenderer.shared.image(d, time: t, width: n, height: n)
            let box = Box(images: img.map { [$0] } ?? [])
            Task { @MainActor in EffectThumbnails.shared.storeStill(d.id, box) }
        }
        return nil
    }

    func loop(_ d: EffectDescriptor) -> [CGImage]? {
        if let l = loops[d.id] { return l }
        let key = "l:" + d.id
        guard d.category == .effect, !pending.contains(key) else { return nil }
        pending.insert(key)
        let n = Self.pixels, count = Self.frameCount, step = Self.loopSeconds / Double(count)
        Self.queue.async {
            let frames = (0..<count).compactMap { EffectPreviewRenderer.shared.image(d, time: 0.05 + Double($0) * step, width: n, height: n) }
            let box = Box(images: frames)
            Task { @MainActor in EffectThumbnails.shared.storeLoop(d.id, box) }
        }
        return nil
    }

    private func storeStill(_ id: String, _ box: Box) {
        pending.remove("s:" + id)
        guard let img = box.images.first else { return }
        stills[id] = img
        stillOrder.append(id)
        if stillOrder.count > maxStills { stills[stillOrder.removeFirst()] = nil }
    }

    private func storeLoop(_ id: String, _ box: Box) {
        pending.remove("l:" + id)
        guard !box.images.isEmpty else { return }
        loops[id] = box.images
        loopOrder.append(id)
        if loopOrder.count > maxLoops { loops[loopOrder.removeFirst()] = nil }
    }
}

/// One asset tab (Effects, Filters or Adjustment).
struct EffectLibraryTab: View {
    let store: EditorStore
    let category: EffectCategory
    @State private var nav: String = ""
    @State private var query = ""
    @State private var selected: String?
    private var favorites: EffectFavorites { EffectFavorites.shared }

    var searchKey: String {
        switch category {
        case .filter: return "fxlib.search.filters"
        case .adjustment: return "fxlib.search.adjustments"
        default: return "fxlib.search.effects"
        }
    }

    var body: some View {
        let navItems = EffectLibraryCatalog.nav(category)
        let current = nav.isEmpty ? (navItems.dropFirst().first?.id ?? navItems[0].id) : nav
        let searching = !EffectLibraryCatalog.fold(query).isEmpty
        let items = searching ? EffectLibraryCatalog.search(category, query)
            : EffectLibraryCatalog.entries(category, nav: current, favorites: favorites.ids)
        let title = searching ? tr("fxlib.results") : tr(navItems.first { $0.id == current }?.titleKey ?? current)
        HStack(spacing: 0) {
            SubNav(items: navItems.map { ($0.id, tr($0.titleKey)) }, selection: Binding(get: { current }, set: { nav = $0; query = "" }))
            VStack(alignment: .leading, spacing: 8) {
                searchField
                Text(verbatim: title).font(.system(size: 13)).foregroundStyle(Theme.textPrimary).padding(.horizontal, 12)
                if items.isEmpty {
                    EmptyState(symbol: current == EffectLibraryCatalog.favoritesNav && !searching ? "star" : "magnifyingglass",
                               title: tr(searching ? "fxlib.noResults" : (current == EffectLibraryCatalog.favoritesNav ? "fxlib.favorites.empty" : "fxlib.noResults")))
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 78, maximum: 96), spacing: 12)], spacing: 14) {
                            ForEach(items) { d in
                                EffectCard(descriptor: d, selected: selected == d.id,
                                           select: { selected = d.id }, add: { selected = d.id; store.applyEffect(d) })
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

    var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            TextField(tr(searchKey), text: $query).textFieldStyle(.plain).font(.system(size: 12))
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.textTertiary).help(tr("fxlib.clearSearch"))
            }
        }
        .padding(.horizontal, 10).frame(height: 28)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.08)))
        .padding(.horizontal, 12)
    }
}

/// Square card: real render of the entry on the sample frame; hover loops the animated preview and shows ☆ / ⊕.
struct EffectCard: View {
    let descriptor: EffectDescriptor
    let selected: Bool
    let select: () -> Void
    let add: () -> Void
    @State private var hover = false
    @State private var hoverStart = Date()
    private var thumbs: EffectThumbnails { EffectThumbnails.shared }
    private var favorites: EffectFavorites { EffectFavorites.shared }

    var body: some View {
        let fav = favorites.contains(descriptor.id)
        VStack(spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 6).fill(Theme.segmentSelected)
                    .overlay { preview }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Theme.accent : (hover ? Theme.accent.opacity(0.6) : .clear),
                                                                       lineWidth: selected ? 2 : 1.5))
                if hover {
                    HStack(spacing: 4) {
                        RoundBadge(symbol: fav ? "star.fill" : "star", tint: fav ? Color(hex: 0xF5C542) : .white, fill: Color.black.opacity(0.55),
                                   help: tr(fav ? "fxlib.removeFavorite" : "fxlib.addFavorite")) { favorites.toggle(descriptor.id) }
                        RoundBadge(symbol: "plus", tint: .white, fill: Theme.accent, help: tr("asset.addToTrack"), action: add)
                    }
                    .padding(4)
                } else if fav {
                    Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Color(hex: 0xF5C542)).padding(5)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            Text(verbatim: tr(descriptor.nameKey)).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                .lineLimit(1).truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .onHover { h in hover = h; if h { hoverStart = Date() } }
        .onTapGesture(count: 2, perform: add)
        .onTapGesture(perform: select)
        .onDrag { NSItemProvider(object: DragPayload.effect(descriptor.id) as NSString) }
        .contextMenu {
            Button(tr(fav ? "fxlib.removeFavorite" : "fxlib.addFavorite")) { favorites.toggle(descriptor.id) }
            Button(tr("asset.addToTrack"), action: add)
        }
        .help(tr(descriptor.nameKey))
    }

    @ViewBuilder var preview: some View {
        if hover, let frames = thumbs.loop(descriptor), !frames.isEmpty {
            SwiftUI.TimelineView(.animation(minimumInterval: EffectThumbnails.loopSeconds / Double(EffectThumbnails.frameCount))) { tl in
                let t = tl.date.timeIntervalSince(hoverStart)
                let i = Int(t / EffectThumbnails.loopSeconds * Double(frames.count)) % frames.count
                Image(decorative: frames[max(0, i)], scale: 2).resizable().scaledToFill()
            }
        } else if descriptor.category == .adjustment && !descriptor.id.hasPrefix("user.lut.") {
            Image(systemName: descriptor.symbol).font(.system(size: 24)).foregroundStyle(Theme.textPrimary.opacity(0.85))
        } else if let img = thumbs.still(descriptor) {
            Image(decorative: img, scale: 2).resizable().scaledToFill()
        } else {
            Image(systemName: descriptor.symbol).font(.system(size: 22)).foregroundStyle(Theme.textTertiary)
        }
    }
}

/// 20 pt round button on a card (☆ / ⊕).
struct RoundBadge: View {
    let symbol: String
    let tint: Color
    let fill: Color
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
                .frame(width: 20, height: 20).background(fill, in: Circle())
        }
        .buttonStyle(.plain).help(help)
    }
}
