import Testing
import Foundation
import AppKit
import SwiftUI
import ValseCore
import ValseEffects
import ValseEngine
@testable import ValseUI
import ValseTestSupport

/// Effects / Filters / Adjustment asset tabs: catalogue (categories, curated lists, search, favourites), adding from
/// a card, and (VALSE_SNAPSHOT_DIR) offscreen PNGs of the three tabs with real thumbnails.
@MainActor @Suite(.serialized) struct EffectLibraryUITests {
    init() { ValseBootstrap.registerResources() }

    @Test func navHasFavoritesCuratedAndEveryGroup() {
        for cat in [EffectCategory.effect, .filter, .adjustment] {
            let nav = EffectLibraryCatalog.nav(cat).map(\.id)
            #expect(nav.first == EffectLibraryCatalog.favoritesNav)
            let groups = Set(EffectLibraryCatalog.items(cat).map(\.groupKey))
            #expect(groups.isSubset(of: Set(nav)), "\(cat): every group is reachable")
            // every entry is in exactly one group page
            let total = EffectLibraryCatalog.groups(cat).reduce(0) { $0 + EffectLibraryCatalog.entries(cat, nav: $1, favorites: []).count }
            #expect(total == EffectLibraryCatalog.items(cat).count)
        }
        let trending = EffectLibraryCatalog.entries(.effect, nav: EffectLibraryCatalog.curatedNav, favorites: [])
        #expect(trending.count == BuiltinEffects.trending.count)
        #expect(EffectLibraryCatalog.entries(.filter, nav: EffectLibraryCatalog.curatedNav, favorites: []).count == BuiltinFilters.featured.count)
        // built-in groups end with Body effects; FX-018 Custom (import / new effect) always comes last
        let fxGroups = EffectLibraryCatalog.groups(.effect).filter { $0.hasPrefix("effect.group.") }
        #expect(fxGroups.last == "effect.group.custom")
        #expect(fxGroups.dropLast().last == "effect.group.body")
    }

    @Test func searchMatchesNamesTagsAndFrenchWithoutAccents() {
        #expect(EffectLibraryCatalog.search(.effect, "vhs").contains { $0.id == "valse.effect.vhs" })
        #expect(EffectLibraryCatalog.search(.effect, "Snow").contains { $0.id == "valse.effect.snow" })
        #expect(EffectLibraryCatalog.search(.effect, "winter").contains { $0.id == "valse.effect.snow" })   // tag
        #expect(EffectLibraryCatalog.search(.filter, "teal").contains { $0.id == "valse.filter.tealOrange" })
        #expect(EffectLibraryCatalog.search(.effect, "zzzz-nothing").isEmpty)
        L10n.shared.setLanguageForSession("fr")
        defer { L10n.shared.setLanguageForSession("en") }
        #expect(EffectLibraryCatalog.search(.effect, "neige").contains { $0.id == "valse.effect.snow" })
        #expect(EffectLibraryCatalog.search(.effect, "seisme").contains { $0.id == "valse.effect.earthquake" })   // "Séisme"
        #expect(EffectLibraryCatalog.search(.filter, "heure doree").contains { $0.id == "valse.filter.goldenHour" })
    }

    @Test func stickerCatalogueGroupsAndSearch() {
        let groups = StickerCatalog.groups()
        #expect(groups.first == "sticker.group.emoji" && groups.contains("sticker.group.shapes"))
        let total = groups.reduce(0) { $0 + StickerCatalog.entries(nav: $1, favorites: []).count }
        #expect(total == Registries.stickers.all.filter { $0.groupKey != StickerCatalog.yoursNav }.count)   // + imported (Yours)
        #expect(StickerCatalog.search("heart").contains { $0.id == "valse.sticker.heartPink" })
        #expect(StickerCatalog.search("circle yellow").contains { $0.id == "valse.sticker.shape.circle.yellow" })
        L10n.shared.setLanguageForSession("fr")
        defer { L10n.shared.setLanguageForSession("en") }
        #expect(StickerCatalog.search("fleche").contains { $0.id == "valse.sticker.arrowRed" })
    }

