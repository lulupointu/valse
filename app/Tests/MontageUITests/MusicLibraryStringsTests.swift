import Testing
import Foundation
import MontageCore
import MontageEngine
@testable import MontageUI

/// Every dynamic key of the built-in music libraries (generated + bundled CC0 library) is localized in en and fr.
@MainActor struct MusicLibraryStringsTests {
    @Test func musicLibraryKeysAreLocalized() {
        MontageBootstrap.registerResources()
        let keys = MusicLibrary.all.map(\.nameKey) + MusicLibrary.genres.map { "music.genre.\($0)" } + MusicLibrary.moods.map { "music.mood.\($0)" }
        let en = L10n.shared.keys(for: "en"), fr = L10n.shared.keys(for: "fr")
        let missing = Set(keys).filter { !en.contains($0) || !fr.contains($0) }.sorted()
        #expect(missing.isEmpty, "missing: \(missing)")
    }

    @Test func contentLibraryKeysAreLocalized() {
        MontageBootstrap.registerResources()
        let items = ContentLibrary.items
        var keys = ContentLibrary.musicCategories.map { "music.cat.\($0)" } + ["music.cat.generated"]
            + ContentLibrary.sfxCategories.map { "sfx.category.\($0)" } + ContentLibrary.moods.map { "music.mood.\($0)" }
        keys += items.compactMap(\.name).map { "sfx.n.\($0)" }
        keys += items.compactMap(\.mood).map { "music.mood.\($0)" }
        let en = L10n.shared.keys(for: "en"), fr = L10n.shared.keys(for: "fr")
        let missing = Set(keys).filter { !en.contains($0) || !fr.contains($0) }.sorted()
        #expect(missing.isEmpty, "missing: \(missing)")
        // sound effect titles are localized ("Clic 3"), music titles are proper names
        if let click = items.first(where: { $0.name == "click" && $0.n != nil }) {
            #expect(AudioLibrarySections.title(click).hasSuffix(" \(click.n!)"))
        }
        #expect(AudioLibrarySections.keyName(9, minor: true).contains("A") || AudioLibrarySections.keyName(9, minor: true).contains("La"))
    }
}
