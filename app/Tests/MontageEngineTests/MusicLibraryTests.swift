import Testing
import Foundation
import MontageCore
@testable import MontageEngine

/// Built-in procedural music library (AU-001 substitute): catalogue invariants, determinism, levels, files.
@Suite(.serialized) struct MusicLibraryTests {
    @Test func catalogueInvariants() {
        let all = MusicLibrary.all
        #expect(all.count >= 30)
        #expect(Set(all.map(\.id)).count == all.count, "duplicate ids")
        for g in MusicLibrary.genres { #expect(all.filter { $0.genre == g }.count >= 3, "genre \(g)") }
        for t in all {
            #expect(MusicLibrary.genres.contains(t.genre), "\(t.id) genre")
            #expect(MusicLibrary.moods.contains(t.mood), "\(t.id) mood")
            #expect(t.duration >= 30 && t.duration <= 60, "\(t.id) duration \(t.duration)")
            let bars = t.duration * t.bpm / 240
            #expect(abs(bars - bars.rounded()) < 1e-9, "\(t.id) not whole bars")
            #expect(t.nameKey == "music.track.\(t.id)")
            #expect(!t.tags.isEmpty)
            #expect(MusicLibrary.track(id: t.id)?.id == t.id)
        }
        for m in MusicLibrary.moods { #expect(all.contains { $0.mood == m }, "mood \(m) unused") }
    }

    @Test func renderIsDeterministic() {
        let d = MusicLibrary.track(id: "lofi.rainy")!
        let a = MusicLibrary.render(d, seconds: 3), b = MusicLibrary.render(d, seconds: 3)
        #expect(a.frames == b.frames)
        #expect(a.channel(0) == b.channel(0) && a.channel(1) == b.channel(1))
    }

    @Test func shortRenderHasRequestedLengthAndSaneLevels() {
        // One track per genre, first 6 s (intro: pads/chords; faster genres already reach bass and drums).
        for g in MusicLibrary.genres {
            let d = MusicLibrary.all.first { $0.genre == g }!
            let b = MusicLibrary.render(d, seconds: 6)
            #expect(b.frames == 6 * 48000, "\(d.id) frames")
            #expect(b.channels == 2)
            #expect(b.peak <= 1.0 && b.peak > 0.5, "\(d.id) peak \(b.peak)")
            let rms = b.rms(seconds: 1.5, 6)
            #expect(rms > 0.03 && rms < 0.6, "\(d.id) rms \(rms)")
            #expect(b.rms(seconds: 1.5, 6, channel: 1) > 0.03, "\(d.id) right channel")
            #expect(!b.channel(0).contains { $0.isNaN || $0.isInfinite }, "\(d.id) NaN")
        }
    }

    @Test func tracksDifferWithinAGenre() {
        let ds = MusicLibrary.all.filter { $0.genre == "pop" }.prefix(2)
        let a = MusicLibrary.render(ds.first!, seconds: 2), b = MusicLibrary.render(ds.last!, seconds: 2)
        #expect(a.channel(0) != b.channel(0))
    }

    @Test func fileWritesReadableWav() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("montage-music-\(UUID().uuidString)")
        MusicLibrary.directoryOverride = dir
        defer { MusicLibrary.directoryOverride = nil; try? FileManager.default.removeItem(at: dir) }
        let d = MusicLibrary.track(id: "chiptune.quest")!
        #expect(!MusicLibrary.isRendered(d))
        let u = try MusicLibrary.file(d, seconds: 4)
        #expect(u == MusicLibrary.url(for: d))
        #expect(u.lastPathComponent == "chiptune.quest-v\(MusicLibrary.version).wav")
        #expect(MusicLibrary.isRendered(d))
        let back = try await AudioFileIO.read(u)
        #expect(abs(Double(back.frames) / 48000 - 4) < 0.01)
        #expect(back.rms(seconds: 1, 4) > 0.03)
        #expect(try MusicLibrary.file(d) == u)   // cached: no re-render
    }

    @Test func renderSpeedGuard() {
        let d = MusicLibrary.track(id: "electronic.neon")!
        let t0 = Date()
        _ = MusicLibrary.render(d, seconds: 10)
        let dt = Date().timeIntervalSince(t0)
        print("metric music_render_10s_debug_s \(dt)")
        #expect(dt < 30, "10 s render took \(dt) s")
    }

    /// `MONTAGE_MUSIC_DUMP=<dir>` renders every full track there and prints timings (manual listening / release timing).
    @Test func dumpAllTracks() throws {
        guard let path = ProcessInfo.processInfo.environment["MONTAGE_MUSIC_DUMP"] else { return }
        let dir = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var total = 0.0
        for d in MusicLibrary.all {
            let t0 = Date()
            let b = MusicLibrary.render(d)
            let dt = Date().timeIntervalSince(t0)
            total += dt
            try AudioFileIO.write(b, to: dir.appendingPathComponent("\(d.id).wav"))
            print(String(format: "metric music_render %@ %.1f s audio in %.2f s, rms %.3f", d.id, d.duration, dt, b.rms()))
        }
        print(String(format: "metric music_render_total %.2f s", total))
    }
}
