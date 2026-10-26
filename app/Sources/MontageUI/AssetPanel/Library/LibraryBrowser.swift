import SwiftUI
import AppKit
import MontageCore
import Perception

// Shared asset-panel browser (UX.md §3.1–3.2), used by Media ▸ Library, Audio, Templates and the registry tabs:
// category rail (Favorites · Recent · sections), debounced search over every section, lazy grid (square / wide
// cards) or list rows, hover preview, ☆ favourite + ⊕ add, double-click / Return adds, drag to the timeline,
// keyboard navigation (←/→/↑/↓, Return = add, F = favourite, esc = leave), empty states.

/// One card / row of a library.
struct LibraryItem: Identifiable {
    let id: String
    var title: String
    var subtitle: String? = nil
    /// Extra searchable text (tags, group name, English keywords).
    var keywords: [String] = []
    /// Top-right badge (duration).
    var badge: String? = nil
    var art: LibraryArt
    /// Animated preview while hovered (effects/stock loops).
    var hoverFrames: (() async -> [CGImage])? = nil
    /// Drag payload understood by the timeline (DragPayload).
    var payload: String? = nil
    /// "Added" chip (used on the timeline).
    var added = false
    /// Rendering / downloading (progress ring instead of ⊕).
    var busy = false
    /// Audio rows: preview playing.
    var playing = false
    let add: () -> Void
    /// Single click (preview / select). Defaults to nothing.
    var click: (() -> Void)? = nil
    /// Audio rows: "Safe for social media ✓" badge + license card (bundled CC0 library, AU-001).
    var license: LibraryLicense? = nil
    /// Audio rows: "Similar" action (AU-025).
    var similar: (() -> Void)? = nil
}

/// License facts shown by the "safe for social media" badge's card.
struct LibraryLicense {
    var licenseName: String
    var licenseURL: String
    var author: String
    var sourceName: String
    var sourcePage: String
    var retrieved: String
    /// Extra "label: value" rows (BPM, key, duration…), already localized.
    var details: [(String, String)] = []
    /// CC BY (online items): usable on social media, but the author must be credited — amber "Credit" badge,
    /// the credit line (copyable) in the card.
    var credit: String? = nil
}

/// Card picture.
enum LibraryArt {
    case symbol(String)
    case emoji(String)
    case color(RGBA)
    case gradient([RGBA])
    case image(CGImage)
    /// Gradient cover with a symbol (audio rows).
    case cover([RGBA], symbol: String)
    /// Loaded lazily (cached by key) when the card scrolls into view.
    case async(key: String, load: () async -> CGImage?, placeholder: String = "photo", fit: Bool = false)
    /// Video / photo frame: whole frame visible, letterboxed on black in the tile (CapCut media cards, C3-3).
    case letterboxed(key: String, load: () async -> CGImage?, placeholder: String = "film")
}

struct LibrarySection: Identifiable {
    let id: String
    let title: String
    var items: [LibraryItem]
    /// Rail group header this section belongs to (nil = top level).
    var group: String? = nil
    /// false = searchable / favouritable but not listed in the rail (e.g. the media bin, drawn by a custom entry).
    var inRail = true
}

/// Rail entry ids shared by every library.
enum LibraryNav {
    static let favorites = "favorites"
    static let recent = "recent"
    static let search = "search"
}

enum LibraryTileStyle {
    /// 86 pt square cards (effects, stickers, stock).
    case square
    /// Wide cards with the given aspect (media 3:2, templates 9:16).
    case wide(CGFloat)
    /// 56 pt list rows (audio).
    case list
}

/// Case/diacritic-insensitive, all-terms search (title, subtitle, keywords).
enum LibrarySearch {
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matches(_ item: LibraryItem, _ query: String) -> Bool {
        matches(fields: [item.title, item.subtitle ?? ""] + item.keywords, query)
    }

    static func matches(fields: [String], _ query: String) -> Bool {
        let q = fold(query)
        guard !q.isEmpty else { return true }
        let hay = fields.map(fold)
        return q.split(separator: " ").allSatisfy { term in hay.contains { $0.contains(term) } }
    }

