import SwiftUI
import AppKit
import MontageCore
import MontageEngine
import Perception

/// Audio ▸ Online (AU-001 / AU-002, owner exception to local-only — docs/STATUS.md): Instagram / CapCut-like music &
/// sound-effect search over the user's own provider keys (Freesound, Jamendo; Settings ▸ Music, Keychain).
/// For you · Trending · Moods · Genres · Sound effects; rows stream a preview (waveform once cached), show
/// artist · duration · BPM · provider, ☆, the "Safe ✓" / "Credit" badge + license card, and "Use" (⊕ / double-click /
/// drag) downloads once into the project's media folder (+ license sidecar) and adds the track at the playhead.
/// Network: only from here, only while the user opens or searches these entries. UI tests use `MockOnlineAudioHTTP`.
@MainActor @Perceptible
final class OnlineAudioState {
    static let shared = OnlineAudioState()

    static let navForYou = "online.forYou", navTrending = "online.trending", navMoods = "online.moods",
               navGenres = "online.genres", navSFX = "online.sfx"
    static let navIDs: Set<String> = [navForYou, navTrending, navMoods, navGenres, navSFX]
    static var navEntries: [(id: String, title: String)] {
        [(navForYou, tr("online.nav.forYou")), (navTrending, tr("online.nav.trending")), (navMoods, tr("online.nav.moods")),
         (navGenres, tr("online.nav.genres")), (navSFX, tr("online.nav.sfx"))]
    }
    static let enabledKey = "montage.onlineAudio.enabled"
    /// Opens Settings ▸ Music (installed by AppModel).
    static var openSettings: (() -> Void)?

    enum Phase: Equatable {
        case idle, loading, loaded, disabled, noKey, offline, rateLimited
        case invalidKey(String)
        case failed(String)
        var name: String {
            switch self {
            case .idle: return "idle"
            case .loading: return "loading"
            case .loaded: return "loaded"
            case .disabled: return "disabled"
            case .noKey: return "noKey"
            case .offline: return "offline"
            case .rateLimited: return "rateLimited"
            case .invalidKey: return "invalidKey"
            case .failed: return "failed"
            }
        }
    }

    let http: OnlineAudioHTTP
    let secrets: OnlineAudioSecretStore
    let providers: [any OnlineAudioProvider]
    let mocked: Bool

    var enabled: Bool { didSet { if !mocked { AppDefaults.store.set(enabled, forKey: Self.enabledKey) }; keysVersion += 1 } }
    var mood = "happy"
    var genre = "pop"
    /// Sound effects: "" = popular, else a category id.
    var sfxCategory = ""
    private(set) var phase: Phase = .idle
    private(set) var results: [OnlineTrack] = []
    /// Providers that failed while others answered (shown as a one-line warning).
    private(set) var warnings: [String] = []
    private(set) var downloading: Set<String> = []
    /// Bumped when a key / the enabled switch changes (reloads the visible list).
    private(set) var keysVersion = 0
    /// Every online track seen this session (row id → track): drops, favourites, recents.
    @PerceptionIgnored private(set) var known: [String: OnlineTrack] = [:]
    /// Favourited / used tracks, persisted (support folder) so Favorites / Recent list them offline.
    private(set) var saved: [String: OnlineTrack] = [:]
    @PerceptionIgnored private var cache: [OnlineAudioQuery: (Date, [OnlineTrack], [String])] = [:]
    @PerceptionIgnored private var task: Task<Void, Never>?
    @PerceptionIgnored private(set) var lastQuery: OnlineAudioQuery?

    init(http: OnlineAudioHTTP? = nil, secrets: OnlineAudioSecretStore? = nil,
         providers: [any OnlineAudioProvider] = OnlineAudioProviders.all) {
        let mock = TestAnchors.isEnabled || ProcessInfo.processInfo.environment["MONTAGE_ONLINE_AUDIO_MOCK"] == "1"
        mocked = http == nil ? mock : true
        self.http = http ?? (mock ? MockOnlineAudioHTTP() : URLSessionOnlineAudioHTTP())
        self.secrets = secrets ?? (mock ? MemorySecretStore() : KeychainSecretStore())
        self.providers = providers
        enabled = mocked ? true : (AppDefaults.store.object(forKey: Self.enabledKey) as? Bool ?? true)
        saved = mocked ? [:] : Self.loadSaved()
        for (k, v) in saved { known[k] = v }
    }

