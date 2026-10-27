import Foundation
import ValseCore

// Online music & sound-effect search (AU-001 / AU-002, owner exception to "local-only", docs/STATUS.md decisions):
// the ONLY network access of the music library. Requests happen only when the user opens / searches Audio ▸ Online;
// nothing else in the app calls these types. Providers return items whose license is safe for social media
// (`OnlineLicensePolicy`: CC0 / public-domain mark = "Safe ✓"; CC BY = allowed with the credit shown; NC / ND / SA /
// Sampling+ are rejected). Adding a track downloads it once (cache → project media folder + license sidecar) so the
// project keeps working offline.

/// License of an online item, already vetted by `OnlineLicensePolicy`.
public struct OnlineLicense: Codable, Sendable, Hashable {
    public enum Level: String, Codable, Sendable {
        /// CC0 / Public Domain Mark: no attribution, commercial use OK.
        case publicDomain
        /// CC BY: commercial use OK, credit the author (caption / description).
        case attribution
    }
    /// SPDX-like id: "CC0-1.0", "PDM-1.0", "CC-BY-4.0", "CC-BY-3.0".
    public var id: String
    public var name: String
    public var url: String
    public var level: Level
    public var requiresAttribution: Bool { level == .attribution }

    public init(id: String, name: String, url: String, level: Level) {
        self.id = id; self.name = name; self.url = url; self.level = level
    }
}

/// Which licenses an online item may have to be offered at all.
public enum OnlineLicensePolicy {
    /// Maps a provider's license (a Creative Commons URL or a Freesound license name) to an allowed license;
    /// nil = rejected (non-commercial, no-derivatives, share-alike, Sampling+, unknown).
    public static func classify(_ raw: String) -> OnlineLicense? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch s {
        case "creative commons 0", "cc0", "cc0-1.0": return cc0
        case "attribution", "cc-by", "cc by": return by("4.0")
        default: break
        }
        var path = s.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        if path.hasPrefix("www.") { path.removeFirst(4) }
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/legalcode") { path = String(path.dropLast(10)) }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.first == "creativecommons.org", parts.count >= 3 else { return nil }
        if parts[1] == "publicdomain" {
            if parts[2] == "zero" { return cc0 }
            if parts[2] == "mark" { return OnlineLicense(id: "PDM-1.0", name: "Public Domain Mark 1.0",
                                                         url: "https://creativecommons.org/publicdomain/mark/1.0/", level: .publicDomain) }
            return nil
        }
        // only plain "by" (no -nc / -nd / -sa) and a known version
        guard parts[1] == "licenses", parts[2] == "by" else { return nil }
        let v = parts.count >= 4 ? parts[3] : "4.0"
        guard ["2.0", "2.5", "3.0", "4.0"].contains(v) else { return nil }
        return by(v)
    }

    static let cc0 = OnlineLicense(id: "CC0-1.0", name: "CC0 1.0 Universal (Public Domain Dedication)",
                                   url: "https://creativecommons.org/publicdomain/zero/1.0/", level: .publicDomain)
    static func by(_ v: String) -> OnlineLicense {
        OnlineLicense(id: "CC-BY-\(v)", name: "Creative Commons Attribution \(v)",
                      url: "https://creativecommons.org/licenses/by/\(v)/", level: .attribution)
    }
}

/// One search result (music track or sound effect) of an online provider.
public struct OnlineTrack: Codable, Sendable, Hashable, Identifiable {
    public var provider: String
    public var remoteID: String
    public var kind: ContentItem.Kind
    public var title: String
    public var artist: String
    public var duration: Double
    public var bpm: Double?
    public var tags: [String]
    /// Streamed by the preview player.
    public var previewURL: URL
    /// Downloaded once on "Use" (may equal `previewURL`).
    public var downloadURL: URL
    public var artworkURL: URL?
    /// The item's page at the provider (license evidence, credit link).
    public var pageURL: URL
    public var license: OnlineLicense
    /// Extension of the downloaded file ("mp3").
    public var fileExtension: String
    /// Date the item was fetched (yyyy-MM-dd), recorded in the license sidecar.
    public var retrieved: String

    public var id: String { "\(provider):\(remoteID)" }

    /// Credit line for CC BY items ("“Title” by Artist (page) — CC BY 4.0").
    public var attribution: String {
        "“\(title)” by \(artist) (\(pageURL.absoluteString)), \(license.name) (\(license.url))"
    }