    /// Unique items of `sections` matching `query`, in section order.
    static func results(_ sections: [LibrarySection], _ query: String) -> [LibraryItem] {
        var seen = Set<String>()
        var out: [LibraryItem] = []
        for s in sections { for i in s.items where !seen.contains(i.id) && matches(i, query) { seen.insert(i.id); out.append(i) } }
        return out
    }
}

/// The browser: rail + content. `tab` keys the remembered rail selection / query; `namespace` keys favourites.
struct LibraryBrowser<Header: View>: View {
    let tab: String
    let namespace: String
    let sections: [LibrarySection]
    var style: LibraryTileStyle = .square
    var searchPlaceholder: String = tr("asset.search")
    var showsFavorites = true
    var showsRecents = true
    /// Extra rail entries before the sections whose content the caller draws (e.g. Media ▸ Import).
    var customNav: [(id: String, title: String)] = []
    var customContent: ((String) -> AnyView)? = nil
    /// Extra rail groups (after "Yours", before the sections) whose entries the caller draws with `customContent`,
    /// search included: while one of them is selected the query goes to the caller (e.g. Audio ▸ Online search).
    var customGroups: [(group: String, entries: [(id: String, title: String)])] = []
    var emptyHint: String? = nil
    /// Rail entry selected the first time (default: the first custom entry, else the first section).
    var initialNav: String? = nil
    /// Title of a collapsible group holding the custom entries, Favorites and Recent (CapCut "Yours ▴").
    var yoursGroup: String? = nil
    @ViewBuilder var header: () -> Header

    private var lib: AssetLibraryStore { AssetLibraryStore.shared }
    private var state: AssetPanelState { AssetPanelState.shared }

    var defaultNav: String { initialNav ?? customNav.first?.id ?? sections.first(where: \.inRail)?.id ?? LibraryNav.favorites }

    var navItems: [CategoryRail.Entry] {
        // CapCut "Yours ▴" group (custom entries, Favorites, Recent) when `yoursGroup` is set.
        let y = yoursGroup
        var out: [CategoryRail.Entry] = y.map { [.init(id: "group:" + $0, title: $0, isGroup: true)] } ?? []
        out += customNav.map { .init(id: $0.id, title: $0.title, group: y) }
        if showsFavorites { out.append(.init(id: LibraryNav.favorites, title: tr("asset.nav.favorites"), symbol: "star", group: y)) }
        if showsRecents { out.append(.init(id: LibraryNav.recent, title: tr("asset.nav.recent"), symbol: "clock", group: y)) }
        for g in customGroups {
            out.append(.init(id: "group:" + g.group, title: g.group, isGroup: true))
            out += g.entries.map { .init(id: $0.id, title: $0.title, group: g.group) }
        }
        var groups: [String] = []
        for s in sections where s.inRail {
            if let g = s.group {
                if !groups.contains(g) { groups.append(g); out.append(.init(id: "group:" + g, title: g, isGroup: true)) }
                out.append(.init(id: s.id, title: s.title, group: g))
            } else {
                out.append(.init(id: s.id, title: s.title))
            }
        }
        return out
    }

