import Foundation
import Security
import ValseCore

/// Where the user's own provider API keys live (Settings ▸ Music). Never in UserDefaults, never in the repo.
public protocol OnlineAudioSecretStore: AnyObject, Sendable {
    func get(_ account: String) -> String?
    func set(_ value: String?, for account: String)
}

/// macOS Keychain (generic passwords, service "fr.valse.online-audio", one account per provider id).
/// Keys saved before the rename (service "fr.montage.online-audio", created by the old bundle id) are copied over at
/// the first launch (`migrateLegacyItems`) or at the first read, without any keychain prompt: an item macOS would ask
/// about (its access list names the old app) stays where it is, and the key reads as not set (the user enters it
/// again in Settings ▸ Music).
public final class KeychainSecretStore: OnlineAudioSecretStore, @unchecked Sendable {
    public let service: String
    /// Where this store looks for keys saved by Montage (nil: nowhere).
    let legacyService: String?

    /// scripts/updater_e2e.sh test copies use their own services, never the user's.
    static var testSuffix: String {
        Bundle.main.bundleIdentifier != "fr.valse.Valse" && ProcessInfo.processInfo.environment["VALSE_UPDATER_TEST"] == "1"
            ? ".updater-e2e" : ""
    }
    public static var defaultService: String { "fr.valse.online-audio" + testSuffix }
    static var defaultLegacyService: String { LegacyNames.keychainService + testSuffix }

    public init(service: String = KeychainSecretStore.defaultService) {
        self.service = service
        legacyService = service == Self.defaultService ? Self.defaultLegacyService : nil
    }

    public func get(_ account: String) -> String? {
        if let v = Self.read(service: service, account: account, interactive: true) { return v }
        guard let legacyService, let v = Self.read(service: legacyService, account: account, interactive: false) else { return nil }
        set(v, for: account)
        return v
    }

    static func read(service: String, account: String, interactive: Bool) -> String? {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        if !interactive { q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// First launch after the rename: copies every key of the old service that can be read without a prompt.
    /// Returns the accounts copied. Old items are kept (Montage may still be installed elsewhere).
    @discardableResult
    public static func migrateLegacyItems() -> [String] {
        let store = KeychainSecretStore()
        guard let legacy = store.legacyService else { return [] }
        // attributes only (no secret): never asks
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: legacy,
                                kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll,
                                kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        var copied: [String] = []
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  read(service: store.service, account: account, interactive: false) == nil,
                  let v = read(service: legacy, account: account, interactive: false) else { continue }
            store.set(v, for: account)
            copied.append(account)
        }
        return copied
    }

    public func set(_ value: String?, for account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let v = value, !v.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(v.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let s = SecItemAdd(add as CFDictionary, nil)
        if s != errSecSuccess { EngineLog.error("keychain: storing the \(account) key failed (\(s))") }
    }
}

/// In-memory store (unit + UI tests: the real Keychain is never touched).
public final class MemorySecretStore: OnlineAudioSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    public init(_ values: [String: String] = [:]) { self.values = values }
    public func get(_ account: String) -> String? { lock.withLock { values[account] } }
    public func set(_ value: String?, for account: String) {
        lock.withLock { if let v = value, !v.isEmpty { values[account] = v } else { values[account] = nil } }
    }
}

// MARK: - Mock provider data (tests: no network)

/// Answers provider requests offline with Freesound / Jamendo-shaped JSON whose audio URLs are local `file://`
/// tones, and serves those files for previews / downloads. Used by unit tests and by the app in UI-test mode, so the
/// whole pipeline (request → parse → license filter → stream → download → add) runs without the network.
/// Key "offline" simulates no connection, key "bad" an invalid key.
public final class MockOnlineAudioHTTP: OnlineAudioHTTP, @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private var _requests: [URL] = []
    /// Every URL requested so far (tests assert on query parameters).
    public var requests: [URL] { lock.withLock { _requests } }

    public init(directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("valse-online-mock", isDirectory: true)) {
        self.directory = directory
    }