    public init(provider: String, remoteID: String, kind: ContentItem.Kind, title: String, artist: String, duration: Double,
                bpm: Double? = nil, tags: [String] = [], previewURL: URL, downloadURL: URL, artworkURL: URL? = nil, pageURL: URL,
                license: OnlineLicense, fileExtension: String = "mp3", retrieved: String = OnlineTrack.today()) {
        self.provider = provider; self.remoteID = remoteID; self.kind = kind; self.title = title; self.artist = artist
        self.duration = duration; self.bpm = bpm; self.tags = tags; self.previewURL = previewURL; self.downloadURL = downloadURL
        self.artworkURL = artworkURL; self.pageURL = pageURL; self.license = license; self.fileExtension = fileExtension
        self.retrieved = retrieved
    }

    /// Extension of a download URL when it names an audio file, else "mp3" (Jamendo streams have no extension).
    public static func audioExtension(_ u: URL) -> String {
        let e = u.pathExtension.lowercased()
        return ["mp3", "wav", "ogg", "m4a", "flac", "aif", "aiff"].contains(e) ? e : "mp3"
    }

    public static func today() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

/// What to list: a text search and/or a browse mode (CapCut / Instagram: For you, Trending, Moods, Genres).
public struct OnlineAudioQuery: Hashable, Sendable {
    public enum Mode: Hashable, Sendable {
        /// Editors' picks / best rated (the "For you" feed; `boost` adds the user's favourite tags).
        case featured
        /// Most popular recently.
        case trending
        case mood(String)
        case genre(String)
        /// Sound-effect category (ContentLibrary.sfxCategories ids).
        case category(String)
        case search
    }
    public var kind: ContentItem.Kind
    public var mode: Mode
    public var text: String
    /// Extra tags from the user's favourites / recent picks (For you), local signal only.
    public var boost: [String]
    public var page: Int
    public var pageSize: Int

    public init(kind: ContentItem.Kind, mode: Mode, text: String = "", boost: [String] = [], page: Int = 1, pageSize: Int = 30) {
        self.kind = kind; self.mode = mode; self.text = text; self.boost = boost; self.page = page; self.pageSize = pageSize
    }

    /// Search words for moods / genres / sound categories (English: providers index English tags).
    public var terms: String {
        switch mode {
        case .featured, .trending: return text
        case .search: return text
        case .mood(let m): return [OnlineAudioCatalog.moodTerms[m] ?? m, text].filter { !$0.isEmpty }.joined(separator: " ")
        case .genre(let g): return [OnlineAudioCatalog.genreTerms[g] ?? g, text].filter { !$0.isEmpty }.joined(separator: " ")
        case .category(let c): return [OnlineAudioCatalog.sfxTerms[c] ?? c, text].filter { !$0.isEmpty }.joined(separator: " ")
        }
    }
}

/// Browse vocabularies of the online library (UI chips; ids localized as music.mood.* / online.genre.* / sfx.category.*).
public enum OnlineAudioCatalog {
    public static let moods = ContentLibrary.moods
    public static let genres = ["pop", "electronic", "hiphop", "lofi", "rock", "cinematic", "acoustic", "jazz", "ambient",
                                "classical", "corporate", "funk"]
    public static let sfxCategories = ContentLibrary.sfxCategories
    static let moodTerms: [String: String] = [
        "happy": "happy", "chill": "chill", "energetic": "energetic", "epic": "epic", "romantic": "romantic",
        "dreamy": "dreamy", "sad": "sad", "tense": "suspense", "inspiring": "inspiring", "playful": "playful", "groovy": "groovy",
    ]
    static let genreTerms: [String: String] = [
        "pop": "pop", "electronic": "electronic", "hiphop": "hiphop", "lofi": "lofi", "rock": "rock", "cinematic": "cinematic",
        "acoustic": "acoustic", "jazz": "jazz", "ambient": "ambient", "classical": "classical", "corporate": "corporate", "funk": "funk",
    ]
    static let sfxTerms: [String: String] = [
        "transition": "whoosh", "ui": "click", "notification": "notification", "impact": "impact", "cartoon": "cartoon",
        "crowd": "applause", "tech": "camera shutter", "money": "coins", "stings": "jingle", "foley": "footsteps",
        "nature": "rain", "scifi": "laser",
    ]
}

public enum OnlineAudioError: Error, Equatable, Sendable {
    /// No connection (or the host can't be reached).
    case offline
    /// 401 / 403: missing or wrong API key.
    case invalidKey
    /// 429.
    case rateLimited
    case server(Int)
    case decoding(String)
    /// The download isn't decodable audio.
    case badAudio

