import Testing
import Foundation
import ValseCore
@testable import ValseEngine
@testable import ValseUI

/// Audio ▸ Online state machine with mocked providers (no network, no Keychain): setup state without keys,
/// results once a key is saved, offline / bad-key states, provider interleaving, "For you" taste from saved tracks.
@MainActor @Suite(.serialized) struct OnlineAudioStateTests {
    func make() -> (OnlineAudioState, MockOnlineAudioHTTP) {
        let http = MockOnlineAudioHTTP(directory: FileManager.default.temporaryDirectory.appendingPathComponent("valse-online-ui-\(UUID().uuidString)"))
        return (OnlineAudioState(http: http, secrets: MemorySecretStore()), http)
    }

    func settle(_ s: OnlineAudioState) async {
        for _ in 0..<3000 where s.phase == .loading { try? await Task.sleep(for: .milliseconds(10)) }   // hang bound (load)
    }

    @Test func noKeyShowsSetupAndMakesNoRequest() async {
        let (s, http) = make()
        s.load(nav: OnlineAudioState.navForYou, text: "")
        #expect(s.phase == .noKey)
        #expect(http.requests.isEmpty, "no key → no network")
        s.enabled = false
        s.load(nav: OnlineAudioState.navForYou, text: "")
        #expect(s.phase == .disabled)
    }

    @Test func savedKeyLoadsInterleavedResults() async {
        let (s, http) = make()
        s.setKey("K", for: "freesound")
        s.setKey("C", for: "jamendo")
        s.load(nav: OnlineAudioState.navTrending, text: "")
        await settle(s)
        #expect(s.phase == .loaded)
        #expect(s.results.count >= 10)
        #expect(Set(s.results.prefix(2).map(\.provider)) == ["freesound", "jamendo"], "providers interleaved")
        #expect(s.results.allSatisfy { $0.kind == .music })
        // cached for the same query: no new request
        let n = http.requests.count
        s.load(nav: OnlineAudioState.navTrending, text: "")
        #expect(http.requests.count == n && s.phase == .loaded)
        // sound effects only ask Freesound
        s.load(nav: OnlineAudioState.navSFX, text: "pop")
        await settle(s)
        #expect(s.results.allSatisfy { $0.provider == "freesound" && $0.kind == .sfx })
        #expect(s.lastQuery?.mode == .search)
    }

    @Test func offlineAndBadKeyStates() async {
        let (s, _) = make()
        s.setKey("offline", for: "freesound")
        s.load(nav: OnlineAudioState.navSFX, text: "")
        await settle(s)
        #expect(s.phase == .offline)
        s.setKey("bad", for: "freesound")
        s.load(nav: OnlineAudioState.navSFX, text: "")
        await settle(s)
        #expect(s.phase == .invalidKey("Freesound"))
        // one provider failing while the other answers: results + a warning
        s.setKey("C", for: "jamendo")
        s.load(nav: OnlineAudioState.navGenres, text: "")
        await settle(s)
        #expect(s.phase == .loaded && !s.results.isEmpty && s.warnings.count == 1)
    }

    @Test func forYouUsesTheTasteOfSavedTracks() async {
        let (s, _) = make()
        s.setKey("C", for: "jamendo")
        s.load(nav: OnlineAudioState.navTrending, text: "")
        await settle(s)
        let ids = s.results.prefix(2).map(OnlineAudioState.rowID)
        s.keepSaved(ids)
        #expect(s.saved.count == 2)
        #expect(s.forYouTags().contains("pop"))
        let q = s.query(nav: OnlineAudioState.navForYou, text: "")
        #expect(q.mode == .featured && q.boost.contains("pop"))
        #expect(s.query(nav: OnlineAudioState.navMoods, text: "").mode == .mood(s.mood))
    }

    @Test func onlineStringsAreLocalized() {
        ValseBootstrap.registerResources()
        var keys = OnlineAudioCatalog.genres.map { "online.genre.\($0)" } + OnlineAudioCatalog.moods.map { "music.mood.\($0)" }
        keys += OnlineAudioProviders.all.map { "settings.music.provider.\($0.id)" }
        keys += SettingsTab.allCases.map(\.nameKey)
        keys += ["audio.license.creditShort", "audio.license.creditTitle", "audio.license.creditBody",
                 "settings.music.key.replace", "settings.music.key.placeholder", "settings.music.key.saved", "settings.music.key.none"]
        let en = L10n.shared.keys(for: "en"), fr = L10n.shared.keys(for: "fr")
        let missing = Set(keys).filter { !en.contains($0) || !fr.contains($0) }.sorted()
        #expect(missing.isEmpty, "missing: \(missing)")
    }
}
