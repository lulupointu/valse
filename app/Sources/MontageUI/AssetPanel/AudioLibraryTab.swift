@preconcurrency import AVFoundation
import SwiftUI
import AppKit
import MontageCore
import MontageEngine

/// Asset panel ▸ Audio (UX.md §3.4, AU-001/002/003): Yours · Extracted · Music folder · Favorites · Recent ·
/// Music ▾ (locally synthesized royalty-free tracks by genre) · Sound effects ▾. List rows: cover · title /
/// "artist · genre · 00:45" · ☆ · ⊕; click = preview (▶/❚❚, progress over the waveform), double-click / ⊕ / drag adds.
struct AudioLibraryTab: View {
    let store: EditorStore
    private var preview: LibraryAudioPreview { LibraryAudioPreview.shared }
    private var rendering: AudioLibraryRendering { AudioLibraryRendering.shared }

    var body: some View {
        let usedURLs = Set(store.mediaBin.media.filter { m in store.usedMediaIDs.contains(m.id) }.map(\.url.standardizedFileURL))
        let bin = LibrarySection(id: "audio.bin", title: tr("audio.lib.imported"), items: store.mediaBin.media.filter { $0.kind == .audio }.map {
            MediaBinView(store: store, kinds: [.audio], tab: "audio").audioRowItem($0, used: store.usedMediaIDs.contains($0.id))
        }, inRail: false)
        LibraryBrowser(tab: "audio", namespace: "audio", sections: [bin] + AudioLibrarySections.music(store, usedURLs) + sfxSections(usedURLs),
                       style: .list, searchPlaceholder: tr("audio.search"),
                       customNav: [("yours", tr("audio.lib.imported")), ("extracted", tr("audio.lib.extracted")),
                                   ("folder", tr("audio.lib.folder"))],
                       customContent: { nav in
                           switch nav {
                           case "extracted": return AnyView(ExtractedAudioView(store: store))
                           case "folder": return AnyView(LocalMusicView(store: store))
                           default: return AnyView(MediaTab(store: store, kinds: [.audio]))
                           }
                       },
                       defaultNav: AudioLibrarySections.defaultNav, yoursGroup: tr("asset.nav.yours"))
        .onDisappear { preview.stop() }
    }

    func sfxSections(_ used: Set<URL>) -> [LibrarySection] {
        SoundEffects.categories.map { cat in
            LibrarySection(id: "sfx.\(cat)", title: tr("sfx.category.\(cat)"),
                           items: SoundEffects.all.filter { $0.category == cat }.map { sfxItem($0, used) }, group: tr("audio.lib.sfx"))
        }
    }

    func sfxItem(_ d: SoundEffectDescriptor, _ used: Set<URL>) -> LibraryItem {
        let id = "sfx.\(d.id)"
        return LibraryItem(id: id, title: tr(d.nameKey),
                           subtitle: "\(tr("sfx.category.\(d.category)")) · \(Timecode.shortDuration(Time(d.duration)))",
                           keywords: [d.id, d.category, tr("audio.lib.sfx")],
                           art: .cover(AudioCovers.sfx(d.category), symbol: "waveform"),
                           payload: AudioLibraryPayload.sfx(d.id),
                           added: used.contains(SoundEffects.url(for: d).standardizedFileURL),
                           busy: rendering.busy.contains(id), playing: preview.playingID == id,
                           add: { [store] in AudioLibraryRendering.shared.add(id, name: tr(d.nameKey), store: store) { try SoundEffects.file(d) } },
                           click: { LibraryAudioPreview.shared.toggle(id) { try SoundEffects.file(d) } })
    }
}

/// Library payloads for the timeline ("montage-music:<id>", "montage-sfx:<id>").
enum AudioLibraryPayload {
    static func music(_ id: String) -> String { "montage-music:\(id)" }
    static func sfx(_ id: String) -> String { "montage-sfx:\(id)" }

    static func file(_ url: URL) -> String { "montage-file:\(url.path)" }

