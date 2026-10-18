import SwiftUI
import MontageCore
import MontageEngine

/// Audio ▸ Music ▾ / Sound effects ▾ (AU-001 / AU-002): the bundled CC0 library (`ContentLibrary`: real tracks from
/// FreePD / Free Music Archive, sound effects from Kenney / OpenGameArt / Wikimedia Commons), one rail entry per
/// category, plus a "Generated" entry with the procedurally synthesized tracks / effects (`MusicLibrary`,
/// `SoundEffects`). Rows: title + "safe for social media" badge, "artist · 02:09 · 120 BPM", ☆, Similar, ⊕.
@MainActor
enum AudioLibrarySections {
    static var defaultNav: String { "group:" + tr("audio.lib.music") }

    static func music(_ store: EditorStore, _ used: Set<URL>) -> [LibrarySection] {
        let busy = AudioLibraryRendering.shared.busy
        let playing = LibraryAudioPreview.shared.playingID
        let lib = ContentLibrary.availableMusic
        var out: [LibrarySection] = ContentLibrary.musicCategories.compactMap { c in
            let items = lib.filter { $0.category == c }
            guard !items.isEmpty else { return nil }
            return LibrarySection(id: "music.cat.\(c)", title: tr("music.cat.\(c)"),
                                  items: items.map { libraryItem($0, store: store, used: used, busy: busy, playing: playing) },
                                  group: tr("audio.lib.music"))
        }
        out.append(LibrarySection(id: "music.generated", title: tr("music.cat.generated"),
                                  items: MusicLibrary.all.map { item($0, store: store, used: used, busy: busy, playing: playing) },
                                  group: tr("audio.lib.music")))
        return out
    }

    static func sfx(_ store: EditorStore, _ used: Set<URL>, generated: [LibraryItem]) -> [LibrarySection] {
        let busy = AudioLibraryRendering.shared.busy
        let playing = LibraryAudioPreview.shared.playingID
        let lib = ContentLibrary.availableSFX
        var out: [LibrarySection] = ContentLibrary.sfxCategories.compactMap { c in
            let items = lib.filter { $0.category == c }
            guard !items.isEmpty else { return nil }
            return LibrarySection(id: "sfx.cat.\(c)", title: tr("sfx.category.\(c)"),
                                  items: items.map { libraryItem($0, store: store, used: used, busy: busy, playing: playing) },
                                  group: tr("audio.lib.sfx"))
        }
        out.append(LibrarySection(id: "sfx.generated", title: tr("music.cat.generated"), items: generated, group: tr("audio.lib.sfx")))
        return out
    }

    // MARK: Bundled library items

    static func title(_ c: ContentItem) -> String {
        guard c.kind == .sfx, let n = c.name else { return c.title }
        return tr("sfx.n.\(n)") + (c.n.map { " \($0)" } ?? "")
    }

    static func rowID(_ c: ContentItem) -> String { "lib.\(c.id)" }

    static func libraryItem(_ c: ContentItem, store: EditorStore, used: Set<URL>, busy: Set<String>, playing: String?) -> LibraryItem {
        let id = rowID(c)
        let name = title(c)
        let dur = Timecode.shortDuration(Time(c.duration ?? 0))
        let subtitle: String
        if c.kind == .music {
            subtitle = [c.artist, dur, c.bpm.map { tr("audio.lib.bpm", Int($0.rounded())) }].compactMap { $0 }.joined(separator: " · ")
        } else {
            subtitle = "\(tr("sfx.category.\(c.category)")) · \(dur)"
        }
        var keywords = c.tags + [c.category, c.artist, c.source.name, c.title, tr(c.kind == .music ? "music.cat.\(c.category)" : "sfx.category.\(c.category)")]
        if let m = c.mood { keywords += [m, tr("music.mood.\(m)")] }
        if let b = c.bpm { keywords.append("\(Int(b.rounded())) bpm") }
        let url = ContentLibrary.url(for: c)
        return LibraryItem(id: id, title: name, subtitle: subtitle, keywords: keywords,
                           art: .cover(c.kind == .music ? AudioCovers.colors(c.category) : AudioCovers.sfx(c.category),
                                       symbol: c.kind == .music ? categorySymbol(c.category) : sfxSymbol(c.category)),
                           payload: AudioLibraryPayload.library(c.id),
                           added: url.map { used.contains($0.standardizedFileURL) } ?? false,
                           busy: busy.contains(id), playing: playing == id,
                           add: { [store] in addLibrary(c, store: store) },
                           click: {
                               guard let url else { return }
                               LibraryAudioPreview.shared.seed(id, peaks: c.peaks, beats: c.kind == .music ? c.beats : nil, duration: c.duration)
                               LibraryAudioPreview.shared.toggle(id) { url }
                           },
                           license: license(c),
                           similar: { AudioSimilarState.shared.show(item: c) })
    }

