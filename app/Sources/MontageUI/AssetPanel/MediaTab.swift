import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MontageCore
import MontageEngine
import Perception

/// Media tab (UX.md §3.3): rail Import · Favorites · Recent · Library ▾ (local royalty-free stock). Import = the
/// project bin: [⊕ Import] · new folder · grid/list · sort · type filter, folders, 3:2 cards (duration, "Added",
/// hover scrub, ☆ / ⊕), multi-select (⌘ / ⇧ click) and drag of the selection to the timeline, Finder drops.
struct MediaTab: View {
    @Perception.Bindable var store: EditorStore
    /// Kinds listed (the Audio tab reuses this view for "Yours" with `[.audio]`).
    var kinds: Set<MediaKind> = [.video, .image, .audio]

    var isFullTab: Bool { kinds.count == 3 }
    var tabID: String { isFullTab ? "media" : "audio" }

    var body: some View {
        WithPerceptionTracking {
            if isFullTab {
                LibraryBrowser(tab: tabID, namespace: "media", sections: sections, style: .wide(1.5),
                               searchPlaceholder: tr("media.search"),
                               customNav: [("import", tr("media.nav.import")), ("subprojects", tr("subprojects.nav"))],
                               customContent: { id in
                                   id == "subprojects" ? AnyView(SubprojectsView(store: store))   // TL-022
                                       : AnyView(MediaBinView(store: store, kinds: kinds, tab: tabID))
                               },
                               yoursGroup: tr("asset.nav.yours"),
                               header: { ClipSearchBanner(store: store) })   // AI-028: free-text search model offer
                // The library search also drives the AI smart search (AI-028): content / on-screen text / dialogue matches.
                .onValueChange(of: AssetPanelState.shared.query[tabID] ?? "") { _, q in store.setMediaQuery(q) }
            } else {
                MediaBinView(store: store, kinds: kinds, tab: tabID)   // inside the Audio browser (its search lists these too)
            }
        }
    }

    /// Bin media (hidden from the rail; searchable, favouritable) + the local stock library.
    var sections: [LibrarySection] {
        let used = store.usedMediaIDs
        // AI-028 smart search hits match the typed query even when the name doesn't (query added as a keyword).
        let q = store.ai.mediaQuery
        let smart = Set(store.smartSearchResults(store.mediaBin.media)?.map(\.id) ?? [])
        let bin = LibrarySection(id: "bin", title: tr("media.nav.import"), items: store.mediaBin.media.map { a in
                                     var i = MediaLibraryItems.item(a, store: store, used: used.contains(a.id))
                                     if smart.contains(a.id) { i.keywords.append(q) }
                                     return i
                                 },
                                 inRail: false)
        return [bin] + MediaLibraryItems.stockSections(store)
    }
}

/// Builds `LibraryItem`s for bin media and stock content.
@MainActor
enum MediaLibraryItems {
    static func favoriteID(_ a: MediaAsset) -> String { "bin." + a.contentHash }

    static func item(_ a: MediaAsset, store: EditorStore, used: Bool) -> LibraryItem {
        LibraryItem(id: favoriteID(a), title: a.name, keywords: [a.kind.rawValue, a.url.pathExtension],
                    badge: a.kind == .image ? nil : Timecode.shortDuration(a.duration),
                    art: a.kind == .audio
                        ? .async(key: MediaThumbs.posterKey(a), load: { await MediaThumbs.poster(a) }, placeholder: "waveform")
                        : .letterboxed(key: MediaThumbs.posterKey(a), load: { await MediaThumbs.poster(a) },
                                       placeholder: a.kind == .image ? "photo" : "film"),
                    hoverFrames: a.kind == .video ? { await MediaThumbs.filmstrip(a, count: 10) } : nil,
                    payload: DragPayload.media(a.id), added: used,
                    add: { [weak store] in store?.addToTimeline(a.id) })
    }
}


/// The project bin view (Import entry of the Media tab, and Audio ▸ Yours).
struct MediaBinView: View {
    @Perception.Bindable var store: EditorStore
    let kinds: Set<MediaKind>
    let tab: String
    @Perception.Bindable private var prefs = MediaBrowserPrefs.shared
    @State private var dropTargeted = false
    /// Open bin folder (nil = root). Folders are shown in the full Media tab only.
    @State private var folder: MediaFolderID?
    @State private var width: CGFloat = 300
    private var state: AssetPanelState { AssetPanelState.shared }

    var showsFolders: Bool { kinds.count == 3 }
    var currentFolder: MediaFolderID? { folder.flatMap { f in store.mediaBin.folders.contains { $0.id == f } ? f : nil } }

    var effectiveKinds: Set<MediaKind> {
        guard showsFolders else { return kinds }
        switch prefs.filter {
        case .all: return kinds
        case .video: return [.video]
        case .image: return [.image]
        case .audio: return [.audio]
        }
    }

