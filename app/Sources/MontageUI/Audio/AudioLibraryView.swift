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
            SubNav(items: [("yours", tr("audio.lib.yours")), ("sfx", tr("audio.lib.sfx")), ("extracted", tr("audio.lib.extracted"))],
                   selection: $ui.section)
            Group {
                switch ui.section {
                case "sfx": sfxList
                case "extracted": extractedList
                default: MediaTab(store: store, kinds: [.audio])
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onDisappear { preview.stop() }
    }

    private var sfxList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(SoundEffects.categories, id: \.self) { cat in
                    Text(loc: "sfx.category.\(cat)").font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary).padding(.top, 4)
                    ForEach(SoundEffects.all.filter { $0.category == cat }) { d in
                        AudioRow(title: tr(d.nameKey), subtitle: "\(tr("sfx.category.\(cat)")) · \(Timecode.shortDuration(Time(d.duration)))",
                                 symbol: "waveform", playing: preview.playingID == d.id,
                                 onPlay: { if let u = try? SoundEffects.file(d) { preview.toggle(d.id, u) } },
                                 onAdd: { if let u = try? SoundEffects.file(d) { store.importFiles([u], thenInsertAt: store.transport.playhead) } })
                    }
                }
            }
            .padding(10)
        }
    }

    private var extractedList: some View {
        let items = store.project.media.filter { $0.kind == .audio && $0.url.lastPathComponent.hasSuffix(" (audio).m4a") }
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
}

struct AudioRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let playing: Bool
    let onPlay: () -> Void
    let onAdd: () -> Void
    @State private var hover = false
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color(red: 0.09, green: 0.18, blue: 0.33))
                Image(systemName: playing ? "pause.fill" : (hover ? "play.fill" : symbol)).font(.system(size: 14)).foregroundStyle(.white)
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
        }
        .padding(8)
        .frame(height: 56)
        .background(Color(white: 0.165), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onPlay)
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