    // MARK: Keys

    func key(_ provider: String) -> String? { secrets.get(provider).flatMap { $0.isEmpty ? nil : $0 } }
    func setKey(_ value: String?, for provider: String) {
        secrets.set(value?.trimmingCharacters(in: .whitespacesAndNewlines), for: provider)
        cache.removeAll()
        keysVersion += 1
    }
    var configuredProviders: [String] { providers.filter { key($0.id) != nil }.map(\.id) }

    // MARK: Queries

    func query(nav: String, text: String) -> OnlineAudioQuery {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch nav {
        case Self.navSFX:
            if !t.isEmpty { return OnlineAudioQuery(kind: .sfx, mode: .search, text: t) }
            return OnlineAudioQuery(kind: .sfx, mode: sfxCategory.isEmpty ? .trending : .category(sfxCategory))
        case Self.navTrending: return OnlineAudioQuery(kind: .music, mode: t.isEmpty ? .trending : .search, text: t)
        case Self.navMoods: return OnlineAudioQuery(kind: .music, mode: .mood(mood), text: t)
        case Self.navGenres: return OnlineAudioQuery(kind: .music, mode: .genre(genre), text: t)
        default:
            if !t.isEmpty { return OnlineAudioQuery(kind: .music, mode: .search, text: t) }
            return OnlineAudioQuery(kind: .music, mode: .featured, boost: forYouTags())
        }
    }

    /// The user's taste, from tracks they favourited / used (local signal only): most frequent tags.
    func forYouTags() -> [String] {
        var count: [String: Int] = [:]
        for t in saved.values where t.kind == .music { for g in t.tags.prefix(6) { count[g.lowercased(), default: 0] += 1 } }
        return count.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(3).map(\.key)
    }

    /// Loads the list for `nav` / `text` (24 h memory cache per query, like the providers ask).
    func load(nav: String, text: String, force: Bool = false) {
        let q = query(nav: nav, text: text)
        task?.cancel()
        guard enabled else { phase = .disabled; results = []; return }
        // fixed merge order: the provider specialised in this kind first (Jamendo for music, then Freesound), ties in
        // catalogue order — never the order the answers arrive in (see the merge below)
        let active = providers.enumerated().filter { $0.element.kinds.contains(q.kind) }
            .sorted { ($0.element.kinds.count, $0.offset) < ($1.element.kinds.count, $1.offset) }
            .compactMap { e in key(e.element.id).map { (e.element, $0) } }
        guard !active.isEmpty else { phase = .noKey; results = []; lastQuery = q; return }
        if !force, let c = cache[q], Date().timeIntervalSince(c.0) < 86_400 {
            lastQuery = q; results = c.1; warnings = c.2; phase = .loaded; return
        }
        if lastQuery != q { results = [] }
        lastQuery = q
        phase = .loading
        let http = http
        task = Task {
            // collected in PROVIDER order, not arrival order: the merged list (and the warnings) must not depend on
            // which provider answered first (the order changed from search to search; DX-C, audio_online_fr under load)
            var byProvider = [Result<[OnlineTrack], OnlineAudioError>?](repeating: nil, count: active.count)
            await withTaskGroup(of: (Int, Result<[OnlineTrack], OnlineAudioError>).self) { g in
                for (i, (p, k)) in active.enumerated() {
                    g.addTask {
                        // the Result is built first, the tuple returned outside do/catch: with -O (Swift 6.3.3)
                        // `do { return (i, .success(try await …)) } catch { … }` returned index 0 from every child, so
                        // the last provider overwrote the first (release builds only: Jamendo rows missing)
                        let r: Result<[OnlineTrack], OnlineAudioError>
                        do { r = .success(try await p.search(q, key: k, http: http)) } catch { r = .failure(OnlineAudioError.from(error)) }
                        return (i, r)
                    }
                }
                for await (i, r) in g { byProvider[i] = r }
            }
            var lists: [[OnlineTrack]] = [], errors: [(String, OnlineAudioError)] = []
            for (i, r) in byProvider.enumerated() {
                switch r {
                case .success(let l)?: lists.append(l)
                case .failure(let e)?: errors.append((active[i].0.name, e))
                case nil: break
                }
            }
            guard !Task.isCancelled, lastQuery == q else { return }
            // interleave providers so both show up at the top
            var merged: [OnlineTrack] = [], seen = Set<String>()
            let longest = lists.map(\.count).max() ?? 0
            for i in 0..<longest { for l in lists where i < l.count && seen.insert(l[i].id).inserted { merged.append(l[i]) } }
            for t in merged { known[Self.rowID(t)] = t }
            results = merged
            warnings = errors.map { "\($0.0): \(Self.message($0.1))" }
            if lists.isEmpty, let first = errors.first {
                switch first.1 {
                case .offline: phase = .offline
                case .invalidKey: phase = .invalidKey(first.0)
                case .rateLimited: phase = .rateLimited
                default: phase = .failed(Self.message(first.1))
                }
            } else {
                phase = .loaded
                cache[q] = (Date(), merged, warnings)
            }
        }
    }