    var items: [MediaAsset] {
        let k = effectiveKinds
        let base = store.mediaBin.media.filter { k.contains($0.kind) && (!showsFolders || $0.folderID == currentFolder) }
        // SE-010: Settings ▸ Project ▸ "Show media from subprojects" off hides media used only inside compounds
        let filtered = AppPreferences.shared.settings.showSubprojectMedia ? base : {
            let only = Subprojects.mediaOnlyInSubprojects(store.project)
            return base.filter { !only.contains($0.id) }
        }()
        return MediaSorting.sorted(filtered, by: prefs.sort, ascending: prefs.ascending)
    }
    var folders: [MediaFolder] { showsFolders && prefs.filter == .all ? BinOps.children(of: currentFolder, in: store.mediaBin) : [] }

    var body: some View {
        WithPerceptionTracking {
            let list = items
            let missing = Set(store.mediaBin.media.filter(store.isMissing).map(\.id))
            let used = store.usedMediaIDs
            VStack(spacing: 0) {
                if store.mediaBin.media.filter({ kinds.contains($0.kind) }).isEmpty {
                    dropZone
                } else {
                    toolbar(missing: missing.count)
                    if showsFolders && currentFolder == nil {   // CapCut's "All" caption over the grid
                        Text(loc: "media.filter.\(prefs.filter.rawValue)").font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.bottom, 6)
                    }
                    if showsFolders && currentFolder != nil { BinBreadcrumb(store: store, folder: $folder) }
                    ScrollView {
                        if !showsFolders {
                            // Audio ▸ Imported: the same 56 pt rows as the music / sound-effect libraries (UX_GAPS W8-1).
                            LazyVStack(spacing: 8) {
                                ForEach(Array(list.enumerated()), id: \.element.id) { i, a in
                                    WithPerceptionTracking {
                                        LibraryRow(tab: tab, namespace: "audio", item: audioRowItem(a, used: used.contains(a.id))).testID("media.card.\(i)")
                                    }
                                }
                            }
                            .padding(.horizontal, 12).padding(.bottom, 12)
                        } else if prefs.layout == .grid {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: columns), spacing: 12) {
                                ForEach(folders) { f in WithPerceptionTracking { FolderCard(store: store, folder: f, current: $folder) } }
                                ForEach(Array(list.enumerated()), id: \.element.id) { i, a in
                                    WithPerceptionTracking {
                                        MediaCard(store: store, asset: a, tab: tab, order: list, used: used.contains(a.id), missing: missing.contains(a.id),
                                                  cardWidth: cardWidth)
                                            .testID("media.card.\(i)")
                                    }
                                }
                            }
                            .padding(.horizontal, 12).padding(.bottom, 12)
                        } else {
                            LazyVStack(spacing: MediaRow.spacing) {
                                ForEach(folders) { f in WithPerceptionTracking { FolderCard(store: store, folder: f, current: $folder).frame(height: 60) } }
                                ForEach(Array(list.enumerated()), id: \.element.id) { i, a in
                                    WithPerceptionTracking {
                                        MediaRow(store: store, asset: a, tab: tab, order: list, used: used.contains(a.id), missing: missing.contains(a.id),
                                                 stripWidth: max(1, width - 24))
                                            .testID("media.card.\(i)")
                                    }
                                }
                            }
                            .padding(.horizontal, 12).padding(.bottom, 12)
                        }
                    }
                    .testID("media.grid")
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                loadURLs(providers) { store.importMedia($0, folder: showsFolders ? currentFolder : nil) }
                return true
            }
            .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 6).stroke(Theme.accent, lineWidth: 2).padding(4) } }
            .onAppear { register(list) }
            .onValueChange(of: list.map(\.id)) { register(list) }
            .onValueChange(of: columns) { register(list) }
        }
    }

    var columns: Int { prefs.layout == .list || !showsFolders ? 1 : MediaGrid.columns(width: width) }
    var cardWidth: CGFloat { max(1, (width - 24 - CGFloat(columns - 1) * 10) / CGFloat(columns)) }

    func audioRowItem(_ a: MediaAsset, used: Bool) -> LibraryItem {
        let id = "media.\(a.id)"
        let url = a.url
        return LibraryItem(id: id, title: a.name, subtitle: "\(a.url.pathExtension.uppercased()) · \(Timecode.shortDuration(a.duration))",
                           art: .async(key: MediaThumbs.posterKey(a), load: { await MediaThumbs.poster(a) }, placeholder: "waveform"),
                           payload: DragPayload.media(a.id), added: used, playing: LibraryAudioPreview.shared.playingID == id,
                           add: { [store] in store.addToTimeline(a.id) },
                           click: { LibraryAudioPreview.shared.toggle(id) { url } })
    }

    /// Keyboard navigation over the bin cards (ids = media ids).
    func register(_ list: [MediaAsset]) {
        state.layout[tab] = (list.map(\.id.description), columns)
        state.actions[tab] = (add: { [weak store] id in
            guard let store, let mid = MediaID(string: id) else { return }
            let sel = AssetPanelState.shared.mediaSelection
            store.addMediaToTimeline(sel.count > 1 && sel.contains(mid) ? sel : [mid])
        }, favorite: { [weak store] id in
            guard let store, let mid = MediaID(string: id), let a = store.project.asset(mid) else { return }
            AssetLibraryStore.shared.toggleFavorite("media", MediaLibraryItems.favoriteID(a))
        })
        state.visibleCount[tab] = list.count
        state.mediaSelection.removeAll { id in !store.mediaBin.media.contains { $0.id == id } }
    }

    func toolbar(missing: Int) -> some View {
        HStack(spacing: 6) {
            Button { ImportPanel.run(store) } label: {
                Label(tr("media.import"), systemImage: "plus").font(.system(size: 12))
            }
            .buttonStyle(SecondaryButtonStyle())
            .testID("media.import")
            if showsFolders {
                IconButton("folder.badge.plus", help: tr("media.folder.new")) { _ = store.createFolder(in: currentFolder) }
                    .testID("media.folder.new")
            }
            Spacer(minLength: 4)
            if missing > 0 {
                Button { LinkMediaPanel.runFolder(store) } label: {
                    Label(tr("media.missing", missing), systemImage: "exclamationmark.triangle").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(.orange).help(tr("media.linkFolder.message"))
            }
            if showsFolders {
                IconButton(prefs.layout == .grid ? "list.bullet" : "square.grid.2x2",
                           help: tr(prefs.layout == .grid ? "media.view.list" : "media.view.grid")) {
                    prefs.layout = prefs.layout == .grid ? .list : .grid
                }
                .testID("media.layout")
            }
            Menu {
                Picker(tr("media.sort"), selection: $prefs.sort) {
                    ForEach(MediaBrowserPrefs.Sort.allCases, id: \.self) { s in WithPerceptionTracking { Text(loc: "media.sort.\(s.rawValue)").tag(s) } }
                }
                .pickerStyle(.inline)
                Divider()
                Picker(tr("media.sort.order"), selection: $prefs.ascending) {
                    Text(loc: "media.sort.ascending").tag(true)
                    Text(loc: "media.sort.descending").tag(false)
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 12))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(tr("media.sort"))
            .testID("media.sort")
            if showsFolders {
                Menu {
                    Picker(tr("media.filter"), selection: $prefs.filter) {
                        ForEach(MediaBrowserPrefs.Filter.allCases, id: \.self) { f in WithPerceptionTracking { Text(loc: "media.filter.\(f.rawValue)").tag(f) } }
                    }
                    .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "line.3.horizontal.decrease").font(.system(size: 12))
                        Text(loc: "media.filter.\(prefs.filter.rawValue)").font(.system(size: 11))
                    }
                    .foregroundStyle(prefs.filter == .all ? Theme.textPrimary : Theme.accent)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(tr("media.filter"))
                .testID("media.filter")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "plus.circle").font(.system(size: 26)).foregroundStyle(Theme.textPrimary.opacity(0.8))
            Text(loc: "media.import").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
            Text(loc: "media.dropHint").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 6))
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture { ImportPanel.run(store) }
        .testID("media.dropzone")
        .safeAreaInset(edge: .bottom) { if kinds.contains(.video) { RecordTools(store: store) } }
    }
}

