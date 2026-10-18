import SwiftUI
import UniformTypeIdentifiers
import MontageCore
import MontageEffects
import MontageEngine
import MontageAI

/// Top-left asset panel: icon tab bar (icon over 11 pt label) + the active tab's content (AssetTabRegistry).
public struct AssetPanel: View {
    @Bindable var store: EditorStore
    public init(store: EditorStore) { self.store = store }

    public var body: some View {
        if store.ai.transcriptOpen { TranscriptPanel(store: store) } else { tabs }   // W10 transcript replaces the asset panel
    }

    var tabs: some View {
        Panel {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(AssetTabRegistry.sorted) { tab in
                        let active = store.activeAssetTab == tab.id
                        Button { store.activeAssetTab = tab.id } label: {
                            VStack(spacing: 3) {
                                Image(systemName: tab.symbol).font(.system(size: 16))
                                Text(loc: tab.titleKey).font(Theme.Fonts.tabLabel).lineLimit(1)
                            }
                            .foregroundStyle(active ? Theme.accent : Theme.textPrimary.opacity(0.85))
                            .frame(minWidth: 50).padding(.horizontal, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .testID("asset.tab.\(tab.id)")
                    }
                }
                .padding(.horizontal, 6)
            }
        } content: {
            (AssetTabRegistry.tabs.first { $0.id == store.activeAssetTab } ?? AssetTabRegistry.sorted[0]).content(store)
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { AssetPanelFocus.panelFrame = $0 }
        .onAppear { AssetPanelFocus.install() }
    }
}

/// Clicking outside the asset panel hands the arrow keys back to the timeline / player (W13 keyboard navigation).
@MainActor
enum AssetPanelFocus {
    /// Panel frame in window content coordinates (top-left origin).
    static var panelFrame: CGRect = .zero
    /// Modifiers of the last mouse-down (SwiftUI tap actions run after the event; ⌘ / ⇧ multi-select reads these).
    static var lastClickModifiers: NSEvent.ModifierFlags = []
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { e in
            let box = UncheckedSendable(e)
            MainActor.assumeIsolated {
                let e = box.value
                lastClickModifiers = e.modifierFlags.intersection([.command, .shift, .option, .control])
                guard let host = e.window?.contentView else { return }
                let p = e.locationInWindow
                let pt = CGPoint(x: p.x, y: host.bounds.height - p.y)
                if !panelFrame.contains(pt) { AssetPanelState.shared.keyboardTab = nil }
            }
            return e
        }
    }
}

/// Drag payloads understood by the timeline (plain strings so SwiftUI ↔ AppKit interop is trivial).
public enum DragPayload {
    public static func media(_ id: MediaID) -> String { "montage-media:\(id.raw.uuidString)" }
    public static func effect(_ id: String) -> String { "montage-effect:\(id)" }
    public static func transition(_ id: String) -> String { "montage-transition:\(id)" }
    public static func sticker(_ id: String) -> String { "montage-sticker:\(id)" }
    public static func textStyle(_ id: String) -> String { "montage-text:\(id)" }

    public enum Parsed { case media(MediaID), effect(String), transition(String), sticker(String), text(String) }
    public static func parse(_ s: String) -> Parsed? {
        let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "montage-media": return MediaID(string: parts[1]).map(Parsed.media)
        case "montage-effect": return .effect(parts[1])
        case "montage-transition": return .transition(parts[1])
        case "montage-sticker": return .sticker(parts[1])
        case "montage-text": return .text(parts[1])
        default: return nil
        }
    }
}

/// Built-in asset tabs. Add a tab: one `AssetTab` here (or `AssetTabRegistry.register` from a feature module).
@MainActor
enum BuiltinAssetTabs {
    static let all: [AssetTab] = [
        AssetTab(id: "media", titleKey: "tab.media", symbol: "photo.on.rectangle", order: 0) { AnyView(MediaTab(store: $0)) },
        AssetTab(id: "audio", titleKey: "tab.audio", symbol: "music.note", order: 1) { AnyView(AudioTab(store: $0)) },
        AssetTab(id: "text", titleKey: "tab.text", symbol: "textformat", order: 2) { AnyView(TextAssetTab(store: $0)) },
        AssetTab(id: "stickers", titleKey: "tab.stickers", symbol: "face.smiling", order: 3) { store in
            AnyView(StickerLibraryTab(store: store))
        },
        AssetTab(id: "effects", titleKey: "tab.effects", symbol: "sparkles", order: 4) { store in
            AnyView(EffectLibraryTab(store: store, category: .effect).id(EffectCategory.effect))
        },
        AssetTab(id: "transitions", titleKey: "tab.transitions", symbol: "square.split.2x1", order: 5) { store in
            AnyView(TransitionsTab(store: store))   // W5: MontageUI/Transitions
        },
        AssetTab(id: "filters", titleKey: "tab.filters", symbol: "camera.filters", order: 7) { store in
            AnyView(EffectLibraryTab(store: store, category: .filter).id(EffectCategory.filter))
        },
        AssetTab(id: "adjustment", titleKey: "tab.adjustment", symbol: "slider.horizontal.3", order: 8) { store in
            AnyView(EffectLibraryTab(store: store, category: .adjustment).id(EffectCategory.adjustment))
        },
        AssetTab(id: "templates", titleKey: "tab.templates", symbol: "rectangle.stack", order: 9) { AnyView(TemplatesTab(store: $0)) },
    ]

