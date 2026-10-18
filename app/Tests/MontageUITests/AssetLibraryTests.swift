import Testing
import Foundation
import AppKit
import MontageCore
import MontageEffects
import MontageEngine
@testable import MontageUI
import MontageTestSupport

/// W13 shared asset-panel logic: favourites / recents, search, sorting, payloads, multi-add, keyboard navigation,
/// template filters, the "Previewing —" player mode and localization of dynamic keys.
@MainActor @Suite(.serialized) struct AssetLibraryTests {
    func defaults() -> UserDefaults {
        let name = "montage.tests.assets.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func favoritesAndRecentsPersistPerNamespace() {
        let d = defaults()
        let lib = AssetLibraryStore(defaults: d)
        lib.toggleFavorite("media", "a")
        lib.toggleFavorite("media", "b")
        lib.toggleFavorite("audio", "a")
        #expect(lib.favoriteIDs("media") == ["b", "a"])          // most recently starred first
        lib.toggleFavorite("media", "b")
        #expect(lib.favoriteIDs("media") == ["a"] && lib.isFavorite("audio", "a") && !lib.isFavorite("audio", "b"))
        for i in 0..<40 { lib.noteUsed("stock", "i\(i)") }
        lib.noteUsed("stock", "i5")
        #expect(lib.recentIDs("stock").count == AssetLibraryStore.maxRecents && lib.recentIDs("stock").first == "i5")
        let reloaded = AssetLibraryStore(defaults: d)
        #expect(reloaded.favoriteIDs("media") == ["a"] && reloaded.recentIDs("stock").first == "i5")
    }

    @Test func searchIsCaseDiacriticInsensitiveAndAllTerms() {
        let item = LibraryItem(id: "x", title: "Été lumineux", subtitle: "Montage · Joyeux", keywords: ["summer", "bright"],
                               art: .symbol("sun.max"), add: {})
        #expect(LibrarySearch.matches(item, "ete"))
        #expect(LibrarySearch.matches(item, "LUMI summer"))
        #expect(!LibrarySearch.matches(item, "summer dark"))
        #expect(LibrarySearch.matches(item, "  "))
        let a = LibrarySection(id: "a", title: "A", items: [item])
        let b = LibrarySection(id: "b", title: "B", items: [item, LibraryItem(id: "y", title: "Night", art: .symbol("moon"), add: {})])
        #expect(LibrarySearch.results([a, b], "").map(\.id) == ["x", "y"])   // de-duplicated
        #expect(LibrarySearch.results([a, b], "night").map(\.id) == ["y"])
    }

    func asset(_ name: String, _ kind: MediaKind, _ seconds: Double, _ size: Int64) -> MediaAsset {
        MediaAsset(name: name, kind: kind, url: URL(fileURLWithPath: "/tmp/\(name)"), duration: Time(seconds), pixelSize: Size2(16, 9),
                   frameRate: nil, hasVideo: kind != .audio, hasAudio: kind == .audio, contentHash: name, fileSize: size)
    }

    @Test func mediaSorting() {
        let items = [asset("b10", .video, 5, 300), asset("a", .audio, 2, 100), asset("b2", .image, 0, 200)]
        #expect(MediaSorting.sorted(items, by: .imported, ascending: true).map(\.name) == ["b10", "a", "b2"])
        #expect(MediaSorting.sorted(items, by: .name, ascending: true).map(\.name) == ["a", "b2", "b10"])   // natural order
        #expect(MediaSorting.sorted(items, by: .duration, ascending: false).map(\.name) == ["b10", "a", "b2"])
        #expect(MediaSorting.sorted(items, by: .size, ascending: true).map(\.name) == ["a", "b2", "b10"])
        #expect(MediaSorting.sorted(items, by: .type, ascending: true).map(\.name) == ["b10", "b2", "a"])
    }

    @Test func mediaListPayloadRoundTrip() {
        let ids = [MediaID(), MediaID(), MediaID()]
        #expect(DragPayload.parseMediaList(DragPayload.mediaList(ids)) == ids)
        #expect(DragPayload.parseMediaList(DragPayload.media(ids[0])) == nil)
        #expect(DragPayload.parse(DragPayload.mediaList(ids)) == nil)    // the timeline's native parser ignores it
    }

    func storeWithMedia() async throws -> EditorStore {
        let s = EditorStore()
        s.autosaveEnabled = false
        var p = Project()
        let urls = [try await TestMedia.video(.solid(.red), seconds: 1), try await TestMedia.video(.solid(.blue), seconds: 2)]
        p.media = await MediaProbe.probeAll(urls).0
        s.load(project: p)
        return s
    }