    static func addLibrary(_ c: ContentItem, store: EditorStore, at time: Time? = nil, target: InsertTarget = .automatic) {
        guard let url = ContentLibrary.url(for: c) else { store.showToast(tr("audio.lib.notInstalled"), error: true); return }
        AudioLibraryRendering.shared.add(rowID(c), name: title(c), store: store, at: time, target: target,
                                         beats: c.kind == .music ? c.strongBeats : nil) { url }
    }

    static func license(_ c: ContentItem) -> LibraryLicense {
        var details: [(String, String)] = [(tr("audio.license.duration"), Timecode.shortDuration(Time(c.duration ?? 0)))]
        if let b = c.bpm { details.append((tr("audio.license.bpm"), "\(Int(b.rounded()))")) }
        if let k = c.key, let p = AudioFeatures.parseKey(k) { details.append((tr("audio.license.key"), keyName(p.tonic, minor: p.minor))) }
        if let p = c.source.pack, c.kind == .sfx { details.append((tr("audio.license.pack"), p)) }
        return LibraryLicense(licenseName: c.license.name, licenseURL: c.license.url, author: c.source.author,
                              sourceName: c.source.name, sourcePage: c.source.page, retrieved: c.source.retrieved, details: details)
    }

    /// "La mineur" / "A minor" (solfège names in French).
    static func keyName(_ tonic: Int, minor: Bool) -> String {
        let en = AudioFeatures.pitchNames
        let fr = ["Do", "Do♯", "Ré", "Mi♭", "Mi", "Fa", "Fa♯", "Sol", "La♭", "La", "Si♭", "Si"]
        let names = L10n.shared.language == "fr" ? fr : en.map { $0.replacingOccurrences(of: "#", with: "♯").replacingOccurrences(of: "b", with: "♭") }
        return tr(minor ? "audio.key.minor" : "audio.key.major", names[tonic % 12])
    }

    static func categorySymbol(_ c: String) -> String {
        switch c {
        case "vlog": return "camera"
        case "upbeat": return "sun.max"
        case "chill": return "leaf"
        case "lofi": return "cloud.moon"
        case "cinematic": return "film"
        case "corporate": return "briefcase"
        case "emotional": return "heart"
        case "hiphop": return "headphones"
        case "acoustic": return "guitars"
        case "electronic": return "waveform.path"
        case "funny": return "face.smiling"
        case "jazz": return "music.quarternote.3"
        default: return "music.note"
        }
    }

    static func sfxSymbol(_ c: String) -> String {
        switch c {
        case "transition": return "wind"
        case "ui": return "cursorarrow.click"
        case "notification": return "bell"
        case "impact": return "burst"
        case "cartoon": return "theatermasks"
        case "crowd": return "hands.clap"
        case "tech": return "camera"
        case "money": return "dollarsign.circle"
        case "stings": return "music.note"
        case "foley": return "shoeprints.fill"
        case "nature": return "cloud.rain"
        case "scifi": return "sparkles"
        default: return "waveform"
        }
    }

    // MARK: Generated (procedural) tracks

    static func item(_ d: MusicTrackDescriptor, store: EditorStore, used: Set<URL>, busy: Set<String>, playing: String?) -> LibraryItem {
        let id = "music.\(d.id)"
        return LibraryItem(id: id, title: tr(d.nameKey),
                           subtitle: "\(MusicLibrary.artist) · \(tr("music.genre.\(d.genre)")) · \(Timecode.shortDuration(Time(d.duration)))",
                           keywords: d.tags + [d.genre, d.mood, tr("music.genre.\(d.genre)"), tr("music.mood.\(d.mood)"), "\(Int(d.bpm)) bpm",
                                               tr("music.cat.generated")],
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

    // MARK: Drag & drop

    static func handleDrop(_ s: String, store: EditorStore, time: Time, target: InsertTarget) -> Bool {
        if s.hasPrefix("montage-lib:"), let c = ContentLibrary.item(id: String(s.dropFirst(12))) {
            addLibrary(c, store: store, at: time, target: target)
            return true
        }
        guard s.hasPrefix("montage-music:"), let d = MusicLibrary.track(id: String(s.dropFirst(14))) else { return false }
        AudioLibraryRendering.shared.add("music.\(d.id)", name: tr(d.nameKey), store: store, at: time, target: target) { try MusicLibrary.file(d) }
        return true
    }

    static func dropDuration(_ s: String) -> Time? {
        if s.hasPrefix("montage-lib:"), let c = ContentLibrary.item(id: String(s.dropFirst(12))) { return Time(c.duration ?? 1) }
        guard s.hasPrefix("montage-music:"), let d = MusicLibrary.track(id: String(s.dropFirst(14))) else { return nil }
        return Time(d.duration)
    }
}