    static let dropHandler: LibraryDropHandlers.Handler = { s, store, time, target in
        if s.hasPrefix("montage-sfx:"), let d = SoundEffects.all.first(where: { $0.id == String(s.dropFirst(12)) }) {
            AudioLibraryRendering.shared.add("sfx.\(d.id)", name: tr(d.nameKey), store: store, at: time, target: target) { try SoundEffects.file(d) }
            return true
        }
        if s.hasPrefix("montage-file:") {
            store.importFiles([URL(fileURLWithPath: String(s.dropFirst(13)))], thenInsertAt: time, target: target)
            return true
        }
        return AudioLibrarySections.handleDrop(s, store: store, time: time, target: target)
    }

    static let dropDuration: LibraryDropHandlers.Duration = { s, _ in
        if s.hasPrefix("montage-sfx:") { return SoundEffects.all.first { $0.id == String(s.dropFirst(12)) }.map { Time($0.duration) } }
        return AudioLibrarySections.dropDuration(s)
    }
}

/// Synthesizes library audio off-main once, then imports it and inserts it (like CapCut's download-then-add).
@MainActor @Observable
final class AudioLibraryRendering {
    static let shared = AudioLibraryRendering()
    private(set) var busy: Set<String> = []

    /// Returns the rendered file (rendering off-main on first use).
    func file(_ id: String, _ make: @escaping @Sendable () throws -> URL) async -> URL? {
        busy.insert(id)
        defer { busy.remove(id) }
        return await Task.detached(priority: .userInitiated) { try? make() }.value
    }

    /// Renders (once), puts the file in the bin under `name` (reused if already there) and inserts it at `time`
    /// (default: the playhead when called).
    func add(_ id: String, name: String, store: EditorStore, at time: Time? = nil, target: InsertTarget = .automatic,
             _ make: @escaping @Sendable () throws -> URL) {
        let at = time ?? store.transport.playhead
        Task {
            guard let url = await file(id, make), let asset = try? await store.libraryAsset(url, name: name) else {
                store.showToast(tr("audio.lib.renderFailed"), error: true); return
            }
            store.addToTimeline(asset.id, at: at, target: target)
            AssetLibraryStore.shared.noteUsed("audio", id)
        }
    }
}

/// One-at-a-time preview player for library rows, with waveform peaks for the progress strip.
@MainActor @Observable
final class LibraryAudioPreview {
    static let shared = LibraryAudioPreview()
    private(set) var playingID: String?
    private(set) var peaks: [String: [Float]] = [:]
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var endTask: Task<Void, Never>?

    var currentTime: Double { player?.currentTime ?? 0 }
    var duration: Double { player?.duration ?? 0 }

    func toggle(_ id: String, _ make: @escaping @Sendable () throws -> URL) {
        if playingID == id { stop(); return }
        stop()
        Task {
            guard let url = await AudioLibraryRendering.shared.file(id, make) else { return }
            play(id, url)
        }
    }

    func play(_ id: String, _ url: URL) {
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        player = p
        p.play()
        playingID = id
        if peaks[id] == nil {
            Task {
                let pk = await Task.detached(priority: .utility) { AudioPeaks.compute(url, bars: 120) }.value
                peaks[id] = pk
            }
        }
        endTask = Task { [weak self] in
            while let self, self.playingID == id, let pl = self.player, pl.isPlaying {
                try? await Task.sleep(for: .milliseconds(200))
            }
            if let self, self.playingID == id { self.playingID = nil; self.player = nil }
        }
    }

    func seek(fraction: Double) {
        guard let p = player else { return }
        p.currentTime = max(0, min(1, fraction)) * p.duration
    }

    func stop() {
        endTask?.cancel(); endTask = nil
        player?.stop(); player = nil; playingID = nil
    }
}

/// Peak bars of an audio file (preview strip).
nonisolated enum AudioPeaks {
    static func compute(_ url: URL, bars: Int) -> [Float] {
        guard let f = try? AVAudioFile(forReading: url), f.length > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 65536) else { return [] }
        let total = Double(f.length)
        var out = [Float](repeating: 0, count: bars)
        var pos: AVAudioFramePosition = 0
        while pos < f.length {
            do { try f.read(into: buf) } catch { break }
            let n = Int(buf.frameLength)
            if n == 0 { break }
            if let ch = buf.floatChannelData {
                for c in 0..<Int(buf.format.channelCount) {
                    let d = ch[c]
                    var i = 0
                    while i < n {
                        let b = min(bars - 1, Int(Double(pos + AVAudioFramePosition(i)) / total * Double(bars)))
                        out[b] = max(out[b], abs(d[i]))
                        i += 8
                    }
                }
            }
            pos += AVAudioFramePosition(n)
        }
        let m = max(out.max() ?? 1, 0.001)
        return out.map { $0 / m }
    }
}

