import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import MontageCore
import MontageEngine

/// Asset panel ▸ Audio (UX.md §3.4): sub-nav Yours · Sound effects · Extracted. List rows (not grid): cover · title /
/// "category · 00:02" · ▶ preview on click · ⊕ add at the playhead.
struct AudioLibraryView: View {
    let store: EditorStore
    @Bindable private var ui = AudioLibraryUIState.shared
    @State private var preview = AudioPreviewPlayer()

    var body: some View {
        HStack(spacing: 0) {
            SubNav(items: [("yours", tr("audio.lib.yours")), ("music", tr("audio.lib.music")), ("sfx", tr("audio.lib.sfx")),
                           ("extracted", tr("audio.lib.extracted"))],
                   selection: $ui.section)
            Group {
                switch ui.section {
                case "music": musicList
                case "sfx": sfxList
                case "extracted": extractedList
                default: yoursList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onDisappear { preview.stop() }
    }

    /// Music: the built-in procedural royalty-free pack, by genre (synthesized on first ▶ / ⊕, then cached).
    private var musicList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(MusicLibrary.genres, id: \.self) { g in
                    Text(loc: "music.genre.\(g)").font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary).padding(.top, 4)
                    ForEach(MusicLibrary.all.filter { $0.category == g }) { d in
                        AudioRow(title: tr(d.nameKey), subtitle: "\(tr("music.genre.\(g)")) · \(Timecode.shortDuration(Time(d.duration)))",
                                 symbol: "music.note", playing: preview.playingID == d.id || ui.rendering == d.id, testID: "audio.music.\(d.id)",
                                 onPlay: { Task { if let u = await musicFile(d) { preview.toggle(d.id, u) } } },
                                 onAdd: { Task { if let u = await musicFile(d) { store.importFiles([Self.namedFile(u, d)], thenInsertAt: store.transport.playhead) } } })
                    }
                }
            }
            .padding(10)
        }
    }

    /// Synthesizes a track off the main thread (shows the row as busy meanwhile).
    private func musicFile(_ d: SoundEffectDescriptor) async -> URL? {
        if !FileManager.default.fileExists(atPath: SoundEffects.url(for: d).path) { ui.rendering = d.id }
        defer { if ui.rendering == d.id { ui.rendering = nil } }
        return await Self.sfxFile(d)
    }

    private var sfxList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(SoundEffects.categories, id: \.self) { cat in
                    Text(loc: "sfx.category.\(cat)").font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary).padding(.top, 4)
                    ForEach(SoundEffects.all.filter { $0.category == cat }) { d in
                        AudioRow(title: tr(d.nameKey), subtitle: "\(tr("sfx.category.\(cat)")) · \(Timecode.shortDuration(Time(d.duration)))",
                                 symbol: "waveform", playing: preview.playingID == d.id,
                                 onPlay: { Task { if let u = await Self.sfxFile(d) { preview.toggle(d.id, u) } } },
                                 onAdd: { Task { if let u = await Self.sfxFile(d) { store.importFiles([Self.namedFile(u, d)], thenInsertAt: store.transport.playhead) } } })
                    }
                }
            }
            .padding(10)
        }
    }

    /// Yours: imported music as 56 pt rows (waveform cover, "artist · 02:09", ▶ on hover / click to preview, ⊕ adds at
    /// the playhead, drag to the timeline), with Import on top and Finder drops (CapCut [60], UX_GAPS W8-1).
    private var yoursList: some View {
        let items = store.project.media.filter { $0.kind == .audio && !Self.isExtracted($0) }
        return VStack(alignment: .leading, spacing: 8) {
            Button { ImportPanel.run(store) } label: {
                Label(tr("media.import"), systemImage: "plus").font(.system(size: 12)).frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
            .testID("audio.import")
            if items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "music.note").font(.system(size: 26)).foregroundStyle(Theme.textTertiary)
                    Text(loc: "audio.lib.yours.empty").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { ImportPanel.run(store) }
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, a in
                            YoursAudioRow(store: store, asset: a, index: i, playing: preview.playingID == a.id.description,
                                          onPlay: { preview.toggle(a.id.description, a.url) })
                        }
                    }
                }
            }
        }
        .padding(10)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadURLs(providers) { store.importMedia($0) }
            return true
        }
    }

    static func isExtracted(_ a: MediaAsset) -> Bool { a.url.lastPathComponent.hasSuffix(" (audio).m4a") }

    private var extractedList: some View {
        let items = store.project.media.filter { $0.kind == .audio && Self.isExtracted($0) }
        return VStack(alignment: .leading, spacing: 10) {
            Button { pickVideos() } label: {
                Label(tr("audio.extract.button"), systemImage: "film.stack").frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
            Text(loc: "audio.extract.hint").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(items) { a in
                        AudioRow(title: a.name, subtitle: Timecode.shortDuration(a.duration), symbol: "music.note",
                                 playing: preview.playingID == a.id.description,
                                 onPlay: { preview.toggle(a.id.description, a.url) },
                                 onAdd: { _ = store.addToTimeline(a.id) })
                    }
                }
            }
        }
        .padding(10)
    }

    /// Synthesized off the main thread on first use, then cached on disk.
    static func sfxFile(_ d: SoundEffectDescriptor) async -> URL? {
        await Task.detached(priority: .userInitiated) { try? SoundEffects.file(d) }.value
    }

    /// The cached file under its localized title ("Sunrise.wav", hard link), so the imported media and its clip are
    /// named like the library row instead of "music.sunrise-v1".
    static func namedFile(_ u: URL, _ d: SoundEffectDescriptor) -> URL {
        let title = tr(d.nameKey).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let dir = u.deletingLastPathComponent().appendingPathComponent("named-v\(SoundEffects.version)", isDirectory: true)
            .appendingPathComponent(d.id, isDirectory: true)
        let dst = dir.appendingPathComponent(title).appendingPathExtension(u.pathExtension)
        if FileManager.default.fileExists(atPath: dst.path) { return dst }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            do { try FileManager.default.linkItem(at: u, to: dst) } catch { try FileManager.default.copyItem(at: u, to: dst) }
            return dst
        } catch { return u }
    }

    private func pickVideos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.message = tr("audio.extract.button")
        if panel.runModal() == .OK { store.extractAudio(fromFiles: panel.urls) }
    }
}