    static func message(_ e: OnlineAudioError) -> String {
        switch e {
        case .offline: return tr("online.error.offline")
        case .invalidKey: return tr("online.error.key")
        case .rateLimited: return tr("online.error.rate")
        case .server(let c):   // BUG-ERROR-COPY: the HTTP code goes to the log, not the message
            EngineLog.error("online music: HTTP \(c)")
            return tr("online.error.server")
        case .decoding: return tr("online.error.decoding")
        case .badAudio: return tr("online.error.audio")
        }
    }

    // MARK: Rows

    static func rowID(_ t: OnlineTrack) -> String { "online.\(t.provider).\(t.remoteID)" }

    func item(_ t: OnlineTrack, store: EditorStore) -> LibraryItem {
        let id = Self.rowID(t)
        let provider = providers.first { $0.id == t.provider }?.name ?? t.provider
        var sub: [String] = [t.artist, Timecode.shortDuration(Time(t.duration))]
        if let b = t.bpm { sub.append(tr("audio.lib.bpm", Int(b.rounded()))) }
        sub.append(provider)
        let installed = store.mediaBin.media.contains { trackID(of: $0.url) == t.id && store.usedMediaIDs.contains($0.id) }
        var details: [(String, String)] = [(tr("audio.license.duration"), Timecode.shortDuration(Time(t.duration)))]
        if let b = t.bpm { details.append((tr("audio.license.bpm"), "\(Int(b.rounded()))")) }
        if !t.tags.isEmpty { details.append((tr("online.license.tags"), t.tags.prefix(6).joined(separator: ", "))) }
        let license = LibraryLicense(licenseName: t.license.name, licenseURL: t.license.url, author: t.artist, sourceName: provider,
                                     sourcePage: t.pageURL.absoluteString, retrieved: t.retrieved, details: details,
                                     credit: t.license.requiresAttribution ? t.attribution : nil)
        let art: LibraryArt
        if let a = t.artworkURL, t.provider != "freesound" {
            let http = http
            art = .async(key: a.absoluteString, load: {
                guard let (d, s) = try? await http.get(URLRequest(url: a)), s == 200,
                      let src = CGImageSourceCreateWithData(d as CFData, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: 160] as CFDictionary)
            }, placeholder: "music.note")
        } else {
            art = .cover(t.kind == .music ? AudioCovers.colors(t.tags.first ?? t.title) : AudioCovers.sfx(""),
                         symbol: t.kind == .music ? "music.note" : "waveform")
        }
        return LibraryItem(id: id, title: t.title, subtitle: sub.joined(separator: " · "),
                           keywords: t.tags + [t.artist, provider, tr("online.group")], art: art,
                           payload: OnlineAudioDrop.payload(t), added: installed, busy: downloading.contains(id),
                           playing: LibraryAudioPreview.shared.playingID == id,
                           add: { [weak self, store] in self?.use(t, store: store) },
                           click: { [weak self] in self?.preview(t) },
                           license: license)
    }

    /// Favourited / recently used online tracks (hidden "online.saved" section).
    func savedItems(store: EditorStore) -> [LibraryItem] {
        saved.values.sorted { $0.title < $1.title }.map { item($0, store: store) }
    }

    /// Keeps (and persists) the tracks whose rows are favourites / recents.
    func keepSaved(_ ids: [String]) {
        var next: [String: OnlineTrack] = [:]
        for id in ids where id.hasPrefix("online.") { if let t = known[id] ?? saved[id] { next[id] = t } }
        guard Set(next.keys) != Set(saved.keys) else { return }
        saved = next
        if !mocked { Self.storeSaved(next) }
    }

    // MARK: Preview / use

    func preview(_ t: OnlineTrack) {
        let id = Self.rowID(t)
        let http = http
        if OnlineAudioDownloads.isCached(t) {
            let u = OnlineAudioDownloads.cachedURL(t)
            LibraryAudioPreview.shared.toggle(id) { u }
            return
        }
        LibraryAudioPreview.shared.stream(id, url: t.previewURL, duration: t.duration) {
            try? await OnlineAudioDownloads.download(t, http: http)
        }
    }

    /// Downloads once, copies into the project's media folder (+ license sidecar) and inserts at `time` (playhead).
    func use(_ t: OnlineTrack, store: EditorStore, at time: Time? = nil, target: InsertTarget = .automatic) {
        let id = Self.rowID(t)
        guard !downloading.contains(id) else { return }
        let at = time ?? store.transport.playhead
        downloading.insert(id)
        known[id] = t
        let http = http
        let dir = store.packageURL?.appendingPathComponent("media", isDirectory: true)
            ?? MontagePaths.draftsDirectory.appendingPathComponent("Online audio", isDirectory: true)
        Task {
            defer { downloading.remove(id) }
            do {
                let cached = try await OnlineAudioDownloads.download(t, http: http)
                let file = try await Task.detached { try OnlineAudioDownloads.install(cached, track: t, into: dir) }.value
                sidecarIDs[file] = t.id
                let asset = try await store.libraryAsset(file, name: t.title)
                store.addToTimeline(asset.id, at: at, target: target)
                AssetLibraryStore.shared.noteUsed("audio", id)
                if t.license.requiresAttribution { store.showToast(tr("online.toast.credit", t.artist)) }
            } catch {
                store.showToast(Self.message(OnlineAudioError.from(error)), error: true)
            }
        }
    }

    @PerceptionIgnored private var sidecarIDs: [URL: String] = [:]
    /// "provider:id" of a file installed by `use` (from its license sidecar, read once per file).
    func trackID(of url: URL) -> String? {
        if let v = sidecarIDs[url] { return v.isEmpty ? nil : v }
        let v = url.pathExtension == "mp3" || url.pathExtension == "wav" ? OnlineAudioDownloads.readSidecar(url)?.id ?? "" : ""
        sidecarIDs[url] = v
        return v.isEmpty ? nil : v
    }

    // MARK: Persistence

    static var savedURL: URL { MontagePaths.supportDirectory.appendingPathComponent("online_audio_saved.json") }
    static func loadSaved() -> [String: OnlineTrack] {
        (try? Data(contentsOf: savedURL)).flatMap { try? JSONDecoder().decode([String: OnlineTrack].self, from: $0) } ?? [:]
    }
    static func storeSaved(_ s: [String: OnlineTrack]) {
        try? FileManager.default.createDirectory(at: savedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(s).write(to: savedURL, options: .atomic)
    }

    var dump: [String: Any] {
        ["phase": phase.name, "results": results.map(Self.rowID), "count": results.count, "warnings": warnings,
         "downloading": Array(downloading).sorted(), "keys": configuredProviders, "enabled": enabled, "mood": mood, "genre": genre,
         "sfxCategory": sfxCategory, "saved": saved.keys.sorted(),
         "requests": (http as? MockOnlineAudioHTTP)?.requests.filter { !$0.isFileURL }.count ?? -1]
    }
}

