import Testing
import Foundation
import MontageCore
import MontageEngine
@testable import MontageUI

/// Every dynamic key of the built-in music library is localized in en and fr.
@MainActor struct MusicLibraryStringsTests {
    @Test func musicLibraryKeysAreLocalized() {
        MontageBootstrap.registerResources()
        let keys = MusicLibrary.all.map(\.nameKey) + MusicLibrary.genres.map { "music.genre.\($0)" } + MusicLibrary.moods.map { "music.mood.\($0)" }
        let en = L10n.shared.keys(for: "en"), fr = L10n.shared.keys(for: "fr")
        let missing = Set(keys).filter { !en.contains($0) || !fr.contains($0) }.sorted()
        #expect(missing.isEmpty, "missing: \(missing)")
    }
}