    @Test func stickerRecentsAndSort() {
        let a = "valse.sticker.heartPink", b = "valse.sticker.arrowRed", c = "valse.sticker.shape.circle.yellow"
        #expect(StickerCatalog.entries(nav: StickerCatalog.recentNav, favorites: [], recents: [b, "gone", a]).map(\.id) == [b, a])
        #expect(StickerCatalog.nav().prefix(StickerCatalog.leadingNavCount).map(\.id).contains(StickerCatalog.recentNav))
        let items = [a, b, c].compactMap { Registries.stickers[$0] }
        #expect(StickerCatalog.sorted(items, by: .standard, favorites: [c], recents: [b]).map(\.id) == [a, b, c])
        #expect(StickerCatalog.sorted(items, by: .favorites, favorites: [c], recents: [b]).map(\.id) == [c, a, b])
        #expect(StickerCatalog.sorted(items, by: .recent, favorites: [c], recents: [c, b]).map(\.id) == [c, b, a])
    }

    @Test func favoritesToggleAndPersist() {
        let suite = "valse.test.favorites.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let f = EffectFavorites(defaults: defaults)
        f.toggle("valse.effect.vhs"); f.toggle("valse.filter.film400")
        #expect(f.contains("valse.effect.vhs"))
        let again = EffectFavorites(defaults: defaults)
        #expect(again.ids == ["valse.effect.vhs", "valse.filter.film400"])
        again.toggle("valse.effect.vhs")
        #expect(!EffectFavorites(defaults: defaults).contains("valse.effect.vhs"))
        let favPage = EffectLibraryCatalog.entries(.filter, nav: EffectLibraryCatalog.favoritesNav, favorites: again.ids)
        #expect(favPage.map(\.id) == ["valse.filter.film400"])
    }

    @Test func addingAnEffectCreatesAnEffectClipOrAppliesToTheSelection() async throws {
        var p = TestProject()
        let v = try await p.addVideo(.solid(.blue), seconds: 4)
        let s = EditorStore(project: p.project); s.autosaveEnabled = false
        s.applyEffect(Registries.effects["valse.effect.vhs"]!)
        let fxClip = s.project.timeline.tracks.flatMap(\.clips).first { $0.effects.first?.typeID == "valse.effect.vhs" }
        #expect(fxClip != nil && fxClip?.content == .adjustment)
        s.selection = [v]
        s.applyEffect(Registries.effects["valse.filter.film400"]!)
        #expect(s.project.timeline.clip(v)?.effects.contains { $0.typeID == "valse.filter.film400" } == true)
    }

    @Test func thumbnailsRenderOffMain() async throws {
        let d = Registries.effects["valse.effect.snow"]!
        let t = EffectThumbnails.shared
        _ = t.still(d)
        // waits are hang bounds (60 s), not speed budgets: the renders queue behind other work on a loaded machine
        for _ in 0..<1200 where t.still(d) == nil { try await Task.sleep(for: .milliseconds(50)) }
        let img = try #require(t.still(d))
        #expect(img.width == EffectThumbnails.pixels && img.height == EffectThumbnails.pixels)
        _ = t.loop(d)
        for _ in 0..<1200 where t.loop(d) == nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(t.loop(d)?.count == EffectThumbnails.frameCount)
    }

    @Test func renderSnapshots() async throws {
        guard let dir = ProcessInfo.processInfo.environment["VALSE_SNAPSHOT_DIR"] else { return }
        let lang = ProcessInfo.processInfo.environment["VALSE_SNAPSHOT_LANG"] ?? "en"
        L10n.shared.setLanguageForSession(lang)
        defer { L10n.shared.setLanguageForSession("en") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let s = EditorStore(project: Project(name: "Snap")); s.autosaveEnabled = false
        s.activeAssetTab = "stickers"
        try snapshot(AssetPanel(store: s), to: URL(fileURLWithPath: dir).appendingPathComponent("assets-stickers-\(lang).png"))
        for (tab, cat) in [("effects", EffectCategory.effect), ("filters", .filter), ("adjustment", .adjustment)] {
            // warm the thumbnails of the first page so the snapshot shows real renders
            let first = EffectLibraryCatalog.entries(cat, nav: EffectLibraryCatalog.nav(cat).dropFirst().first!.id, favorites: [])
            for d in first.prefix(24) { _ = EffectThumbnails.shared.still(d) }
            for _ in 0..<120 where first.prefix(24).contains(where: { EffectThumbnails.shared.still($0) == nil && $0.category != .adjustment }) {
                try await Task.sleep(for: .milliseconds(50))
            }
            s.activeAssetTab = tab
            try snapshot(AssetPanel(store: s), to: URL(fileURLWithPath: dir).appendingPathComponent("assets-\(tab)-\(lang).png"))
        }
    }

    func snapshot<V: View>(_ view: V, to url: URL, size: CGSize = CGSize(width: 560, height: 640)) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).preferredColorScheme(.dark))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