    var body: some View {
        WithPerceptionTracking {
            let nav = state.navBinding(tab, default: defaultNav)
            HStack(spacing: 0) {
                CategoryRail(tab: tab, entries: navItems, selection: nav)
                VStack(spacing: 0) {
                    header()
                    AssetSearchField(tab: tab, placeholder: searchPlaceholder)
                        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 6)
                    content(nav.wrappedValue)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    var customGroupEntries: [String] { customGroups.flatMap { $0.entries.map(\.id) } }

    @ViewBuilder func content(_ nav: String) -> some View {
        let query = state.query[tab] ?? ""
        let groupFirst = customGroups.first { "group:" + $0.group == nav }?.entries.first?.id
        if let custom = customContent, customGroupEntries.contains(nav) || groupFirst != nil {
            custom(groupFirst ?? nav)
        } else if !LibrarySearch.fold(query).isEmpty {
            let r = LibrarySearch.results(sections, query)
            LibraryItemsView(tab: tab, namespace: namespace, title: tr("asset.results", r.count), items: r, style: style,
                             empty: tr("asset.empty.search", query))
        } else if let custom = customContent, customNav.contains(where: { $0.id == nav }) {
            custom(nav)
        } else if let y = yoursGroup, nav == "group:" + y {
            if let custom = customContent, let first = customNav.first { custom(first.id) } else { AnyView(content(LibraryNav.favorites)) }
        } else if nav == LibraryNav.favorites {
            let all = LibrarySearch.results(sections, "")
            let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            LibraryItemsView(tab: tab, namespace: namespace, title: tr("asset.nav.favorites"),
                             items: lib.favoriteIDs(namespace).compactMap { byID[$0] }, style: style, empty: tr("asset.empty.favorites"))
        } else if nav == LibraryNav.recent {
            let all = LibrarySearch.results(sections, "")
            let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            LibraryItemsView(tab: tab, namespace: namespace, title: tr("asset.nav.recent"),
                             items: lib.recentIDs(namespace).compactMap { byID[$0] }, style: style, empty: tr("asset.empty.recent"))
        } else if nav.hasPrefix("group:") {
            let g = String(nav.dropFirst(6))
            let items = sections.filter { $0.group == g }.flatMap(\.items)
            LibraryItemsView(tab: tab, namespace: namespace, title: g, items: items, style: style, empty: emptyHint ?? tr("asset.empty.section"))
        } else {
            let s = sections.first { $0.id == nav } ?? sections.first
            LibraryItemsView(tab: tab, namespace: namespace, title: s?.title ?? "", items: s?.items ?? [], style: style,
                             empty: emptyHint ?? tr("asset.empty.section"))
        }
    }
}

extension LibraryBrowser where Header == EmptyView {
    init(tab: String, namespace: String, sections: [LibrarySection], style: LibraryTileStyle = .square,
         searchPlaceholder: String = tr("asset.search"), showsFavorites: Bool = true, showsRecents: Bool = true,
         customNav: [(id: String, title: String)] = [], customContent: ((String) -> AnyView)? = nil, emptyHint: String? = nil,
         defaultNav: String? = nil, yoursGroup: String? = nil) {
        self.init(tab: tab, namespace: namespace, sections: sections, style: style, searchPlaceholder: searchPlaceholder,
                  showsFavorites: showsFavorites, showsRecents: showsRecents, customNav: customNav, customContent: customContent,
                  emptyHint: emptyHint, initialNav: defaultNav, yoursGroup: yoursGroup, header: { EmptyView() })
    }
}

/// Section caption + lazy grid / list of items, with keyboard cursor and empty state.
struct LibraryItemsView: View {
    let tab: String
    let namespace: String
    let title: String
    let items: [LibraryItem]
    let style: LibraryTileStyle
    let empty: String
    @State private var width: CGFloat = 300

    private var state: AssetPanelState { AssetPanelState.shared }

    static let spacing: CGFloat = 10
    var minTile: CGFloat {
        switch style {
        case .square: return 78
        case .wide(let a): return a < 1 ? 74 : 96
        case .list: return .infinity
        }
    }

    var columns: Int {
        if case .list = style { return 1 }
        return max(1, Int((width - 24 + Self.spacing) / (minTile + Self.spacing)))
    }

    var body: some View {
        WithPerceptionTracking {
            Group {
                if items.isEmpty {
                    EmptyState(symbol: "tray", title: empty).testID("asset.empty")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            if !title.isEmpty {
                                Text(verbatim: title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                            }
                            if case .list = style {
                                LazyVStack(spacing: 8) {
                                    ForEach(items) { item in
                                        WithPerceptionTracking {
                                            LibraryRow(tab: tab, namespace: namespace, item: item).testID("asset.tile.\(item.id)")
                                        }
                                    }
                                }
                            } else {
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing, alignment: .top), count: columns),
                                          spacing: 12) {
                                    ForEach(items) { item in
                                        WithPerceptionTracking {
                                            LibraryTile(tab: tab, namespace: namespace, item: item, style: style).testID("asset.tile.\(item.id)")
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 12).padding(.bottom, 12)
                    }
                    .testID("asset.grid")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
            .onAppear { register() }
            .onValueChange(of: items.map(\.id)) { register() }
            .onValueChange(of: columns) { register() }
        }
    }

    /// Publishes the order / columns / actions for keyboard navigation and the state dump.
    private func register() {
        let byID = Dictionary(items.map { ($0.id, $0.add) }, uniquingKeysWith: { a, _ in a })
        state.layout[tab] = (items.map(\.id), columns)
        let ns = namespace
        state.actions[tab] = (add: { id in byID[id]?() ; AssetLibraryStore.shared.noteUsed(ns, id) },
                              favorite: { id in AssetLibraryStore.shared.toggleFavorite(ns, id) })
        if state.visibleCount[tab] != items.count { state.visibleCount[tab] = items.count }
    }
}

/// Grid card (square or wide): picture, badge, "Added" chip, hover animation, ☆ / ⊕ on hover or when selected.
struct LibraryTile: View {
    let tab: String
    let namespace: String
    let item: LibraryItem
    let style: LibraryTileStyle
    @State private var hover = false

    private var lib: AssetLibraryStore { AssetLibraryStore.shared }
    private var state: AssetPanelState { AssetPanelState.shared }
    var selected: Bool { state.cursor[tab] == item.id }
    var aspect: CGFloat { if case .wide(let a) = style { return a }; return 1 }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 5) {
                Color.clear
                    .aspectRatio(aspect, contentMode: .fit)
                    .overlay { LibraryArtView(art: item.art, hoverFrames: hover ? item.hoverFrames : nil) }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topTrailing) { if let b = item.badge { DurationBadge(text: b) } }
                    .overlay(alignment: .topLeading) { if item.added { AddedChip() } }
                    .overlay { if item.busy { ProgressView().controlSize(.small).tint(.white) } }
                    .overlay(alignment: .bottomTrailing) {
                        if hover || selected {
                            TileButtons(tab: tab, namespace: namespace, item: item)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(selected ? Theme.accent : (hover ? Theme.accent.opacity(0.6) : .clear), lineWidth: selected ? 2 : 1.5))
                Text(verbatim: item.title).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .assetTap(item.id, single: { select() }, double: { addNow() })
            .modifier(OptionalDrag(payload: item.payload))
            .contextMenu { TileMenu(namespace: namespace, item: item) }
            .help(item.title)
        }
    }

    func select() {
        state.cursor[tab] = item.id
        state.keyboardTab = tab
        item.click?()
    }

    func addNow() {
        item.add()
        lib.noteUsed(namespace, item.id)
    }
}

/// ☆ favourite + ⊕ add (or progress) buttons, bottom-right of a card.
struct TileButtons: View {
    let tab: String
    let namespace: String
    let item: LibraryItem
    private var lib: AssetLibraryStore { AssetLibraryStore.shared }

    var body: some View {
        WithPerceptionTracking {
            let fav = lib.isFavorite(namespace, item.id)
            HStack(spacing: 4) {
                Button { lib.toggleFavorite(namespace, item.id) } label: {
                    Image(systemName: fav ? "star.fill" : "star").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(fav ? Color(hex: 0xF5C451) : .white)
                        .frame(width: 20, height: 20).background(.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain).help(tr(fav ? "asset.unfavorite" : "asset.favorite"))
                .testID("asset.tile.\(item.id).favorite")
                Button { item.add(); lib.noteUsed(namespace, item.id) } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.onAccent)
                        .frame(width: 20, height: 20).background(Theme.accent, in: Circle())
                }
                .buttonStyle(.plain).help(tr("asset.addToTrack")).disabled(item.busy)
                .testID("asset.tile.\(item.id).add")
            }
            .padding(4)
        }
    }
}

struct TileMenu: View {
    let namespace: String
    let item: LibraryItem
    var body: some View {
        WithPerceptionTracking {
            let fav = AssetLibraryStore.shared.isFavorite(namespace, item.id)
            Button(tr("asset.addToTrack")) { item.add(); AssetLibraryStore.shared.noteUsed(namespace, item.id) }
            Button(tr(fav ? "asset.unfavorite" : "asset.favorite")) { AssetLibraryStore.shared.toggleFavorite(namespace, item.id) }
            if let similar = item.similar { Button(tr("audio.similar.find")) { similar() } }
            if item.license != nil { Button(tr("audio.license.show")) { LicenseCardState.shared.toggle(item.id) } }
        }
    }
}

/// List row (audio): 40 pt cover · title / subtitle · ☆ · ⊕; click = preview, playing = ▶ progress + waveform.
struct LibraryRow: View {
    let tab: String
    let namespace: String
    let item: LibraryItem
    @State private var hover = false
    private var lib: AssetLibraryStore { AssetLibraryStore.shared }
    private var state: AssetPanelState { AssetPanelState.shared }
    var selected: Bool { state.cursor[tab] == item.id }

    var body: some View {
        WithPerceptionTracking {
            let fav = lib.isFavorite(namespace, item.id)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Color.clear.frame(width: 40, height: 40)
                        .overlay { LibraryArtView(art: item.art, hoverFrames: nil) }
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay {
                            if item.busy { ProgressView().controlSize(.small).tint(.white) }
                            else if item.playing || hover {
                                ZStack {
                                    Color.black.opacity(0.45)
                                    Image(systemName: item.playing ? "pause.fill" : "play.fill").font(.system(size: 14)).foregroundStyle(.white)
                                }
                            }
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(verbatim: item.title).font(.system(size: 13)).foregroundStyle(item.playing ? Theme.accent : Theme.textPrimary).lineLimit(1)
                            if let l = item.license { SafeForSocialBadge(itemID: item.id, needsCredit: l.credit != nil) }
                            if item.added { AddedChip(inline: true) }
                        }
                        if let s = item.subtitle {
                            Text(verbatim: s).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if let similar = item.similar, hover || selected || item.playing {
                        Button { similar() } label: {
                            Image(systemName: "waveform.and.magnifyingglass").font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary).frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain).help(tr("audio.similar.find"))
                        .testID("asset.tile.\(item.id).similar")
                    }
                    Button { lib.toggleFavorite(namespace, item.id) } label: {
                        Image(systemName: fav ? "star.fill" : "star").font(.system(size: 12))
                            .foregroundStyle(fav ? Color(hex: 0xF5C451) : Theme.textTertiary).frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain).help(tr(fav ? "asset.unfavorite" : "asset.favorite"))
                    .testID("asset.tile.\(item.id).favorite")
                    Button { item.add(); lib.noteUsed(namespace, item.id) } label: {
                        Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.onAccent)
                            .frame(width: 22, height: 22).background(Theme.accent, in: Circle())
                    }
                    .buttonStyle(.plain).help(tr("asset.addToTrack")).disabled(item.busy)
                    .testID("asset.tile.\(item.id).add")
                }
                .padding(8)
                if item.playing { AudioPreviewStrip(id: item.id).padding(.horizontal, 8).padding(.bottom, 6) }
                if let l = item.license, LicenseCardState.shared.shownID == item.id {
                    LicenseCard(itemID: item.id, title: item.title, license: l).padding(.horizontal, 8).padding(.bottom, 8)
                }
            }
            .background(Color(white: selected ? 0.2 : 0.165), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Theme.accent : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .assetTap(item.id, single: {
                state.cursor[tab] = item.id
                state.keyboardTab = tab
                item.click?()
            }, double: { item.add(); lib.noteUsed(namespace, item.id) })
            .modifier(OptionalDrag(payload: item.payload))
            .contextMenu { TileMenu(namespace: namespace, item: item) }
        }
    }
}