enum MediaSorting {
    static func sorted(_ items: [MediaAsset], by sort: MediaBrowserPrefs.Sort, ascending: Bool) -> [MediaAsset] {
        let indexed = Array(items.enumerated())
        func less(_ a: (offset: Int, element: MediaAsset), _ b: (offset: Int, element: MediaAsset)) -> Bool {
            switch sort {
            case .imported: return a.offset < b.offset
            case .name:
                let c = a.element.name.localizedStandardCompare(b.element.name)
                return c == .orderedSame ? a.offset < b.offset : c == .orderedAscending
            case .duration: return a.element.duration == b.element.duration ? a.offset < b.offset : a.element.duration < b.element.duration
            case .size: return a.element.fileSize == b.element.fileSize ? a.offset < b.offset : a.element.fileSize < b.element.fileSize
            case .type:
                let ka = kindOrder(a.element.kind), kb = kindOrder(b.element.kind)
                return ka == kb ? a.element.name.localizedStandardCompare(b.element.name) == .orderedAscending : ka < kb
            }
        }
        let s = indexed.sorted(by: less).map(\.element)
        return ascending ? s : s.reversed()
    }
    static func kindOrder(_ k: MediaKind) -> Int { k == .video ? 0 : (k == .image ? 1 : 2) }
}