/// Waveform with the played part in accent; click to seek.
struct AudioPreviewStrip: View {
    let id: String
    private var preview: LibraryAudioPreview { LibraryAudioPreview.shared }
    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let pk = preview.peaks[id] ?? []
            let progress = preview.duration > 0 ? preview.currentTime / preview.duration : 0
            GeometryReader { g in
                Canvas { ctx, size in
                    let n = max(1, pk.count)
                    let w = size.width / CGFloat(n)
                    for (i, p) in pk.enumerated() {
                        let h = max(1.5, CGFloat(p) * size.height)
                        let r = CGRect(x: CGFloat(i) * w, y: (size.height - h) / 2, width: max(1, w * 0.6), height: h)
                        ctx.fill(Path(r), with: .color(Double(i) / Double(n) <= progress ? Theme.accent : Color(white: 0.45)))
                    }
                    if pk.isEmpty {
                        ctx.fill(Path(CGRect(x: 0, y: size.height / 2 - 1, width: size.width * progress, height: 2)), with: .color(Theme.accent))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { p in preview.seek(fraction: Double(p.x / max(1, g.size.width))) }
            }
        }
        .frame(height: 20)
        .testID("audio.preview.strip")
    }
}

/// Cover colours per category / genre.
enum AudioCovers {
    static let palette: [[RGBA]] = [
        [RGBA(hex: 0x6A5AE0), RGBA(hex: 0x2E2A6B)], [RGBA(hex: 0xF08A5D), RGBA(hex: 0x8C2F5C)], [RGBA(hex: 0x2BB3A3), RGBA(hex: 0x14465C)],
        [RGBA(hex: 0xE9C46A), RGBA(hex: 0x9C5A1C)], [RGBA(hex: 0x4D9DE0), RGBA(hex: 0x1C2D6B)], [RGBA(hex: 0xD65DB1), RGBA(hex: 0x4B1D6B)],
        [RGBA(hex: 0x7BC67E), RGBA(hex: 0x1D5B3A)], [RGBA(hex: 0xA0A0B8), RGBA(hex: 0x30304A)], [RGBA(hex: 0xFF6F61), RGBA(hex: 0x6B1F2A)],
        [RGBA(hex: 0x5BC0EB), RGBA(hex: 0x203A72)],
    ]
    static func colors(_ key: String) -> [RGBA] {
        let h = key.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return palette[Int(h % UInt32(palette.count))]
    }
    static func sfx(_ cat: String) -> [RGBA] { [RGBA(hex: 0x1F3550), RGBA(hex: 0x0E1A2B)] }
}