extension View {
    /// Click selects immediately; a second click on the same card within the double-click interval also runs
    /// `double` (no single-tap delay, unlike stacking `onTapGesture(count: 2)` over `onTapGesture`).
    func assetTap(_ id: String, single: @escaping () -> Void, double: @escaping () -> Void) -> some View {
        onTapGesture {
            let now = Date.timeIntervalSinceReferenceDate
            let isDouble = AssetTapTracker.lastID == id && now - AssetTapTracker.lastTime < NSEvent.doubleClickInterval
            AssetTapTracker.lastID = isDouble ? nil : id
            AssetTapTracker.lastTime = now
            single()
            if isDouble { double() }
        }
    }
}

@MainActor
enum AssetTapTracker {
    static var lastID: String?
    static var lastTime: TimeInterval = 0
}

struct OptionalDrag: ViewModifier {
    let payload: String?
    func body(content: Content) -> some View {
        if let payload { content.onDrag { NSItemProvider(object: payload as NSString) } } else { content }
    }
}

struct DurationBadge: View {
    let text: String
    var body: some View {
        WithPerceptionTracking {
            Text(verbatim: text).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 1.5)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 3))
                .padding(4)
        }
    }
}

/// CapCut "Added" chip on cards already used on the timeline.
struct AddedChip: View {
    var inline = false
    var body: some View {
        WithPerceptionTracking {
            Text(loc: "asset.added").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Theme.accentDim, in: RoundedRectangle(cornerRadius: 3))
                .padding(inline ? 0 : 4)
        }
    }
}