/// Remembers the audio library sub-section across tab switches.
@MainActor @Observable
final class AudioLibraryUIState {
    static let shared = AudioLibraryUIState()
    var section = "yours"
    /// Music track being synthesized (first use).
    var rendering: String?
}

/// A "Yours" row: an imported audio file with its real waveform as the cover and the file's artist tag.
struct YoursAudioRow: View {
    let store: EditorStore
    let asset: MediaAsset
    let index: Int
    let playing: Bool
    let onPlay: () -> Void
    @State private var wave: Waveform?
    @State private var artist: String?
    @State private var showInfo = false

    var body: some View {
        let dur = Timecode.shortDuration(asset.duration)
        AudioRow(title: asset.name, subtitle: artist.map { "\($0) · \(dur)" } ?? dur, symbol: "music.note", playing: playing,
                 waveform: wave, testID: "audio.row.\(index)", onPlay: onPlay, onAdd: { _ = store.addToTimeline(asset.id) })
            .onDrag { NSItemProvider(object: DragPayload.media(asset.id) as NSString) }
            .contextMenu { MediaCardMenu(store: store, asset: asset, showInfo: $showInfo) }
            .popover(isPresented: $showInfo) { MediaInfoView(asset: asset) }
            .task(id: asset.id) {
                wave = WaveformCache.shared.cached(asset)
                if wave == nil { wave = await WaveformCache.shared.waveform(asset) }
                artist = await Self.artist(asset.url)
            }
    }

    /// ID3 / iTunes artist of the file, if tagged.
    nonisolated static func artist(_ url: URL) async -> String? {
        let items = (try? await AVURLAsset(url: url).load(.commonMetadata)) ?? []
        guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtist).first,
              let s = try? await item.load(.stringValue), !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }
}

/// Mini waveform drawn from the cached peaks (cover of audio rows).
struct WaveformCover: View {
    let waveform: Waveform
    var body: some View {
        Canvas { ctx, size in
            let bars = 12, gap: CGFloat = 1.5
            let w = (size.width - gap * CGFloat(bars - 1)) / CGFloat(bars)
            let total = Double(waveform.peaks.count) / Double(Waveform.peaksPerSecond)
            let maxPeak = max(waveform.peak(from: 0, to: total), 0.05)
            for i in 0..<bars {
                // a short window per bar (whole-segment peaks of music are all near full scale)
                let a = total * (Double(i) + 0.5) / Double(bars)
                let v = max(0.12, waveform.peak(from: a, to: a + 0.03) / maxPeak)
                let h = size.height * CGFloat(v) * 0.85
                let r = CGRect(x: CGFloat(i) * (w + gap), y: (size.height - h) / 2, width: w, height: h)
                ctx.fill(Path(roundedRect: r, cornerRadius: w / 2), with: .color(Color(red: 0.45, green: 0.75, blue: 1).opacity(0.9)))
            }
        }
        .padding(7)
    }
}

struct AudioRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let playing: Bool
    var waveform: Waveform? = nil
    var testID: String? = nil
    let onPlay: () -> Void
    let onAdd: () -> Void
    @State private var hover = false
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color(red: 0.09, green: 0.18, blue: 0.33))
                if let waveform, !waveform.peaks.isEmpty {
                    WaveformCover(waveform: waveform).opacity(playing || hover ? 0.35 : 1)
                    if playing || hover {
                        Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 14)).foregroundStyle(.white)
                    }
                } else {
                    Image(systemName: playing ? "pause.fill" : (hover ? "play.fill" : symbol)).font(.system(size: 14)).foregroundStyle(.white)
                }
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.system(size: 13)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(verbatim: subtitle).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer()
            Button(action: onAdd) {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22).background(Theme.accent, in: Circle())
            }
            .buttonStyle(.plain).help(tr("audio.lib.add"))
            .testID((testID ?? "audio.row") + ".add")
        }
        .padding(8)
        .frame(height: 56)
        .background(Color(white: 0.165), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onPlay)
        .testID(testID ?? "audio.row")
    }
}

/// One-at-a-time preview player for library rows.
@MainActor @Observable
final class AudioPreviewPlayer {
    private var player: AVAudioPlayer?
    var playingID: String?
    func toggle(_ id: String, _ url: URL) {
        if playingID == id { stop(); return }
        stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
        playingID = player == nil ? nil : id
        let d = player?.duration ?? 0
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(d + 0.05))
            if self?.playingID == id { self?.playingID = nil }
        }
    }
    func stop() { player?.stop(); player = nil; playingID = nil }
}
