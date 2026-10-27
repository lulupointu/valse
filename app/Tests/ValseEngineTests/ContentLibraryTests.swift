import Testing
import Foundation
import CryptoKit
@preconcurrency import AVFoundation
import ValseCore
@testable import ValseEngine

/// Bundled CC0 music + SFX library (AU-001 / AU-002 / AU-025): manifest validation (licenses, provenance, analysis),
/// installed files (presence + checksum + decodable), similarity and analysis behaviour.
@Suite(.serialized) struct ContentLibraryTests {
    @Test func manifestHasEnoughItemsAndOnlyAllowedLicenses() {
        let m = ContentLibrary.manifest
        let music = ContentLibrary.music, sfx = ContentLibrary.sfx
        #expect(music.count >= 40 && music.count <= 80, "music count \(music.count)")
        #expect(sfx.count >= 100 && sfx.count <= 220, "sfx count \(sfx.count)")
        #expect(Set(m.items.map(\.id)).count == m.items.count, "duplicate ids")
        #expect(Set(m.items.map(\.file)).count == m.items.count, "duplicate files")
        #expect(m.featureVersion == AudioFeatures.version)
        for i in m.items {
            let p = ContentLibrary.validate(i)
            #expect(p.isEmpty, "\(i.id): \(p)")
            #expect(ContentLibrary.allowedLicenses.contains(i.license.id), "\(i.id) license \(i.license.id)")
            #expect(!i.license.name.localizedCaseInsensitiveContains("attribution"), "\(i.id) attribution license")
        }
        for c in ContentLibrary.musicCategories {
            #expect(music.filter { $0.category == c }.count >= 3, "category \(c) has < 3 tracks")
        }
        for c in ContentLibrary.sfxCategories { #expect(sfx.contains { $0.category == c }, "sfx category \(c) empty") }
        for i in music { #expect(ContentLibrary.moods.contains(i.mood ?? ""), "\(i.id) mood \(i.mood ?? "-")") }
        for k in ["music", "sfx"] {
            #expect(m.stats[k]?.mean.count == AudioFeatures.dimension, "stats \(k)")
            #expect(m.stats[k]?.std.allSatisfy { $0 > 0 } == true, "stats \(k) std")
        }
        // the owner's budget: ≤ 150 MB of audio
        #expect(ContentLibrary.totalBytes <= 150_000_000, "library \(ContentLibrary.totalBytes / 1_000_000) MB")
    }

    @Test func musicAnalysisIsSane() {
        for i in ContentLibrary.music {
            let d = i.duration ?? 0, b = i.beats ?? []
            #expect(d >= 30 && d <= 300, "\(i.id) duration \(d)")
            #expect((50...160).contains(i.bpm ?? 0), "\(i.id) bpm \(i.bpm ?? 0)")
            #expect(zip(b, b.dropFirst()).allSatisfy { $0 < $1 }, "\(i.id) beats not increasing")
            #expect((b.last ?? 0) <= d + 0.05 && (b.first ?? -1) >= 0, "\(i.id) beats outside the track")
            // beat count roughly matches the tempo (the tracker may lock to half/double time)
            let expected = d * (i.bpm ?? 0) / 60
            #expect(Double(b.count) > expected * 0.4 && Double(b.count) < expected * 1.6, "\(i.id) \(b.count) beats vs \(expected)")
            #expect(i.strongBeats.count >= b.count / 2 - 1)
            #expect(i.peaks?.count == 120 && i.peaks?.max() == 255, "\(i.id) peaks")
            if let k = i.key { #expect(AudioFeatures.parseKey(k) != nil, "\(i.id) key \(k)") }
        }
        #expect(ContentLibrary.music.filter { $0.key != nil }.count >= ContentLibrary.music.count / 2, "most tracks have a key")
    }

    /// Every manifest item exists in the installed library (app bundle / VALSE_CONTENT_DIR / developer cache)
    /// with the recorded size + SHA-256 and decodes. Skipped (with a warning) when the library was never fetched,
    /// unless VALSE_REQUIRE_CONTENT=1 (release packaging).
    @Test func installedFilesMatchTheManifest() throws {
        guard let dir = ContentLibrary.directory else {
            let required = ProcessInfo.processInfo.environment["VALSE_REQUIRE_CONTENT"] == "1"
            print("⚠️ content library not installed — run scripts/fetch_music_pack.sh (file checks skipped)")
            #expect(!required, "VALSE_REQUIRE_CONTENT=1 but the library is not installed")
            return
        }
        var bytes = 0
        for i in ContentLibrary.items {
            let u = dir.appendingPathComponent(i.file)
            guard let data = try? Data(contentsOf: u) else { Issue.record("\(i.id): missing \(u.path)"); continue }
            bytes += data.count
            #expect(data.count == i.bytes, "\(i.id) size")
            let h = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(h == i.sha256, "\(i.id) checksum")
        }
        print("metric content_library_mb \(Double(bytes) / 1e6)")
        // a sample decodes with the expected duration (AAC priming/padding is trimmed by AVFoundation)
        for i in ContentLibrary.music.prefix(3) + ContentLibrary.sfx.prefix(3) {
            let f = try AVAudioFile(forReading: dir.appendingPathComponent(i.file))
            let d = Double(f.length) / f.processingFormat.sampleRate
            #expect(abs(d - (i.duration ?? 0)) < 0.1, "\(i.id) decoded \(d) vs \(i.duration ?? 0)")
            #expect(f.processingFormat.sampleRate == 48000)
        }
        #expect(ContentLibrary.availableMusic.count == ContentLibrary.music.count)
        #expect(ContentLibrary.availableSFX.count == ContentLibrary.sfx.count)
    }

    @Test func similarityRanksAndExcludesTheSeed() throws {
        let music = ContentLibrary.music
        try #require(music.count >= 10)
        for seed in music.prefix(8) {
            let r = ContentSimilarity.similar(to: seed, limit: 10, in: music)
            #expect(r.count == 10)
            #expect(!r.contains { $0.item.id == seed.id })
            #expect(zip(r, r.dropFirst()).allSatisfy { $0.score >= $1.score })
            #expect(r.allSatisfy { $0.item.kind == .music })
        }
        // features of an item compared with itself: perfect match
        let s = music[0]
        let me = ContentSimilarity.similar(toFeatures: s.features!, kind: .music, limit: 1, in: music)
        #expect(me.first?.item.id == s.id)
        #expect(abs((me.first?.score ?? 0) - 1) < 1e-4)
        // categories cluster: on average a track's nearest neighbours share its category more often than chance
        var same = 0, total = 0
        for seed in music {
            for m in ContentSimilarity.similar(to: seed, limit: 5, in: music) { total += 1; if m.item.category == seed.category { same += 1 } }
        }
        let chance = 1.0 / Double(ContentLibrary.musicCategories.count)
        #expect(Double(same) / Double(total) > chance * 1.5, "same-category rate \(Double(same) / Double(total)) vs chance \(chance)")
        // sound effects
        let sfx = ContentLibrary.sfx
        if let first = sfx.first {
            let r = ContentSimilarity.similar(to: first, limit: 5, in: sfx)
            #expect(r.count == 5 && r.allSatisfy { $0.item.kind == .sfx })
        }
        #expect(ContentSimilarity.kind(forDuration: 30) == .music && ContentSimilarity.kind(forDuration: 1.5) == .sfx)
    }

    // MARK: analysis on synthetic audio (no library needed)

    static func tone(_ freqs: [Double], seconds: Double, sr: Double = AudioFeatures.sampleRate) -> [Float] {
        (0..<Int(seconds * sr)).map { i in
            let t = Double(i) / sr
            return Float(freqs.reduce(0) { $0 + sin(2 * .pi * $1 * t) } / Double(freqs.count) * 0.5)
        }
    }

    @Test func keyEstimateFindsTriads() {
        // C major triad C4 E4 G4 + octave
        let c = AudioFeatures.extract(Self.tone([261.63, 329.63, 392.0, 523.25], seconds: 4), bpm: 0)
        #expect(c.keyTonic == 0 && c.keyMinor == false, "got \(c.keyName ?? "nil")")
        // A minor triad A3 C4 E4
        let a = AudioFeatures.extract(Self.tone([220.0, 261.63, 329.63, 440.0], seconds: 4), bpm: 0)
        #expect(a.keyName == "A minor" || a.keyName == "C major", "got \(a.keyName ?? "nil")")  // relative keys share notes
        #expect(c.vector.count == AudioFeatures.dimension)
        #expect(AudioFeatures.parseKey("F# minor")! == (6, true))
    }

    @Test func featuresSeparateToneFromNoise() {
        var rng = SystemRandomNumberGenerator()
        let noise = (0..<Int(3 * AudioFeatures.sampleRate)).map { _ in Float.random(in: -0.4...0.4, using: &rng) }
        let t1 = AudioFeatures.extract(Self.tone([440], seconds: 3), bpm: 0).vector
        let t2 = AudioFeatures.extract(Self.tone([466.16], seconds: 3), bpm: 0).vector
        let n = AudioFeatures.extract(noise, bpm: 0).vector
        let stats = ContentFeatureStats([t1, t2, n])
        let e1 = stats.embed(t1), e2 = stats.embed(t2), en = stats.embed(n)
        func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
        #expect(dot(e1, e2) > dot(e1, en), "tone-tone \(dot(e1, e2)) vs tone-noise \(dot(e1, en))")
        #expect(abs(dot(e1, e1) - 1) < 1e-4)
    }

    @Test func analyzerFillsBeatsKeyAndPeaks() async throws {
        // 8 s of a 120 BPM click track over a C-major chord, written as WAV and analysed like a library item
        let sr = 48000.0, secs = 8.0
        let b = AudioBuffer(channels: 2, frames: Int(secs * sr), sampleRate: sr)
        for i in 0..<b.frames {
            let t = Double(i) / sr
            let beat = t.truncatingRemainder(dividingBy: 0.5)
            let click = beat < 0.03 ? Float(sin(2 * .pi * 1000 * t) * (1 - beat / 0.03)) * 0.8 : 0
            let chord = Float((sin(2 * .pi * 261.63 * t) + sin(2 * .pi * 329.63 * t) + sin(2 * .pi * 392 * t)) / 3 * 0.25)
            b[0, i] = click + chord; b[1, i] = click + chord
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("valse-content-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("music"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try AudioFileIO.write(b, to: dir.appendingPathComponent("music/test.wav"))
        let item = ContentItem(
            id: "test.click", kind: .music, title: "Click", artist: "Test", category: "electronic", mood: "energetic", tags: [],
            name: nil, n: nil, file: "music/test.wav", bytes: 0, sha256: String(repeating: "0", count: 64),
            license: .init(id: "CC0-1.0", name: "CC0", url: "https://creativecommons.org/publicdomain/zero/1.0/", evidence: "x", verified: "2026-10-18"),
            source: .init(name: "Test", page: "https://example.org", download: "https://example.org/a", author: "Test",
                          retrieved: "2026-10-18", published: nil, pack: nil, path: nil, originalSha256: String(repeating: "0", count: 64)))
        let a = try await ContentAnalyzer.analyze(item, in: dir)
        #expect(abs((a.duration ?? 0) - secs) < 0.01)
        let bpm = a.bpm ?? 0
        #expect(abs(bpm - 120) < 3 || abs(bpm - 60) < 2 || abs(bpm - 240) < 5, "bpm \(bpm)")
        #expect((a.beats?.count ?? 0) >= 6)
        #expect(a.key == "C major", "key \(a.key ?? "nil")")
        #expect(a.peaks?.count == 120)
        #expect(a.features?.count == AudioFeatures.dimension)
        // manifest encoding: one item per line, decodes back
        let m = ContentManifest(generated: "2026-10-18", stats: ["music": ContentFeatureStats([a.features!])], items: [a, a])
        let data = try m.encoded()
        let back = try JSONDecoder().decode(ContentManifest.self, from: data)
        #expect(back.items.count == 2 && back.items[0].bpm == a.bpm)
        #expect(String(decoding: data, as: UTF8.self).split(separator: "\n").count >= 3)
    }
}