/// Timeline drops of online rows ("montage-online:<provider>:<id>").
@MainActor
enum OnlineAudioDrop {
    static func payload(_ t: OnlineTrack) -> String { "montage-online:\(t.id)" }

    static func track(_ s: String) -> OnlineTrack? {
        guard s.hasPrefix("montage-online:") else { return nil }
        let id = String(s.dropFirst(15))
        let st = OnlineAudioState.shared
        return st.known.values.first { $0.id == id } ?? st.saved.values.first { $0.id == id }
    }

    static func handle(_ s: String, store: EditorStore, time: Time, target: InsertTarget) -> Bool {
        guard let t = track(s) else { return false }
        OnlineAudioState.shared.use(t, store: store, at: time, target: target)
        return true
    }

    static func duration(_ s: String) -> Time? { track(s).map { Time($0.duration) } }
}

/// Content of the Online rail entries: browse chips, states (setup / offline / errors), result rows.
struct OnlineAudioView: View {
    let store: EditorStore
    let nav: String
    private var state: OnlineAudioState { OnlineAudioState.shared }

    var body: some View {
        WithPerceptionTracking {
            let text = AssetPanelState.shared.query["audio"] ?? ""
            VStack(alignment: .leading, spacing: 0) {
                chips
                content(text: text)
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .task(id: LoadKey(nav: nav, text: text, mood: state.mood, genre: state.genre, cat: state.sfxCategory, keys: state.keysVersion)) {
                state.load(nav: nav, text: text)
            }
            .testID("online.view")
        }
    }

    struct LoadKey: Hashable { let nav, text, mood, genre, cat: String; let keys: Int }

    @ViewBuilder var chips: some View {
        switch nav {
        case OnlineAudioState.navMoods:
            ChipRow(ids: OnlineAudioCatalog.moods, title: { tr("music.mood.\($0)") }, selection: state.mood, idPrefix: "online.mood") { state.mood = $0 }
        case OnlineAudioState.navGenres:
            ChipRow(ids: OnlineAudioCatalog.genres, title: { tr("online.genre.\($0)") }, selection: state.genre, idPrefix: "online.genre") { state.genre = $0 }
        case OnlineAudioState.navSFX:
            ChipRow(ids: [""] + OnlineAudioCatalog.sfxCategories, title: { $0.isEmpty ? tr("online.sfx.popular") : tr("sfx.category.\($0)") },
                    selection: state.sfxCategory, idPrefix: "online.sfxcat") { state.sfxCategory = $0 }
        default: EmptyView()
        }
    }

    var title: String {
        let text = AssetPanelState.shared.query["audio"] ?? ""
        if !text.trimmingCharacters(in: .whitespaces).isEmpty { return tr("online.results", text) }
        switch nav {
        case OnlineAudioState.navTrending: return tr("online.nav.trending")
        case OnlineAudioState.navMoods: return tr("music.mood.\(state.mood)")
        case OnlineAudioState.navGenres: return tr("online.genre.\(state.genre)")
        case OnlineAudioState.navSFX: return state.sfxCategory.isEmpty ? tr("online.sfx.popular") : tr("sfx.category.\(state.sfxCategory)")
        default: return tr("online.nav.forYou")
        }
    }

    @ViewBuilder func content(text: String) -> some View {
        switch state.phase {
        case .disabled:
            StateCard(symbol: "wifi.slash", title: tr("online.disabled.title"), message: tr("online.disabled.message"),
                      primary: (tr("online.openSettings"), { OnlineAudioState.openSettings?() }), id: "online.state.disabled")
        case .noKey:
            StateCard(symbol: "key.horizontal", title: tr("online.setup.title"), message: tr("online.setup.message"),
                      primary: (tr("online.setup.button"), { OnlineAudioState.openSettings?() }),
                      secondary: (tr("online.browseOffline"), { AssetPanelState.shared.nav["audio"] = AudioLibrarySections.defaultNav }),
                      id: "online.state.noKey")
        case .offline:
            StateCard(symbol: "wifi.exclamationmark", title: tr("online.offline.title"), message: tr("online.offline.message"),
                      primary: (tr("online.retry"), { state.load(nav: nav, text: text, force: true) }),
                      secondary: (tr("online.browseOffline"), { AssetPanelState.shared.nav["audio"] = AudioLibrarySections.defaultNav }),
                      id: "online.state.offline")
        case .invalidKey(let p):
            StateCard(symbol: SFSymbolCompat.compat("key.slash"), title: tr("online.badKey.title", p), message: tr("online.badKey.message"),
                      primary: (tr("online.openSettings"), { OnlineAudioState.openSettings?() }), id: "online.state.invalidKey")
        case .rateLimited:
            StateCard(symbol: "hourglass", title: tr("online.error.rate"), message: "",
                      primary: (tr("online.retry"), { state.load(nav: nav, text: text, force: true) }), id: "online.state.rate")
        case .failed(let m):
            StateCard(symbol: "exclamationmark.triangle", title: tr("online.failed.title"), message: m,
                      primary: (tr("online.retry"), { state.load(nav: nav, text: text, force: true) }), id: "online.state.failed")
        case .idle, .loading, .loaded:
            if state.phase == .loading && state.results.isEmpty {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(loc: "online.loading").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .testID("online.state.loading")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if !state.warnings.isEmpty {
                        Text(verbatim: state.warnings.joined(separator: " · ")).font(Theme.Fonts.hint).foregroundStyle(Theme.warning)
                            .lineLimit(2).padding(.horizontal, 12).padding(.bottom, 4)
                    }
                    LibraryItemsView(tab: "audio", namespace: "audio", title: title,
                                     items: state.results.map { state.item($0, store: store) }, style: .list,
                                     empty: tr("online.empty"))
                        .opacity(state.phase == .loading ? 0.5 : 1)
                }
            }
        }
    }