/// Draws a `LibraryArt`; while `hoverFrames` is set, loads them once (cached) and loops them at 10 fps.
struct LibraryArtView: View {
    let art: LibraryArt
    let hoverFrames: (() async -> [CGImage])?
    @State private var frames: [CGImage] = []

    var body: some View {
        WithPerceptionTracking {
            ZStack {
                base
                if hoverFrames != nil, !frames.isEmpty {
                    SwiftUI.TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                        WithPerceptionTracking {
                            let i = Int(ctx.date.timeIntervalSinceReferenceDate * 10) % frames.count
                            Image(decorative: frames[i], scale: 2).resizable().interpolation(.high)
                                .aspectRatio(contentMode: letterboxed ? .fit : .fill)
                        }
                    }
                }
            }
            .task(id: hoverFrames != nil) {
                guard let load = hoverFrames else { frames = []; return }
                let f = await load()
                if !Task.isCancelled { frames = f }
            }
        }
    }

    var letterboxed: Bool { if case .letterboxed = art { return true }; return false }

    @ViewBuilder var base: some View {
        switch art {
        case .symbol(let s):
            ZStack { Theme.segmentSelected; Image(systemName: s).font(.system(size: 22)).foregroundStyle(Theme.textPrimary.opacity(0.85)) }
        case .emoji(let e):
            ZStack { Theme.segmentSelected; Text(verbatim: e).font(.system(size: 34)) }
        case .color(let c):
            Color(red: c.r, green: c.g, blue: c.b).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.separator, lineWidth: 1))
        case .gradient(let cs):
            LinearGradient(colors: cs.map { Color(red: $0.r, green: $0.g, blue: $0.b) }, startPoint: .topLeading, endPoint: .bottomTrailing)
        case .image(let img):
            Image(decorative: img, scale: 2).resizable().aspectRatio(contentMode: .fill)
        case .cover(let cs, let symbol):
            ZStack {
                LinearGradient(colors: cs.map { Color(red: $0.r, green: $0.g, blue: $0.b) }, startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.9))
            }
        case .async(let key, let load, let placeholder, let fit):
            AsyncArt(key: key, load: load, placeholder: placeholder, fit: fit)
        case .letterboxed(let key, let load, let placeholder):
            AsyncArt(key: key, load: load, placeholder: placeholder, letterbox: true)
        }
    }
}

