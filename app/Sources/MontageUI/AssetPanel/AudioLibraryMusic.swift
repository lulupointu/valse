import SwiftUI
import MontageCore
import MontageEngine

/// Audio ▸ Music ▾: the locally synthesized royalty-free music library (`MusicLibrary`, AU-001 substitute), one rail
/// entry per genre; mood, tempo and instrument tags are searchable.
@MainActor
enum AudioLibrarySections {
    static var defaultNav: String { "group:" + tr("audio.lib.music") }

    static func music(_ store: EditorStore, _ used: Set<URL>) -> [LibrarySection] {
        let busy = AudioLibraryRendering.shared.busy
        let playing = LibraryAudioPreview.shared.playingID
        return MusicLibrary.genres.map { g in
            LibrarySection(id: "music.\(g)", title: tr("music.genre.\(g)"),
                           items: MusicLibrary.all.filter { $0.genre == g }.map { item($0, store: store, used: used, busy: busy, playing: playing) },
                           group: tr("audio.lib.music"))
        }
    }

    static func item(_ d: MusicTrackDescriptor, store: EditorStore, used: Set<URL>, busy: Set<String>, playing: String?) -> LibraryItem {
        let id = "music.\(d.id)"
        return LibraryItem(id: id, title: tr(d.nameKey),
                           subtitle: "\(MusicLibrary.artist) · \(tr("music.mood.\(d.mood)")) · \(Timecode.shortDuration(Time(d.duration)))",
                           keywords: d.tags + [d.genre, d.mood, tr("music.genre.\(d.genre)"), tr("music.mood.\(d.mood)"), "\(Int(d.bpm)) bpm"],
                           art: .cover(AudioCovers.colors(d.genre), symbol: symbol(d.genre)),
                           payload: AudioLibraryPayload.music(d.id),
                           added: used.contains(MusicLibrary.url(for: d).standardizedFileURL),
                           busy: busy.contains(id), playing: playing == id,
                           add: { [store] in AudioLibraryRendering.shared.add(id, name: tr(d.nameKey), store: store) { try MusicLibrary.file(d) } },
                           click: { LibraryAudioPreview.shared.toggle(id) { try MusicLibrary.file(d) } })
    }

    static func symbol(_ genre: String) -> String {
        switch genre {
        case "lofi": return "cloud.moon"
        case "cinematic": return "film"
        case "hiphop": return "headphones"
        case "electronic": return "waveform.path"
        case "acoustic": return "guitars"
        case "corporate": return "briefcase"
        case "ambient": return "leaf"
        case "chiptune": return "gamecontroller"
        case "jazz": return "music.quarternote.3"
        default: return "music.note"
        }
    }

    static func handleDrop(_ s: String, store: EditorStore, time: Time, target: InsertTarget) -> Bool {
        guard s.hasPrefix("montage-music:"), let d = MusicLibrary.track(id: String(s.dropFirst(14))) else { return false }
        AudioLibraryRendering.shared.add("music.\(d.id)", name: tr(d.nameKey), store: store, at: time, target: target) { try MusicLibrary.file(d) }
        return true
    }

    static func dropDuration(_ s: String) -> Time? {
        guard s.hasPrefix("montage-music:"), let d = MusicLibrary.track(id: String(s.dropFirst(14))) else { return nil }
        return Time(d.duration)
    }
}