    public static func from(_ error: Error) -> OnlineAudioError {
        if let e = error as? OnlineAudioError { return e }
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .timedOut,
                 .dataNotAllowed, .internationalRoamingOff, .dnsLookupFailed:
                return .offline
            default: return .server(u.errorCode)
            }
        }
        return .decoding(String(describing: error))
    }
}

// MARK: - HTTP

/// The one HTTP seam of the online library (tests inject `MockOnlineAudioHTTP`; no network in tests).
public protocol OnlineAudioHTTP: Sendable {
    func get(_ request: URLRequest) async throws -> (Data, Int)
}

public struct URLSessionOnlineAudioHTTP: OnlineAudioHTTP {
    let session: URLSession
    public init() {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 120
        c.httpAdditionalHeaders = ["User-Agent": "Valse/1.0 (macOS video editor)"]
        session = URLSession(configuration: c)
    }
    public func get(_ request: URLRequest) async throws -> (Data, Int) {
        let (d, r) = try await session.data(for: request)
        return (d, (r as? HTTPURLResponse)?.statusCode ?? 200)
    }
}

// MARK: - Providers

public protocol OnlineAudioProvider: Sendable {
    /// Stable id ("freesound", "jamendo"); part of every item id.
    var id: String { get }
    var name: String { get }
    var kinds: Set<ContentItem.Kind> { get }
    /// Where the user creates the free API key (Settings ▸ Music).
    var signupURL: URL { get }
    func request(_ q: OnlineAudioQuery, key: String) -> URLRequest
    func parse(_ data: Data, query: OnlineAudioQuery) throws -> [OnlineTrack]
}

extension OnlineAudioProvider {
    /// Runs the query; maps HTTP / URL errors; keeps only items with an allowed license (parsers already drop the rest).
    public func search(_ q: OnlineAudioQuery, key: String, http: OnlineAudioHTTP) async throws -> [OnlineTrack] {
        let data: Data, status: Int
        do { (data, status) = try await http.get(request(q, key: key)) } catch { throw OnlineAudioError.from(error) }
        switch status {
        case 200..<300: break
        case 401, 403: throw OnlineAudioError.invalidKey
        case 429: throw OnlineAudioError.rateLimited
        default: throw OnlineAudioError.server(status)
        }
        do { return try parse(data, query: q) } catch let e as OnlineAudioError { throw e } catch {
            throw OnlineAudioError.decoding(String(describing: error))
        }
    }
}

/// Freesound API v2 (https://freesound.org/docs/api/): sound effects and music loops. CC0 + CC BY only (filtered
/// server side and re-checked); the HQ MP3 preview (128 kbps) is the downloaded file — originals need OAuth2.
public struct FreesoundProvider: OnlineAudioProvider {
    public let id = "freesound"
    public let name = "Freesound"
    public let kinds: Set<ContentItem.Kind> = [.music, .sfx]
    public let signupURL = URL(string: "https://freesound.org/apiv2/apply/")!
    public static let base = URL(string: "https://freesound.org/apiv2/search/")!
    public init() {}