/// Lazily loaded card picture with a process-wide memory cache (cards scrolled back into view are instant).
struct AsyncArt: View {
    let key: String
    let load: () async -> CGImage?
    let placeholder: String
    var fit = false
    /// Aspect-fit on black, no inset (media frames).
    var letterbox = false
    @State private var image: CGImage?

    var body: some View {
        WithPerceptionTracking {
            ZStack {
                if letterbox { Color.black } else { Theme.inset }
                if let img = image ?? LibraryArtCache.shared.get(key) {
                    Image(decorative: img, scale: 2).resizable().interpolation(.high)
                        .aspectRatio(contentMode: fit || letterbox ? .fit : .fill).padding(fit ? 6 : 0)
                } else {
                    Image(systemName: placeholder).font(.system(size: 18)).foregroundStyle(Theme.textTertiary)
                }
            }
            .task(id: key) {
                if LibraryArtCache.shared.get(key) != nil { return }
                // Debounce: cards flying past during a fast scroll never start loading.
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled, let img = await load() else { return }
                LibraryArtCache.shared.set(key, img)
                if !Task.isCancelled { image = img }
            }
        }
    }
}

@MainActor
final class LibraryArtCache {
    static let shared = LibraryArtCache()
    private let cache: NSCache<NSString, CGImageBox> = {
        let c = NSCache<NSString, CGImageBox>()
        c.totalCostLimit = 48 << 20
        return c
    }()
    final class CGImageBox { let image: CGImage; init(_ i: CGImage) { image = i } }
    func get(_ k: String) -> CGImage? { cache.object(forKey: k as NSString)?.image }
    func set(_ k: String, _ i: CGImage) { cache.setObject(CGImageBox(i), forKey: k as NSString, cost: i.bytesPerRow * i.height) }
}