/// Media grid geometry (C6-1): big CapCut-like tiles, about 3 per row at the default panel width (≈ 450 pt of grid),
/// the count following the panel width (rounded to the nearest count of ~140 pt tiles, so tiles stay ≈ 115–170 pt).
enum MediaGrid {
    static let targetTileWidth: CGFloat = 140
    static let spacing: CGFloat = 10
    static let inset: CGFloat = 12
    static func columns(width: CGFloat) -> Int {
        max(1, Int(((width - 2 * inset + spacing) / (targetTileWidth + spacing)).rounded()))
    }
    static func tileWidth(width: CGFloat) -> CGFloat {
        let n = CGFloat(columns(width: width))
        return max(1, (width - 2 * inset - (n - 1) * spacing) / n)
    }
}

/// Poster / filmstrip thumbnails of bin media (ThumbnailCache, waveform picture for audio).
@MainActor
enum MediaThumbs {
    /// Pixel height of media card pictures (poster + hover frames). Cards are drawn aspect-fit (letterboxed), so the
    /// frame height is the tile height: tiles are ≤ ~140 pt tall, × 2 on Retina ⇒ 288 px stays sharp (C3-3; was 96 px
    /// shown cropped-to-fill in a ~200 pt tile, i.e. upscaled ×4 and blurry).
    static let height = 288
    /// List-view filmstrip frames (C6-2): minimum pixel height of a strip frame (56 pt strip at 2×).
    static let rowHeight = 112

    /// Pixel height of strip frames: tiles are `MediaRow.stripHeight` tall and `stripTileAspect` wide, filled (cropped),
    /// at 2× (Retina); portrait sources cropped to squares need more source pixels. Rounded up to 16 px.
    static func stripFrameHeight(_ a: MediaAsset) -> Int {
        let px = 2 * MediaRow.stripHeight * max(1, stripTileAspect(a) / sourceAspect(a))
        return min(height, max(rowHeight, Int((px / 16).rounded(.up)) * 16))
    }
    static func sourceAspect(_ a: MediaAsset) -> CGFloat {
        a.pixelSize.width > 0 && a.pixelSize.height > 0 ? CGFloat(a.pixelSize.width / a.pixelSize.height) : 16 / 9
    }
    /// Width / height of one strip tile: the source aspect, portrait shown as squares (CapCut list view, screenshot 27).
    static func stripTileAspect(_ a: MediaAsset) -> CGFloat { min(16 / 9, max(1, sourceAspect(a))) }

    /// Source times of an n-tile strip: the middle of each tile's share of the duration.
    static func stripTimes(_ a: MediaAsset, count: Int) -> [Time] {
        let d = a.duration.seconds
        guard count > 0 else { return [] }
        guard a.kind == .video, d > 0 else { return Array(repeating: .zero, count: count) }
        return (0..<count).map { i in Time(min(max(0, d - 0.05), (Double(i) + 0.5) / Double(count) * d)) }
    }

    static func posterKey(_ a: MediaAsset, height: Int = height) -> String { "media.\(a.contentHash).\(height)" }

    static func posterTime(_ a: MediaAsset) -> Time { a.kind == .video ? Time(min(1, a.duration.seconds * 0.1)) : .zero }

    static func poster(_ a: MediaAsset, height: Int = height) async -> CGImage? {
        if a.kind == .audio { return await waveformImage(a) }
        let t = posterTime(a)
        if let c = ThumbnailCache.shared.cached(a, at: t, height: height) { return c }
        return await ThumbnailCache.shared.thumbnail(a, at: t, height: height)
    }

    /// Times sampled for hover scrubbing (count frames over the duration).
    static func scrubTime(_ a: MediaAsset, fraction: Double, count: Int = 20) -> Time {
        let d = a.duration.seconds
        guard d > 0 else { return .zero }
        let i = min(count - 1, max(0, Int(fraction * Double(count))))
        return Time(min(d - 0.05, (Double(i) + 0.5) / Double(count) * d))
    }

    static func filmstrip(_ a: MediaAsset, count: Int) async -> [CGImage] {
        var out: [CGImage] = []
        for i in 0..<count {
            let t = scrubTime(a, fraction: (Double(i) + 0.5) / Double(count), count: count)
            if let img = await ThumbnailCache.shared.thumbnail(a, at: t, height: height) { out.append(img) }
        }
        return out
    }

    /// Blue waveform picture for audio cards (UX.md §3.3).
    static func waveformImage(_ a: MediaAsset) async -> CGImage? {
        guard let w = await WaveformCache.shared.waveform(a) else { return nil }
        let d = a.duration.seconds
        let bars = 48
        let peaks = (0..<bars).map { i in w.peak(from: d * Double(i) / Double(bars), to: d * Double(i + 1) / Double(bars)) }
        return WaveformArt.image(peaks: peaks.map(Float.init), size: CGSize(width: 216, height: 144),
                                 background: RGBA(hex: 0x16314D), bar: RGBA(hex: 0x4FA3E0))
    }
}