    public func request(_ q: OnlineAudioQuery, key: String) -> URLRequest {
        var filter = #"license:("Creative Commons 0" OR "Attribution")"#
        filter += q.kind == .sfx ? " duration:[0 TO 30]" : " duration:[20 TO 600] tag:music"
        if q.mode == .trending { filter += " created:[NOW-90DAY TO NOW]" }
        let sort: String
        switch q.mode {
        case .featured: sort = "rating_desc"
        case .trending: sort = "downloads_desc"
        default: sort = q.terms.isEmpty ? "downloads_desc" : "score"
        }
        var text = q.terms
        if q.mode == .featured, !q.boost.isEmpty { text = ([text] + q.boost.prefix(2)).filter { !$0.isEmpty }.joined(separator: " ") }
        var c = URLComponents(url: Self.base, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "query", value: text), .init(name: "filter", value: filter), .init(name: "sort", value: sort),
            .init(name: "fields", value: "id,name,username,license,duration,tags,previews,url,bpm,images"),
            .init(name: "page", value: "\(q.page)"), .init(name: "page_size", value: "\(min(q.pageSize, 150))"),
            .init(name: "token", value: key),
        ]
        return URLRequest(url: c.url!)
    }

    struct Response: Decodable {
        struct Sound: Decodable {
            let id: Int
            let name: String
            let username: String
            let license: String
            let duration: Double
            let tags: [String]?
            let previews: [String: String]?
            let url: String?
            let bpm: Double?
            let images: [String: String]?
        }
        let results: [Sound]
    }

    public func parse(_ data: Data, query: OnlineAudioQuery) throws -> [OnlineTrack] {
        try JSONDecoder().decode(Response.self, from: data).results.compactMap { s in
            guard let lic = OnlineLicensePolicy.classify(s.license),
                  let p = (s.previews?["preview-hq-mp3"] ?? s.previews?["preview-lq-mp3"]).flatMap(URL.init(string:)) else { return nil }
            let title = s.name.replacingOccurrences(of: #"\.(wav|mp3|aiff?|flac|ogg|m4a)$"#, with: "", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: "_", with: " ")
            return OnlineTrack(provider: id, remoteID: "\(s.id)", kind: query.kind, title: title, artist: s.username,
                               duration: s.duration, bpm: s.bpm.flatMap { $0 > 0 ? $0.rounded() : nil }, tags: s.tags ?? [],
                               previewURL: p, downloadURL: p, artworkURL: s.images?["waveform_m"].flatMap(URL.init(string:)),
                               pageURL: URL(string: s.url ?? "https://freesound.org/s/\(s.id)/")!, license: lic,
                               fileExtension: OnlineTrack.audioExtension(p))
        }
    }
}

/// Jamendo API v3 (https://developer.jamendo.com/): independent music. Only tracks under plain CC BY (no NC / ND /
/// SA, `ccnc=false&ccnd=false&ccsa=false`, re-checked from `license_ccurl`) whose download the artist allows.
public struct JamendoProvider: OnlineAudioProvider {
    public let id = "jamendo"
    public let name = "Jamendo"
    public let kinds: Set<ContentItem.Kind> = [.music]
    public let signupURL = URL(string: "https://devportal.jamendo.com/")!
    public static let base = URL(string: "https://api.jamendo.com/v3.0/tracks/")!
    public init() {}

    public func request(_ q: OnlineAudioQuery, key: String) -> URLRequest {
        var c = URLComponents(url: Self.base, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            .init(name: "client_id", value: key), .init(name: "format", value: "json"),
            .init(name: "limit", value: "\(min(q.pageSize, 200))"), .init(name: "offset", value: "\((q.page - 1) * q.pageSize)"),
            .init(name: "include", value: "musicinfo licenses"), .init(name: "audioformat", value: "mp32"),
            .init(name: "audiodlformat", value: "mp32"),
            .init(name: "ccnc", value: "false"), .init(name: "ccnd", value: "false"), .init(name: "ccsa", value: "false"),
        ]
        switch q.mode {
        case .featured:
            items.append(.init(name: "featured", value: "1"))
            if !q.boost.isEmpty { items.append(.init(name: "fuzzytags", value: q.boost.prefix(3).joined(separator: " "))) }
        case .trending: items.append(.init(name: "order", value: "popularity_week"))
        case .mood(let m): items.append(.init(name: "fuzzytags", value: OnlineAudioCatalog.moodTerms[m] ?? m))
        case .genre(let g): items.append(.init(name: "tags", value: OnlineAudioCatalog.genreTerms[g] ?? g))
        case .category, .search: break
        }
        if !q.text.isEmpty {
            items.append(.init(name: "search", value: q.text))
            items.append(.init(name: "boost", value: "popularity_month"))
        } else if q.mode != .trending {
            items.append(.init(name: "order", value: "popularity_month"))
        }
        c.queryItems = items
        return URLRequest(url: c.url!)
    }

    struct Response: Decodable {
        struct Headers: Decodable { let status: String?; let code: Int?; let error_message: String? }
        struct Track: Decodable {
            struct MusicInfo: Decodable {
                struct Tags: Decodable { let genres: [String]?; let instruments: [String]?; let vartags: [String]? }
                let tags: Tags?
                let speed: String?
            }
            let id: String
            let name: String
            let duration: Double
            let artist_name: String
            let audio: String?
            let audiodownload: String?
            let audiodownload_allowed: Bool?
            let license_ccurl: String?
            let image: String?
            let shareurl: String?
            let musicinfo: MusicInfo?
        }
        let headers: Headers?
        let results: [Track]
    }