    public func get(_ request: URLRequest) async throws -> (Data, Int) {
        guard let url = request.url else { throw URLError(.badURL) }
        lock.withLock { _requests.append(url) }
        if url.isFileURL { return (try Data(contentsOf: url), 200) }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ n: String) -> String? { items.first { $0.name == n }?.value }
        let key = q("token") ?? q("client_id") ?? ""
        if key == "offline" { throw URLError(.notConnectedToInternet) }
        if key == "bad" { return (Data(#"{"detail":"Invalid token"}"#.utf8), 401) }
        try await Task.sleep(for: .milliseconds(30))
        if url.host?.contains("freesound") == true { return (try freesound(q), 200) }
        if url.host?.contains("jamendo") == true { return (try jamendo(q), 200) }
        return (Data(), 404)
    }

    static let musicTitles = ["Sunny Walk", "Night Drive", "Golden Hour", "City Lights", "Ocean Breeze", "Paper Planes",
                              "Morning Coffee", "Neon Dreams", "Slow Motion", "Weekend Vibes", "First Snow", "Road Trip"]
    static let sfxTitles = ["Whoosh", "Pop", "Click", "Ding", "Swipe", "Boom", "Applause", "Camera shutter", "Coin", "Rain"]

    func freesound(_ q: (String) -> String?) throws -> Data {
        let query = q("query") ?? ""
        let music = q("filter")?.contains("tag:music") == true
        let titles = music ? Self.musicTitles : Self.sfxTitles
        // licenses: mostly CC0, some CC BY, and rejected ones (NC, Sampling+) the parser must drop
        let licenses = ["http://creativecommons.org/publicdomain/zero/1.0/", "https://creativecommons.org/licenses/by/4.0/",
                        "http://creativecommons.org/licenses/by-nc/3.0/", "http://creativecommons.org/publicdomain/zero/1.0/",
                        "Sampling+"]
        var results: [[String: Any]] = []
        for (i, t) in titles.enumerated() {
            let id = 9000 + i + (music ? 100 : 0)
            let dur = music ? 24.0 + Double(i % 4) * 4 : 0.6 + Double(i % 3) * 0.5
            let file = try tone(id: "fs\(id)", seconds: dur, hz: 220 + Double(i) * 37, beatHz: music ? 2 : 0)
            let name = query.isEmpty ? t : "\(t) (\(query))"
            results.append(["id": id, "name": name + ".wav", "username": "mock_user\(i % 3)", "license": licenses[i % licenses.count],
                            "duration": dur, "tags": [music ? "music" : "sfx", query.lowercased()].filter { !$0.isEmpty },
                            "previews": ["preview-hq-mp3": file.absoluteString], "url": "https://freesound.org/s/\(id)/",
                            "bpm": music ? 120 : 0])
        }
        return try JSONSerialization.data(withJSONObject: ["count": results.count, "results": results])
    }

    func jamendo(_ q: (String) -> String?) throws -> Data {
        let search = q("search") ?? q("tags") ?? q("fuzzytags") ?? ""
        var results: [[String: Any]] = []
        for (i, t) in Self.musicTitles.prefix(8).enumerated() {
            let id = "17\(i)"
            let file = try tone(id: "jm\(id)", seconds: 30 + Double(i) * 3, hz: 196 + Double(i) * 29, beatHz: 1.6)
            let lic = i == 5 ? "http://creativecommons.org/licenses/by-sa/3.0/" : "http://creativecommons.org/licenses/by/3.0/"
            results.append(["id": id, "name": search.isEmpty ? t : "\(t) – \(search)", "duration": 30 + i * 3,
                            "artist_name": "Mock Artist \(i % 4)", "audio": file.absoluteString, "audiodownload": file.absoluteString,
                            "audiodownload_allowed": i != 6, "license_ccurl": lic, "image": "",
                            "shareurl": "https://www.jamendo.com/track/\(id)",
                            "musicinfo": ["speed": "medium", "tags": ["genres": ["pop"], "vartags": ["happy"], "instruments": ["piano"]]]])
        }
        return try JSONSerialization.data(withJSONObject: ["headers": ["status": "success", "code": 0], "results": results])
    }

    /// A short stereo tone (with a pulse for "music"), written once as WAV.
    func tone(id: String, seconds: Double, hz: Double, beatHz: Double) throws -> URL {
        let u = directory.appendingPathComponent("\(id).wav")
        if FileManager.default.fileExists(atPath: u.path) { return u }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sr = 22050.0
        let b = AudioBuffer(channels: 2, frames: Int(seconds * sr), sampleRate: sr)
        for i in 0..<b.frames {
            let t = Double(i) / sr
            let env = beatHz > 0 ? 0.5 + 0.5 * max(0, cos(2 * .pi * beatHz * t)) : max(0, 1 - t / seconds)
            let v = Float(sin(2 * .pi * hz * t) * 0.3 * env)
            b[0, i] = v; b[1, i] = v
        }
        try AudioFileIO.write(b, to: u)
        return u
    }
}