/// Left rail (120 pt): plain entries, collapsible group headers (filled, chevron) with indented children.
struct CategoryRail: View {
    struct Entry: Identifiable {
        let id: String
        let title: String
        var symbol: String? = nil
        var isGroup = false
        var group: String? = nil
    }
    let tab: String
    let entries: [Entry]
    @Binding var selection: String
    @State private var collapsed: Set<String> = []

    var body: some View {
        WithPerceptionTracking {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(entries) { e in
                        WithPerceptionTracking {
                            if e.isGroup {
                                groupHeader(e)
                            } else if e.group == nil || !collapsed.contains(e.group!) {
                                item(e)
                            }
                        }
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 8)
            }
            .frame(width: 120)
            .background(Theme.panel)
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.separator).frame(width: 1) }
        }
    }

    func groupHeader(_ e: Entry) -> some View {
        let open = !collapsed.contains(e.title)
        let sel = selection == e.id
        return HStack(spacing: 4) {
            Text(verbatim: e.title).font(.system(size: 12, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.9)
                .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
            Spacer(minLength: 0)
            Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                .frame(width: 10, height: 20).contentShape(Rectangle())
                .onTapGesture { if open { collapsed.insert(e.title) } else { collapsed.remove(e.title) } }
        }
        .foregroundStyle(sel ? Theme.accent : Theme.textPrimary)
        .padding(.leading, 8).padding(.trailing, 3).padding(.vertical, 4).frame(minHeight: 28)
        .background(sel ? Theme.accentDim.opacity(0.45) : Color(hex: 0x2A2A2A), in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { selection = e.id; AssetPanelState.shared.query[tab] = nil }
        .testID("asset.nav.\(e.id)")
    }

    func item(_ e: Entry) -> some View {
        let sel = selection == e.id
        return HStack(spacing: 5) {
            if let s = e.symbol { Image(systemName: sel ? s + ".fill" : s).font(.system(size: 10)) }
            Text(verbatim: e.title).font(.system(size: 12)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(sel ? Theme.accent : Theme.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, e.group == nil ? 10 : 18).padding(.trailing, 6).padding(.vertical, 5).frame(minHeight: 28)
        .background(sel ? Theme.accentDim.opacity(0.45) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { selection = e.id; AssetPanelState.shared.query[tab] = nil }
        .testID("asset.nav.\(e.id)")
    }
}

/// Search field (28 pt, #141414, radius 4, 🔍): typing updates the shared query for `tab` after a 250 ms pause.
struct AssetSearchField: View {
    let tab: String
    let placeholder: String
    static let debounce: Duration = .milliseconds(250)
    @State private var text = ""
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                // Each keystroke schedules the commit from the binding itself. With `.onChange(of: text)` macOS 13 dropped
                // the last change of a burst: a keystroke landing while the panel re-rendered for the previous (debounced)
                // query set `text` but never re-ran onChange, so the query stayed "summ" while the field showed "summer".
                TextField(placeholder, text: Binding(get: { text }, set: { text = $0; commit($0, now: false) }))
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .onSubmit { commit(text, now: true) }
                    // BUG-SPACE-FOCUS: Esc gives the keyboard back to the editor (Space plays again); the query stays
                    .focused($focused)
                    .onExitCommand { focused = false }
                    .testID("asset.search")
                if !text.isEmpty {
                    Button { text = ""; commit("", now: true) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain).help(tr("asset.search.clear")).testID("asset.search.clear")
                }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(Color(hex: 0x141414), in: RoundedRectangle(cornerRadius: 4))
            .onAppear { text = AssetPanelState.shared.query[tab] ?? "" }
            .onValueChange(of: AssetPanelState.shared.query[tab] ?? "") { _, q in if q.isEmpty && !text.isEmpty && task == nil { text = "" } }
        }
    }

    func commit(_ t: String, now: Bool) {
        task?.cancel()
        let tab = tab
        if now { AssetPanelState.shared.query[tab] = t; task = nil; return }
        task = Task {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            AssetPanelState.shared.query[tab] = t
            task = nil
        }
    }
}
