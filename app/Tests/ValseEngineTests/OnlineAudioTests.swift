import Testing
import Foundation
import ValseCore
@testable import ValseEngine

/// Online music / SFX search (AU-001 / AU-002): license policy, provider requests + parsing, error mapping, download
/// cache + license sidecar — all against `MockOnlineAudioHTTP` (no network). `liveSearch` is opt-in:
/// VALSE_LIVE_FREESOUND_KEY / VALSE_LIVE_JAMENDO_KEY.
@Suite(.serialized) struct OnlineAudioTests {
    static func mock() -> MockOnlineAudioHTTP {
        MockOnlineAudioHTTP(directory: FileManager.default.temporaryDirectory.appendingPathComponent("valse-online-test-\(UUID().uuidString)"))
    }

    @Test func licensePolicyKeepsOnlySocialSafeLicenses() {
        #expect(OnlineLicensePolicy.classify("http://creativecommons.org/publicdomain/zero/1.0/")?.level == .publicDomain)
        #expect(OnlineLicensePolicy.classify("https://creativecommons.org/publicdomain/zero/1.0/legalcode")?.id == "CC0-1.0")
        #expect(OnlineLicensePolicy.classify("https://creativecommons.org/publicdomain/mark/1.0/")?.id == "PDM-1.0")
        #expect(OnlineLicensePolicy.classify("Creative Commons 0")?.id == "CC0-1.0")
        let by = OnlineLicensePolicy.classify("http://creativecommons.org/licenses/by/3.0/")
        #expect(by?.id == "CC-BY-3.0" && by?.requiresAttribution == true)
        #expect(OnlineLicensePolicy.classify("https://www.creativecommons.org/licenses/by/4.0")?.id == "CC-BY-4.0")
        for rejected in ["http://creativecommons.org/licenses/by-nc/3.0/", "http://creativecommons.org/licenses/by-sa/4.0/",
                         "http://creativecommons.org/licenses/by-nd/4.0/", "http://creativecommons.org/licenses/by-nc-sa/3.0/",
                         "Sampling+", "Attribution NonCommercial", "https://example.org/license", "",
                         "http://creativecommons.org/licenses/sampling+/1.0/"] {
            #expect(OnlineLicensePolicy.classify(rejected) == nil, "\(rejected) must be rejected")
        }
    }

    @Test func freesoundRequestFiltersLicensesAndParses() async throws {
        let p = FreesoundProvider()
        let q = OnlineAudioQuery(kind: .sfx, mode: .category("transition"))
        let r = p.request(q, key: "K")
        let items = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems!
        func v(_ n: String) -> String? { items.first { $0.name == n }?.value }
        #expect(r.url!.host == "freesound.org" && r.url!.absoluteString.hasPrefix("https://freesound.org/apiv2/search/?"))
        #expect(v("token") == "K")
        #expect(v("filter")!.contains(#"license:("Creative Commons 0" OR "Attribution")"#))
        #expect(v("filter")!.contains("duration:[0 TO 30]"))
        #expect(v("query") == "whoosh")
        #expect(v("fields")!.contains("previews"))
        let music = p.request(OnlineAudioQuery(kind: .music, mode: .trending), key: "K")
        #expect(music.url!.absoluteString.contains("tag%3Amusic") || music.url!.query!.contains("tag:music"))

        let http = Self.mock()
        let res = try await p.search(OnlineAudioQuery(kind: .sfx, mode: .search, text: "pop"), key: "K", http: http)
        #expect(!res.isEmpty)
        // the mock mixes NC / Sampling+ items in: the parser drops them
        #expect(res.allSatisfy { ["CC0-1.0", "CC-BY-4.0"].contains($0.license.id) })
        #expect(res.count < MockOnlineAudioHTTP.sfxTitles.count)
        #expect(res.allSatisfy { !$0.title.hasSuffix(".wav") && $0.kind == .sfx && $0.provider == "freesound" })
        #expect(res.contains { $0.license.requiresAttribution } && res.contains { !$0.license.requiresAttribution })
        let m = try await p.search(OnlineAudioQuery(kind: .music, mode: .featured), key: "K", http: http)
        #expect(m.first?.bpm == 120)
    }