    @Test func multiMediaDropAddsClipsInOrder() async throws {
        let s = try await storeWithMedia()
        let ids = s.project.media.map(\.id)
        #expect(s.handleLibraryDrop(DragPayload.mediaList(ids), at: .zero, target: .automatic))
        let main = try #require(s.project.timeline.mainTrack)
        #expect(main.clips.map(\.mediaID) == ids)
        #expect(abs(main.clips[1].start.seconds - 1) < 0.01)
        #expect(s.selection.count == 2)
        #expect(s.dropPreviewDuration(DragPayload.mediaList(ids)).map { abs($0.seconds - 3) < 0.01 } == true)
        #expect(!s.handleLibraryDrop("montage-unknown:1", at: .zero, target: .automatic))
        #expect(s.usedMediaIDs == Set(ids))
    }

    @Test func keyboardNavigationMovesCursorAndAdds() {
        let st = AssetPanelState()
        var added: [String] = []
        st.layout["t"] = (["a", "b", "c", "d", "e"], 2)
        st.actions["t"] = (add: { added.append($0) }, favorite: nil)
        #expect(!st.handleKey(.right, modifiers: []))          // no focus → arrows belong to the timeline
        st.keyboardTab = "t"
        #expect(st.handleKey(.right, modifiers: []) && st.cursor["t"] == "a")
        _ = st.handleKey(.down, modifiers: [])
        #expect(st.cursor["t"] == "c")
        _ = st.handleKey(.right, modifiers: [])
        _ = st.handleKey(.down, modifiers: [])
        #expect(st.cursor["t"] == "e")
        _ = st.handleKey(.down, modifiers: [])
        #expect(st.cursor["t"] == "e")                         // clamped
        #expect(st.handleKey(.char("\r"), modifiers: []) && added == ["e"])
        #expect(!st.handleKey(.left, modifiers: .command))     // ⌘← stays a shortcut
        _ = st.handleKey(.escape, modifiers: [])
        #expect(st.keyboardTab == nil)
    }

    @Test func templateFilters() {
        let t = TemplateDescriptor(id: "t", nameKey: "x", categoryKey: "template.cat.vlog", aspect: 9.0 / 16, clipCount: 3, duration: Time(20),
                                   cover: { nil }, apply: { _ in })
        #expect(TemplateLibrary.matches(t, .portrait, .few, .medium))
        #expect(!TemplateLibrary.matches(t, .landscape, .any, .any))
        #expect(!TemplateLibrary.matches(t, .all, .one, .any))
        #expect(!TemplateLibrary.matches(t, .all, .any, .long))
    }

    @Test func libraryPreviewLeavesTimelineUntouched() async throws {
        let s = try await storeWithMedia()
        let id = s.project.media[1].id
        s.addToTimeline(s.project.media[0].id, at: .zero)
        s.seek(to: Time(0.5)); s.transport.playhead = Time(0.5)
        let before = s.project
        s.previewMedia(id)
        #expect(s.isPreviewing && s.playerUI.preview?.kind == .video)
        #expect(abs((s.playerUI.preview?.range.duration.seconds ?? 0) - 2) < 0.05)
        #expect(s.project == before && abs(s.transport.playhead.seconds - 0.5) < 0.001)
        s.exitPreview()
        #expect(!s.isPreviewing && abs(s.transport.playhead.seconds - 0.5) < 0.001)

        // W13 extras on W2's preview mode: stock recipe, transition at the nearest cut
        s.previewStock(try #require(StockLibrary["gradient.lavender"]))
        #expect(s.playerUI.preview?.kind == .library && s.project == before)
        s.addToTimeline(id)                                    // any edit returns to the timeline
        #expect(!s.isPreviewing)
        s.previewTransition(try #require(Registries.transitions.all.first))
        #expect(s.playerUI.preview?.kind == .transition)
        let rng = try #require(s.playerUI.preview?.range)
        #expect(rng.duration.seconds > 0.5 && rng.end <= s.project.duration)   // ±1 s around a main-track cut
        s.exitPreview()

        s.previewEffect(try #require(Registries.effects(in: .effect).first))
        #expect(s.playerUI.preview?.kind == .effect)
        s.exitPreview()
    }

    @Test func dynamicKeysAreLocalized() {
        var keys = MediaBrowserPrefs.Sort.allCases.map { "media.sort.\($0.rawValue)" }
            + MediaBrowserPrefs.Filter.allCases.map { "media.filter.\($0.rawValue)" }
            + TemplateLibrary.Orientation.allCases.map { "templates.filter.orientation.\($0.rawValue)" }
            + TemplateLibrary.Clips.allCases.map { "templates.filter.clips.\($0.rawValue)" }
            + TemplateLibrary.Length.allCases.map { "templates.filter.duration.\($0.rawValue)" }
            + TemplateLibrary.categories
        keys += ["video", "image", "audio", "effect", "filter", "sticker", "text", "library", "transition"].map { "player.preview.kind.\($0)" }
        keys += StockLibrary.categories.map { "library.cat.\($0)" }
        for lang in ["en", "fr"] {
            L10n.shared.setLanguageForSession(lang)
            for k in keys { #expect(tr(k) != k, "\(k) missing in \(lang)") }
        }
        L10n.shared.setLanguageForSession("en")
    }
}