/// Audio ▸ Extracted: "Extract audio from a video" + the extracted items (W8's flow, AU-003).
struct ExtractedAudioView: View {
    let store: EditorStore
    var body: some View {
        let items = store.mediaBin.media.filter { $0.kind == .audio && $0.url.lastPathComponent.hasSuffix(" (audio).m4a") }
        VStack(alignment: .leading, spacing: 10) {
            Button { pickVideos() } label: {
                Label(tr("audio.extract.button"), systemImage: "film.stack").frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
            .testID("audio.extract")
            Text(loc: "audio.extract.hint").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            if items.isEmpty {
                EmptyState(symbol: "music.note", title: tr("audio.extract.empty"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(items) { a in
                            LibraryRow(tab: "audio", namespace: "audio", item: item(a))
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    func item(_ a: MediaAsset) -> LibraryItem {
        let id = "media.\(a.id)"
        let url = a.url
        return LibraryItem(id: id, title: a.name, subtitle: Timecode.shortDuration(a.duration), art: .cover(AudioCovers.colors(a.name), symbol: "music.note"),
                           payload: DragPayload.media(a.id), added: store.usedMediaIDs.contains(a.id),
                           playing: LibraryAudioPreview.shared.playingID == id,
                           add: { [store] in store.addToTimeline(a.id) },
                           click: { LibraryAudioPreview.shared.toggle(id) { url } })
    }

    private func pickVideos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.message = tr("audio.extract.button")
        if panel.runModal() == .OK { store.extractAudio(fromFiles: panel.urls) }
    }
}

/// The user's local music folder (default ~/Music), scanned off-main.
@MainActor @Observable
final class LocalMusicLibrary {
    static let shared = LocalMusicLibrary()
    static let defaultsKey = "montage.audio.musicFolder"
    nonisolated static let extensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "caf", "alac", "ogg"]
    nonisolated static let maxFiles = 3000

    struct Track: Identifiable, Sendable {
        let url: URL
        let title: String
        let folder: String
        let duration: Double
        var id: String { "file." + url.path }
    }

    var folder: URL {
        didSet { UserDefaults.standard.set(folder.path, forKey: Self.defaultsKey); scan() }
    }
    private(set) var tracks: [Track] = []
    private(set) var scanning = false
    @ObservationIgnored private var scannedFolder: URL?

    init() {
        if let env = ProcessInfo.processInfo.environment["MONTAGE_MUSIC_FOLDER"] { folder = URL(fileURLWithPath: env) }
        else if let p = UserDefaults.standard.string(forKey: Self.defaultsKey) { folder = URL(fileURLWithPath: p) }
        else { folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music") }
    }

    func scanIfNeeded() { if scannedFolder != folder { scan() } }

    func scan() {
        let root = folder
        scannedFolder = root
        scanning = true
        Task {
            let found = await Task.detached(priority: .utility) { Self.scan(root) }.value
            guard self.folder == root else { return }
            tracks = found
            scanning = false
        }
    }

    nonisolated static func scan(_ root: URL) -> [Track] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [Track] = []
        for case let u as URL in e {
            guard extensions.contains(u.pathExtension.lowercased()) else { continue }
            let d = (try? AVAudioFile(forReading: u)).map { Double($0.length) / max(1, $0.processingFormat.sampleRate) } ?? 0
            out.append(Track(url: u, title: u.deletingPathExtension().lastPathComponent,
                             folder: u.deletingLastPathComponent().lastPathComponent, duration: d))
            if out.count >= maxFiles { break }
        }
        return out.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

struct LocalMusicView: View {
    let store: EditorStore
    private var lib: LocalMusicLibrary { LocalMusicLibrary.shared }

    var body: some View {
        let q = AssetPanelState.shared.query["audio"] ?? ""
        let tracks = lib.tracks.filter { LibrarySearch.matches(fields: [$0.title, $0.folder], q) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                Text(verbatim: lib.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(tr("audio.folder.choose")) { choose() }.buttonStyle(SecondaryButtonStyle()).testID("audio.folder.choose")
                IconButton("arrow.clockwise", help: tr("audio.folder.rescan")) { lib.scan() }
            }
            if lib.scanning && lib.tracks.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tracks.isEmpty {
                EmptyState(symbol: "music.note.house", title: tr("audio.folder.empty"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(tracks) { t in LibraryRow(tab: "audio", namespace: "audio", item: item(t)).testID("asset.tile.\(t.id)") }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { lib.scanIfNeeded() }
    }

    func item(_ t: LocalMusicLibrary.Track) -> LibraryItem {
        let url = t.url
        return LibraryItem(id: t.id, title: t.title, subtitle: "\(t.folder) · \(Timecode.shortDuration(Time(t.duration)))",
                           art: .cover(AudioCovers.colors(t.folder), symbol: "music.note"),
                           payload: AudioLibraryPayload.file(url),
                           playing: LibraryAudioPreview.shared.playingID == t.id,
                           add: { [store] in store.importFiles([url], thenInsertAt: store.transport.playhead) },
                           click: { LibraryAudioPreview.shared.toggle(t.id) { url } })
    }

    func choose() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.directoryURL = lib.folder
        p.prompt = tr("audio.folder.choose")
        if p.runModal() == .OK, let u = p.url { lib.folder = u }
    }
}