/// Small CG drawings for audio art.
enum WaveformArt {
    static func image(peaks: [Float], size: CGSize, background: RGBA, bar: RGBA) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: background.r, green: background.g, blue: background.b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: bar.r, green: bar.g, blue: bar.b, alpha: 1))
        let n = max(1, peaks.count)
        let step = size.width / CGFloat(n)
        for (i, p) in peaks.enumerated() {
            let bh = max(2, CGFloat(min(1, max(0, p))) * size.height * 0.8)
            ctx.fill(CGRect(x: CGFloat(i) * step + step * 0.2, y: (size.height - bh) / 2, width: step * 0.6, height: bh))
        }
        return ctx.makeImage()
    }
}

/// Selection handling shared by cards and rows (click / ⌘ click / ⇧ click).
@MainActor
enum MediaSelection {
    static func click(_ a: MediaAsset, order: [MediaAsset], tab: String) {
        let state = AssetPanelState.shared
        let mods = AssetPanelFocus.lastClickModifiers
        var sel = state.mediaSelection
        if mods.contains(.command) {
            if let i = sel.firstIndex(of: a.id) { sel.remove(at: i) } else { sel.append(a.id) }
        } else if mods.contains(.shift), let anchorID = state.cursor[tab].flatMap(MediaID.init(string:)),
                  let i0 = order.firstIndex(where: { $0.id == anchorID }), let i1 = order.firstIndex(where: { $0.id == a.id }) {
            sel = order[min(i0, i1)...max(i0, i1)].map(\.id)
        } else {
            sel = [a.id]
        }
        state.mediaSelection = sel
        if !mods.contains(.shift) { state.cursor[tab] = a.id.description }
        state.keyboardTab = tab
    }

    /// Drag payload: the whole selection (in bin order) when the dragged card is part of it.
    static func payload(_ a: MediaAsset, order: [MediaAsset]) -> String {
        let sel = AssetPanelState.shared.mediaSelection
        guard sel.count > 1, sel.contains(a.id) else { return DragPayload.media(a.id) }
        return DragPayload.mediaList(order.map(\.id).filter(sel.contains))
    }
}

struct MediaCard: View {
    let store: EditorStore
    let asset: MediaAsset
    let tab: String
    let order: [MediaAsset]
    let used: Bool
    let missing: Bool
    /// Card width from the grid layout (no per-card geometry observer: keeps 1,000-item scrolling cheap).
    let cardWidth: CGFloat
    @State private var poster: CGImage?
    @State private var scrub: CGImage?
    @State private var scrubFraction: Double?
    @State private var hover = false
    @State private var showInfo = false
    private var state: AssetPanelState { AssetPanelState.shared }
    private var lib: AssetLibraryStore { AssetLibraryStore.shared }