    static func grouped<T>(_ items: [T], _ key: KeyPath<T, String>) -> [(String, [T])] {
        var order: [String] = []
        var map: [String: [T]] = [:]
        for i in items {
            let k = i[keyPath: key]
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(i)
        }
        return order.map { ($0, map[$0]!) }
    }
}

/// Generic library grid with a left sub-nav of groups (CapCut asset tabs).
struct RegistryGrid<Item>: View {
    struct Tile: Identifiable {
        let id: String
        let title: String
        let symbol: String?
        var emoji: String? = nil
        /// Rendered picture (animated stickers' still), shown instead of the symbol.
        var image: CGImage? = nil
        let payload: String
        let add: () -> Void
    }
    let store: EditorStore
    let groups: [(String, [Item])]
    let tile: (Item) -> Tile
    @State private var group: String = ""

    /// W13: rendered by the shared `LibraryBrowser` (Favorites · Recent · groups, search, keyboard, ☆ / ⊕).
    var body: some View {
        let tab = store.activeAssetTab
        LibraryBrowser(tab: tab, namespace: tab, sections: groups.map { g in
            LibrarySection(id: g.0, title: tr(g.0), items: g.1.map(tile).map { t in
                LibraryItem(id: t.id, title: t.title, keywords: [tr(g.0)],
                            art: t.emoji.map { .emoji($0) } ?? .symbol(t.symbol ?? "sparkles"), payload: t.payload, add: t.add)
            })
        })
    }
}

struct AssetTile<Item>: View {
    let tile: RegistryGrid<Item>.Tile
    @State private var hover = false
    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 6).fill(Theme.segmentSelected)
                    .overlay {
                        if let img = tile.image { Image(decorative: img, scale: 2).resizable().aspectRatio(contentMode: .fit).padding(10) }
                        else if let e = tile.emoji { Text(verbatim: e).font(.system(size: 34)) }
                        else if let s = tile.symbol { Image(systemName: s).font(.system(size: 24)).foregroundStyle(Theme.textPrimary.opacity(0.85)) }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(hover ? Theme.accent : .clear, lineWidth: 1.5))
                if hover {
                    Button(action: tile.add) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 20, height: 20).background(Theme.accent, in: Circle())
                    }
                    .buttonStyle(.plain).padding(4).help(tr("asset.addToTrack"))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            Text(verbatim: tile.title).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
        }
        .onHover { hover = $0 }
        .onTapGesture(count: 2, perform: tile.add)
        .onDrag { NSItemProvider(object: tile.payload as NSString) }
    }
}

/// Left sub-navigation column of an asset tab (selected item: accent.dim background).
struct SubNav: View {
    let items: [(id: String, title: String)]
    @Binding var selection: String
    var body: some View {
        // UX.md §3.1: 120 pt column, 9 pt padding, 28 pt items (13 pt; selected = accent on accent.dim). Scrolls when the
        // category list is taller than the panel (Effects has ~20 groups).
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items, id: \.id) { item in
                    Button { selection = item.id } label: {
                        Text(verbatim: item.title)
                            .font(.system(size: 13))
                            .foregroundStyle(selection == item.id ? Theme.accent : Theme.textPrimary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).frame(height: 28)
                            .background(selection == item.id ? Theme.accentDim.opacity(0.45) : .clear, in: RoundedRectangle(cornerRadius: 4))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(item.title)
                    .testID("asset.nav.\(item.id)")
                }
            }
            .padding(9)
        }
        .scrollIndicators(.never)
        .frame(width: 120)
        .background(Theme.panel)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.separator).frame(width: 1) }
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(Theme.textTertiary)
            Text(verbatim: title).font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}

// Text tab content: MontageUI/Text/TextAssetTab.swift (text engine, W7).

/// Captions tab: Auto captions (on-device speech recognition) — W10, MontageUI/AI/AutoCaptionsPanel.swift.
struct CaptionsTab: View {
    let store: EditorStore
    var body: some View { AutoCaptionsPanel(store: store) }
}