    @Test func jamendoKeepsPlainCCBYDownloadableTracks() async throws {
        let p = JamendoProvider()
        let r = p.request(OnlineAudioQuery(kind: .music, mode: .mood("happy"), text: "summer"), key: "C")
        let items = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems!
        func v(_ n: String) -> String? { items.first { $0.name == n }?.value }
        #expect(v("client_id") == "C" && v("ccnc") == "false" && v("ccnd") == "false" && v("ccsa") == "false")
        #expect(v("fuzzytags") == "happy" && v("search") == "summer")
        #expect(p.request(OnlineAudioQuery(kind: .music, mode: .featured), key: "C").url!.query!.contains("featured=1"))
        #expect(p.request(OnlineAudioQuery(kind: .music, mode: .trending), key: "C").url!.query!.contains("order=popularity_week"))

        let res = try await p.search(OnlineAudioQuery(kind: .music, mode: .trending), key: "C", http: Self.mock())
        // 8 mock tracks: one BY-SA, one without download permission → dropped
        #expect(res.count == 6)
        #expect(res.allSatisfy { $0.license.id == "CC-BY-3.0" && $0.license.requiresAttribution })
        #expect(res.first!.attribution.contains(res.first!.artist) && res.first!.attribution.contains("jamendo.com"))
        // bad client id: HTTP 200 with a failed header
        let bad = Data(#"{"headers":{"status":"failed","code":5,"error_message":"Invalid client id"},"results":[]}"#.utf8)
        #expect(throws: OnlineAudioError.invalidKey) { try p.parse(bad, query: OnlineAudioQuery(kind: .music, mode: .featured)) }
    }

    @Test func errorsMapToUserStates() async {
        let http = Self.mock()
        let q = OnlineAudioQuery(kind: .sfx, mode: .trending)
        await #expect(throws: OnlineAudioError.offline) { try await FreesoundProvider().search(q, key: "offline", http: http) }
        await #expect(throws: OnlineAudioError.invalidKey) { try await FreesoundProvider().search(q, key: "bad", http: http) }
        #expect(OnlineAudioError.from(URLError(.timedOut)) == .offline)
        #expect(OnlineAudioError.from(URLError(.notConnectedToInternet)) == .offline)
    }

    @Test func downloadCachesOnceAndInstallsWithLicenseSidecar() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("valse-online-dl-\(UUID().uuidString)")
        OnlineAudioDownloads.cacheOverride = root.appendingPathComponent("cache")
        defer { OnlineAudioDownloads.cacheOverride = nil; try? FileManager.default.removeItem(at: root) }
        let http = Self.mock()
        let t = try #require(try await FreesoundProvider().search(OnlineAudioQuery(kind: .sfx, mode: .trending), key: "K", http: http).first)
        #expect(!OnlineAudioDownloads.isCached(t))
        let c = try await OnlineAudioDownloads.download(t, http: http)
        #expect(OnlineAudioDownloads.isCached(t) && c.pathExtension == "wav")
        let n = http.requests.count
        _ = try await OnlineAudioDownloads.download(t, http: http)
        #expect(http.requests.count == n, "second download must hit the cache")
        let installed = try OnlineAudioDownloads.install(c, track: t, into: root.appendingPathComponent("project/media"))
        #expect(FileManager.default.fileExists(atPath: installed.path))
        let side = try #require(OnlineAudioDownloads.readSidecar(installed))
        #expect(side.id == t.id && side.license == t.license && side.pageURL == t.pageURL)
        let audio = try await AudioFileIO.read(installed)
        #expect(abs(Double(audio.frames) / audio.sampleRate - t.duration) < 0.05)
    }

    @Test func memorySecretStoreRoundTrips() {
        let s = MemorySecretStore()
        #expect(s.get("freesound") == nil)
        s.set("abc", for: "freesound")
        #expect(s.get("freesound") == "abc")
        s.set("", for: "freesound")
        #expect(s.get("freesound") == nil)
    }

    /// Opt-in live check against the real services (never in CI / scripts/test.sh unless a key is exported).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VALSE_LIVE_FREESOUND_KEY"] != nil
                   || ProcessInfo.processInfo.environment["VALSE_LIVE_JAMENDO_KEY"] != nil))
    func liveSearch() async throws {
        let env = ProcessInfo.processInfo.environment
        let http = URLSessionOnlineAudioHTTP()
        if let k = env["VALSE_LIVE_FREESOUND_KEY"] {
            let r = try await FreesoundProvider().search(OnlineAudioQuery(kind: .sfx, mode: .search, text: "whoosh"), key: k, http: http)
            #expect(!r.isEmpty)
            #expect(r.allSatisfy { OnlineLicensePolicy.classify($0.license.url) != nil })
            let m = try await FreesoundProvider().search(OnlineAudioQuery(kind: .music, mode: .featured), key: k, http: http)
            #expect(!m.isEmpty)
        }
        if let k = env["VALSE_LIVE_JAMENDO_KEY"] {
            let r = try await JamendoProvider().search(OnlineAudioQuery(kind: .music, mode: .featured), key: k, http: http)
            #expect(!r.isEmpty)
            #expect(r.allSatisfy { $0.license.level == .attribution })
        }
    }
}