    var selected: Bool { state.mediaSelection.contains(asset.id) }
    var isCursor: Bool { state.cursor[tab] == asset.id.description && state.keyboardTab == tab }
    /// Position in the shown list: the ☆ / ⊕ test IDs are per card (`media.card.<i>.favorite`), since the hovered card
    /// and the keyboard-cursor card both show them (one shared ID made a click resolve to either: FLAKY-UI2).
    /// Only evaluated while the buttons are shown.
    var cardIndex: Int { order.firstIndex { $0.id == asset.id } ?? -1 }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 4) {
                Color.clear
                    .aspectRatio(1.5, contentMode: .fit)
                    .overlay { picture }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topTrailing) {
                        if asset.kind != .image { DurationBadge(text: Timecode.shortDuration(asset.duration)) }
                    }
                    .overlay(alignment: .topLeading) { statusChip }
                    .overlay(alignment: .bottomTrailing) {
                        if hover || isCursor {
                            HStack(spacing: 4) {
                                let fid = MediaLibraryItems.favoriteID(asset)
                                let fav = lib.isFavorite("media", fid)
                                Button { lib.toggleFavorite("media", fid) } label: {
                                    Image(systemName: fav ? "star.fill" : "star").font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(fav ? Color(hex: 0xF5C451) : .white)
                                        .frame(width: 20, height: 20).background(.black.opacity(0.55), in: Circle())
                                }
                                .buttonStyle(.plain).help(tr(fav ? "asset.unfavorite" : "asset.favorite"))
                                .testID("media.card.\(cardIndex).favorite")
                                Button { store.addToTimeline(asset.id) } label: {
                                    Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                                        .frame(width: 20, height: 20).background(Theme.accent, in: Circle())
                                }
                                .buttonStyle(.plain).help(tr("asset.addToTrack"))
                                .testID("media.card.\(cardIndex).add")
                            }
                            .padding(4)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let f = scrubFraction, asset.kind != .image { HoverTimeBar(fraction: f) }
                    }
                    .overlay {
                        if missing {
                            ZStack {
                                Color.black.opacity(0.6)
                                Label(tr("media.lost"), systemImage: "exclamationmark.triangle.fill").font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .onTapGesture { LinkMediaPanel.run(store, asset) }
                            .help(tr("media.link"))
                        }
                    }
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 6).stroke(Theme.accent, lineWidth: 2)
                                .overlay(alignment: .leading) { handle }.overlay(alignment: .trailing) { handle }
                        } else if hover {
                            RoundedRectangle(cornerRadius: 6).stroke(Theme.accent.opacity(0.6), lineWidth: 1.5)
                        }
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            guard asset.kind != .image else { return }
                            let f = min(1, max(0, Double(p.x / max(1, cardWidth))))
                            if asset.kind == .video { updateScrub(f) } else { scrubFraction = f }
                        case .ended:
                            scrubFraction = nil; scrub = nil
                        }
                    }
                Text(verbatim: asset.name).font(.system(size: 11)).foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .contextMenu { MediaCardMenu(store: store, asset: asset, showInfo: $showInfo) }
            .popover(isPresented: $showInfo) { WithPerceptionTracking { MediaInfoView(asset: asset) } }
            .mediaTap(asset, store: store, order: order, tab: tab, width: cardWidth)
            .onDrag { NSItemProvider(object: MediaSelection.payload(asset, order: order) as NSString) }
            .task(id: asset.contentHash) {
                poster = LibraryArtCache.shared.get(MediaThumbs.posterKey(asset))
                if poster != nil { return }
                try? await Task.sleep(for: .milliseconds(40))     // skip cards flying past in a fast scroll
                guard !Task.isCancelled, let img = await MediaThumbs.poster(asset) else { return }
                LibraryArtCache.shared.set(MediaThumbs.posterKey(asset), img)
                poster = img
            }
        }
    }


    @ViewBuilder var picture: some View {
        ZStack {
            if asset.kind == .audio { Theme.inset } else { Color.black }   // letterbox (C3-3)
            if let img = scrub ?? poster {
                // Whole frame visible (aspect-fit) like CapCut; audio waveform art still fills.
                Image(decorative: img, scale: 2).resizable().interpolation(.high)
                    .aspectRatio(contentMode: asset.kind == .audio ? .fill : .fit)
            } else {
                Image(systemName: asset.kind == .audio ? "waveform" : (asset.kind == .image ? "photo" : "film"))
                    .font(.system(size: 20)).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    @ViewBuilder var statusChip: some View {
        if store.convertPending.contains(asset.contentHash) {
            ProgressView().controlSize(.mini).padding(4).help(tr("job.convert"))
        } else if store.proxyPending.contains(asset.contentHash) {
            ProgressView().controlSize(.mini).padding(4).help(tr("job.proxy"))
        } else if used {
            AddedChip()
        } else if asset.livePhotoVideoURL != nil {
            Text(loc: "media.livePhoto").font(.system(size: 9, weight: .semibold)).padding(.horizontal, 4).padding(.vertical, 1)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3)).padding(4)
        }
    }

    /// White pill handles on the selected card's edges (CapCut source in/out affordance).
    var handle: some View {
        Capsule().fill(.white).frame(width: 4, height: 18).padding(.horizontal, 1)
    }

    func updateScrub(_ f: Double) {
        scrubFraction = f
        let t = MediaThumbs.scrubTime(asset, fraction: f)
        if let c = ThumbnailCache.shared.cached(asset, at: t, height: MediaThumbs.height) { scrub = c; return }
        let a = asset
        Task {
            let img = await ThumbnailCache.shared.thumbnail(a, at: t, height: MediaThumbs.height)
            if scrubFraction != nil, let img, MediaThumbs.scrubTime(a, fraction: scrubFraction ?? 0) == t { scrub = img }
        }
    }
}

/// White vertical bar at the hovered time of a media card / strip (C6-3): a click there moves the preview to it.
struct HoverTimeBar: View {
    let fraction: Double
    var body: some View {
        WithPerceptionTracking {
            GeometryReader { g in
                WithPerceptionTracking {
                    Rectangle().fill(.white).frame(width: 1.5)
                        .shadow(color: .black.opacity(0.5), radius: 1)
                        .offset(x: min(g.size.width - 1.5, max(0, g.size.width * fraction - 0.75)))
                }
            }
            .allowsHitTesting(false)
        }
    }
}