    var footer: some View {
        let kind: ContentItem.Kind = nav == OnlineAudioState.navSFX ? .sfx : .music
        let names = state.providers.filter { state.key($0.id) != nil && $0.kinds.contains(kind) }.map(\.name)
        return HStack(spacing: 4) {
            Image(systemName: "globe").font(.system(size: 9))
            Text(verbatim: names.isEmpty ? tr("online.footer.none") : tr("online.footer", names.joined(separator: " · ")))
                .lineLimit(1)
        }
        .font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 12).padding(.vertical, 5)
    }
}

/// Horizontal chips (moods / genres / sound categories).
struct ChipRow: View {
    let ids: [String]
    let title: (String) -> String
    let selection: String
    let idPrefix: String
    let select: (String) -> Void

    var body: some View {
        WithPerceptionTracking {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ids, id: \.self) { id in
                        WithPerceptionTracking {
                            let on = id == selection
                            Button { select(id) } label: {
                                Text(verbatim: title(id)).font(.system(size: 11.5, weight: on ? .semibold : .regular))
                                    .foregroundStyle(on ? Theme.onAccent : Theme.textPrimary)
                                    .padding(.horizontal, 10).frame(height: 24)
                                    .background(on ? Theme.accent : Theme.control, in: Capsule())   // round 13: was a neutral #333
                            }
                            .buttonStyle(.plain)
                            .testID("\(idPrefix).\(id.isEmpty ? "popular" : id)")
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.bottom, 6)
        }
    }
}

/// Centered empty / error state with up to two actions.
struct StateCard: View {
    let symbol: String
    let title: String
    let message: String
    var primary: (String, () -> Void)? = nil
    var secondary: (String, () -> Void)? = nil
    let id: String

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(Theme.textTertiary)
                Text(verbatim: title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary).multilineTextAlignment(.center)
                if !message.isEmpty {
                    Text(verbatim: message).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                if let p = primary {
                    Button(p.0) { p.1() }.buttonStyle(AccentButtonStyle()).testID("\(id).primary")
                }
                if let s = secondary {
                    Button { s.1() } label: { Text(verbatim: s.0).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.accent) }
                        .buttonStyle(.plain).testID("\(id).secondary")
                }
            }
            .padding(24)
            .frame(maxWidth: 360)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .testID(id)
        }
    }
}