    public func parse(_ data: Data, query: OnlineAudioQuery) throws -> [OnlineTrack] {
        let r = try JSONDecoder().decode(Response.self, from: data)
        if let h = r.headers, h.status == "failed" {
            // Jamendo reports a bad client_id with HTTP 200 + code 5
            if h.code == 5 { throw OnlineAudioError.invalidKey }
            throw OnlineAudioError.server(h.code ?? 0)
        }
        return r.results.compactMap { t in
            guard t.audiodownload_allowed != false, let lic = t.license_ccurl.flatMap(OnlineLicensePolicy.classify),
                  let audio = t.audio.flatMap(URL.init(string:)), !audio.absoluteString.isEmpty else { return nil }
            let dl = t.audiodownload.flatMap { $0.isEmpty ? nil : URL(string: $0) } ?? audio
            let tags = (t.musicinfo?.tags?.genres ?? []) + (t.musicinfo?.tags?.vartags ?? []) + (t.musicinfo?.tags?.instruments ?? [])
            return OnlineTrack(provider: id, remoteID: t.id, kind: .music, title: t.name, artist: t.artist_name, duration: t.duration,
                               bpm: nil, tags: tags, previewURL: audio, downloadURL: dl,
                               artworkURL: t.image.flatMap { $0.isEmpty ? nil : URL(string: $0) },
                               pageURL: URL(string: t.shareurl ?? "https://www.jamendo.com/track/\(t.id)")!, license: lic,
                               fileExtension: OnlineTrack.audioExtension(dl))
        }
    }
}

public enum OnlineAudioProviders {
    public static let all: [any OnlineAudioProvider] = [FreesoundProvider(), JamendoProvider()]
    public static func provider(_ id: String) -> (any OnlineAudioProvider)? { all.first { $0.id == id } }
}

// MARK: - Download on "Use"

/// Downloads an item once into the cache (`<cache>/OnlineAudio/<provider>/<id>.<ext>`), then copies it into the
/// project's media folder with a `<file>.license.json` sidecar (provider, page, author, license, retrieval date) so the
/// project works offline and the license travels with it.
public enum OnlineAudioDownloads {
    nonisolated(unsafe) public static var cacheOverride: URL?
    public static var cacheDirectory: URL {
        cacheOverride ?? ValsePaths.cacheDirectory.appendingPathComponent("OnlineAudio", isDirectory: true)
    }

    public static func cachedURL(_ t: OnlineTrack) -> URL {
        cacheDirectory.appendingPathComponent(t.provider, isDirectory: true)
            .appendingPathComponent(safe(t.remoteID) + "." + t.fileExtension)
    }

    public static func isCached(_ t: OnlineTrack) -> Bool { FileManager.default.fileExists(atPath: cachedURL(t).path) }

    /// Downloads (if needed) and returns the cached file.
    public static func download(_ t: OnlineTrack, http: OnlineAudioHTTP) async throws -> URL {
        let dst = cachedURL(t)
        if FileManager.default.fileExists(atPath: dst.path) { return dst }
        let data: Data, status: Int
        do { (data, status) = try await http.get(URLRequest(url: t.downloadURL)) } catch { throw OnlineAudioError.from(error) }
        guard (200..<300).contains(status) else { throw status == 429 ? OnlineAudioError.rateLimited : OnlineAudioError.server(status) }
        guard data.count > 512 else { throw OnlineAudioError.badAudio }
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = dst.appendingPathExtension("part")
        try data.write(to: tmp, options: .atomic)
        _ = try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: tmp, to: dst)
        try writeSidecar(t, next: dst)
        return dst
    }

    /// Copies the cached file into `dir` as "<Title> (<provider> <id>).<ext>" + license sidecar; returns the copy.
    public static func install(_ cached: URL, track t: OnlineTrack, into dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = safe("\(t.title) (\(t.provider) \(t.remoteID))")
        let dst = dir.appendingPathComponent(name + "." + t.fileExtension)
        if !FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.copyItem(at: cached, to: dst) }
        try writeSidecar(t, next: dst)
        return dst
    }

    public static func sidecarURL(_ audio: URL) -> URL { audio.appendingPathExtension("license.json") }

    public static func writeSidecar(_ t: OnlineTrack, next audio: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try e.encode(t).write(to: sidecarURL(audio), options: .atomic)
    }

    public static func readSidecar(_ audio: URL) -> OnlineTrack? {
        (try? Data(contentsOf: sidecarURL(audio))).flatMap { try? JSONDecoder().decode(OnlineTrack.self, from: $0) }
    }

    static func safe(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        return String(s.unicodeScalars.map { bad.contains($0) ? "-" : Character($0) }.prefix(120))
    }
}