extension View {
    /// Media card / row click (C6-3): select, then preview. A media already in the preview jumps to the clicked
    /// (= hovered) time; another media opens at its beginning. Double-click adds it to the timeline.
    func mediaTap(_ a: MediaAsset, store: EditorStore, order: [MediaAsset], tab: String, width: CGFloat) -> some View {
        let id = a.id.description
        return onTapGesture(coordinateSpace: .local) { p in
            let now = Date.timeIntervalSinceReferenceDate
            let isDouble = AssetTapTracker.lastID == id && now - AssetTapTracker.lastTime < NSEvent.doubleClickInterval
            AssetTapTracker.lastID = isDouble ? nil : id
            AssetTapTracker.lastTime = now
            MediaSelection.click(a, order: order, tab: tab)
            if AssetPanelFocus.lastClickModifiers.isEmpty {
                store.previewMedia(a.id, hoverTime: MediaRow.hoverTime(a, x: p.x, width: width))
            }
            if isDouble { store.addToTimeline(a.id) }
        }
    }
}

/// List-view row (C6-2, CapCut screenshot 27): a rounded filmstrip of frames across the panel width, duration top
/// right, file name below. Frames come lazily from `ThumbnailCache` (cached ones show at once, others fill in).
struct MediaRow: View {
    static let stripHeight: CGFloat = 56
    static let spacing: CGFloat = 12

    let store: EditorStore
    let asset: MediaAsset
    let tab: String
    let order: [MediaAsset]
    let used: Bool
    let missing: Bool
    /// Strip width from the list layout (no per-row geometry observer).
    let stripWidth: CGFloat
    @State private var frames: [Int: CGImage] = [:]
    @State private var hoverFraction: Double?
    @State private var hover = false
    @State private var showInfo = false
    private var state: AssetPanelState { AssetPanelState.shared }
    private var lib: AssetLibraryStore { AssetLibraryStore.shared }
    var selected: Bool { state.mediaSelection.contains(asset.id) }
    var isCursor: Bool { state.cursor[tab] == asset.id.description && state.keyboardTab == tab }
    /// See `MediaCard.cardIndex`.
    var cardIndex: Int { order.firstIndex { $0.id == asset.id } ?? -1 }

    /// Source time under x on a strip / card `width` wide (nil for still images).
    static func hoverTime(_ a: MediaAsset, x: CGFloat, width: CGFloat) -> Time? {
        guard a.kind != .image, a.duration.seconds > 0, width > 0 else { return nil }
        return Time(Double(min(1, max(0, x / width))) * a.duration.seconds)
    }

    /// Tiles across a strip: as many source-aspect tiles as fit, the last one cut by the rounded corner (CapCut).
    static func tileCount(_ a: MediaAsset, width: CGFloat) -> Int {
        a.kind == .audio ? 1 : max(1, Int((width / (stripHeight * MediaThumbs.stripTileAspect(a))).rounded(.up)))
    }

    var count: Int { Self.tileCount(asset, width: stripWidth) }
    var frameHeight: Int { MediaThumbs.stripFrameHeight(asset) }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 5) {
                strip
                    .frame(width: stripWidth, height: Self.stripHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topTrailing) {
                        if asset.kind != .image { DurationBadge(text: Timecode.shortDuration(asset.duration)) }
                    }
                    .overlay(alignment: .topLeading) {
                        if used { AddedChip() }
                    }
                    .overlay(alignment: .bottomTrailing) { if hover || isCursor { buttons } }
                    .overlay(alignment: .bottom) {
                        if let f = hoverFraction { HoverTimeBar(fraction: f) }
                    }
                    .overlay {
                        if missing {
                            ZStack {
                                Color.black.opacity(0.6)
                                Label(tr("media.lost"), systemImage: "exclamationmark.triangle.fill").font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .onTapGesture { LinkMediaPanel.run(store, asset) }
                            .help(tr("media.link"))
                        }
                    }
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 6).stroke(Theme.accent, lineWidth: 2)
                                .overlay(alignment: .leading) { handle }.overlay(alignment: .trailing) { handle }
                        } else if hover {
                            RoundedRectangle(cornerRadius: 6).stroke(Theme.accent.opacity(0.6), lineWidth: 1.5)
                        }
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): hoverFraction = asset.kind == .image ? nil : min(1, max(0, Double(p.x / stripWidth)))
                        case .ended: hoverFraction = nil
                        }
                    }
                Text(verbatim: asset.name).font(.system(size: 12)).foregroundStyle(missing ? .orange : (selected ? Theme.textPrimary : Theme.textSecondary))
                    .lineLimit(1).truncationMode(.middle)
            }
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .contextMenu { MediaCardMenu(store: store, asset: asset, showInfo: $showInfo) }
            .popover(isPresented: $showInfo) { WithPerceptionTracking { MediaInfoView(asset: asset) } }
            .mediaTap(asset, store: store, order: order, tab: tab, width: stripWidth)
            .onDrag { NSItemProvider(object: MediaSelection.payload(asset, order: order) as NSString) }
            .task(id: "\(asset.contentHash).\(count)") { await loadFrames() }
        }
    }

    @ViewBuilder var strip: some View {
        if asset.kind == .audio {
            ZStack {
                Theme.inset
                if let img = frames[0] { Image(decorative: img, scale: 2).resizable().interpolation(.high) }
                else { Image(systemName: "waveform").font(.system(size: 18)).foregroundStyle(Theme.textTertiary) }
            }
        } else {
            let tileW = Self.stripHeight * MediaThumbs.stripTileAspect(asset)
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { i in
                    WithPerceptionTracking {
                        ZStack {
                            Color.black
                            if let img = frames[i] ?? frames[asset.kind == .image ? 0 : -1] {
                                Image(decorative: img, scale: 2).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                            }
                        }
                        .frame(width: tileW, height: Self.stripHeight).clipped()
                        .overlay(alignment: .trailing) { Rectangle().fill(.black.opacity(0.35)).frame(width: 0.5) }
                    }
                }
            }
            .frame(width: stripWidth, alignment: .leading)
            .clipped()
        }
    }

    var buttons: some View {
        HStack(spacing: 4) {
            let fid = MediaLibraryItems.favoriteID(asset)
            let fav = lib.isFavorite("media", fid)
            Button { lib.toggleFavorite("media", fid) } label: {
                Image(systemName: fav ? "star.fill" : "star").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(fav ? Color(hex: 0xF5C451) : .white)
                    .frame(width: 20, height: 20).background(.black.opacity(0.55), in: Circle())
            }
            .buttonStyle(.plain).help(tr(fav ? "asset.unfavorite" : "asset.favorite"))
            .testID("media.card.\(cardIndex).favorite")
            Button { store.addToTimeline(asset.id) } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 20, height: 20).background(Theme.accent, in: Circle())
            }
            .buttonStyle(.plain).help(tr("asset.addToTrack"))
            .testID("media.card.\(cardIndex).add")
        }
        .padding(4)
    }

    var handle: some View { Capsule().fill(.white).frame(width: 4, height: 18).padding(.horizontal, 1) }

    /// Fills the strip: cached frames at once, the rest one by one (a fast scroll cancels the task).
    func loadFrames() async {
        let a = asset
        if a.kind == .audio {
            let key = "media.strip.\(a.contentHash).\(Int(stripWidth))"
            if let c = LibraryArtCache.shared.get(key) { frames = [0: c]; return }
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled, let w = await WaveformCache.shared.waveform(a) else { return }
            let d = a.duration.seconds
            let bars = max(8, Int(stripWidth / 4))
            let peaks = (0..<bars).map { i in Float(w.peak(from: d * Double(i) / Double(bars), to: d * Double(i + 1) / Double(bars))) }
            guard let img = WaveformArt.image(peaks: peaks, size: CGSize(width: stripWidth * 2, height: Self.stripHeight * 2),
                                              background: RGBA(hex: 0x16314D), bar: RGBA(hex: 0x4FA3E0)) else { return }
            LibraryArtCache.shared.set(key, img)
            frames = [0: img]
            return
        }
        let times = a.kind == .image ? [Time.zero] : MediaThumbs.stripTimes(a, count: count)
        let h = frameHeight
        var got: [Int: CGImage] = [:]
        for (i, t) in times.enumerated() { if let c = ThumbnailCache.shared.cached(a, at: t, height: h) { got[i] = c } }
        if let poster = LibraryArtCache.shared.get(MediaThumbs.posterKey(a)) { got[-1] = poster }   // placeholder for missing tiles
        frames = got
        if got.count >= times.count { return }
        try? await Task.sleep(for: .milliseconds(40))     // skip rows flying past in a fast scroll
        for (i, t) in times.enumerated() where frames[i] == nil {
            guard !Task.isCancelled else { return }
            if let img = await ThumbnailCache.shared.thumbnail(a, at: t, height: h) { frames[i] = img }
        }
    }
}

/// Audio tab (UX.md §3.4): local music library, sound effects, your audio, extracted audio, music folder.
struct AudioTab: View {
    let store: EditorStore
    var body: some View { WithPerceptionTracking { AudioLibraryTab(store: store) } }
}

enum ImportPanel {
    @MainActor static func run(_ store: EditorStore) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.allowedContentTypes = [.movie, .audio, .image, .folder, .font, .data]
        p.message = tr("media.importMessage")
        p.prompt = tr("media.import")
        if p.runModal() == .OK { store.importFiles(p.urls) }
    }
}

func loadURLs(_ providers: [NSItemProvider], _ done: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    let box = URLBox()
    for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { box.append(url) }
            group.leave()
        }
    }
    group.notify(queue: .main) { MainActor.assumeIsolated { done(box.urls) } }
}

nonisolated final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    func append(_ u: URL) { lock.withLock { _urls.append(u) } }
    var urls: [URL] { lock.withLock { _urls } }
}
