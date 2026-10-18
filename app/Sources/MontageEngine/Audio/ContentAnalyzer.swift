@preconcurrency import AVFoundation
import Foundation
import MontageCore

/// Offline analysis of the content library (run by scripts/fetch_music_pack.sh through
/// `Montage --analyze-content <staging-manifest.json> <content-dir> <out.json>`): duration, loudness, beats + BPM
/// (W8's `AudioAnalysis` beat tracker), key, waveform peaks and similarity features, plus per-kind feature stats.
public enum ContentAnalyzer {
    public static func analyze(_ item: ContentItem, in dir: URL) async throws -> ContentItem {
        var i = item
        let url = dir.appendingPathComponent(item.file)
        let f = try AVAudioFile(forReading: url)
        i.duration = round3(Double(f.length) / f.processingFormat.sampleRate)
        let (res, beats, mono) = try await AudioFeatures.analyze(url: url)
        i.features = res.vector.map { Float(round4(Double($0))) }
        if item.kind == .music {
            // The tracker often locks to double time on busy tracks (170–200 BPM): fold to the felt tempo (≤ 160) by
            // keeping the stronger half of the beats, like a musician would count it.
            var bpm = beats.bpm, all = beats.beats, strongList = beats.strongBeats
            if bpm > 160 {
                bpm /= 2; all = strongList
                strongList = stride(from: 0, to: all.count, by: 2).map { all[$0] }
            }
            i.bpm = (bpm * 10).rounded() / 10
            i.beats = all.map(round3)
            let strong = Set(strongList.map(round3))
            i.strongPhase = i.beats?.first.map { strong.contains($0) ? 0 : 1 } ?? 0
            i.key = res.keyName
        }
        i.peaks = peaks(mono, bars: item.kind == .music ? 120 : 48)
        let l = try await AudioAnalysis.loudness(url: url)
        i.loudness = l.isFinite ? (l * 10).rounded() / 10 : nil
        return i
    }

    /// Peak bars 0…255 (max of |x| per bar, normalised to the loudest bar).
    public static func peaks(_ x: [Float], bars: Int) -> [Int] {
        guard !x.isEmpty else { return [] }
        var out = [Float](repeating: 0, count: bars)
        for (k, s) in x.enumerated() {
            let b = min(bars - 1, k * bars / x.count)
            out[b] = max(out[b], abs(s))
        }
        let m = max(out.max() ?? 1, 1e-4)
        return out.map { Int(($0 / m * 255).rounded()) }
    }

    /// Analyses every item of `manifest` (files under `dir`), fills the stats and writes `out`. Returns a summary.
    public static func run(manifest: URL, dir: URL, out: URL, log: @Sendable (String) -> Void = { print($0) }) async throws -> ContentManifest {
        var m = try JSONDecoder().decode(ContentManifest.self, from: Data(contentsOf: manifest))
        var done: [ContentItem] = []
        let t0 = Date()
        for (k, item) in m.items.enumerated() {
            let a = try await analyze(item, in: dir)
            done.append(a)
            if item.kind == .music || k % 25 == 0 {
                log(String(format: "[%3d/%d] %@ %.1fs %@ %@", k + 1, m.items.count, item.id, a.duration ?? 0,
                           a.bpm.map { String(format: "%.0f BPM", $0) } ?? "", a.key ?? ""))
            }
        }
        m.items = done
        m.featureVersion = AudioFeatures.version
        m.stats = [:]
        for kind in [ContentItem.Kind.music, .sfx] {
            let vs = done.filter { $0.kind == kind }.compactMap(\.features)
            if !vs.isEmpty {
                var s = ContentFeatureStats(vs)
                s.mean = s.mean.map { Float(round4(Double($0))) }
                s.std = s.std.map { Float(round4(Double($0))) }
                m.stats[kind.rawValue] = s
            }
        }
        try m.encoded().write(to: out)
        log(String(format: "analysed %d items in %.1f s → %@", done.count, Date().timeIntervalSince(t0), out.path))
        return m
    }

    /// CLI entry (`Montage --analyze-content <manifest> <dir> <out>`); returns the process exit code.
    public static func runCLI(_ args: [String]) -> Int32 {
        guard args.count >= 3 else {
            FileHandle.standardError.write(Data("usage: Montage --analyze-content <manifest.json> <content-dir> <out.json>\n".utf8))
            return 2
        }
        let box = ExitBox()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                _ = try await run(manifest: URL(fileURLWithPath: args[0]), dir: URL(fileURLWithPath: args[1], isDirectory: true),
                                  out: URL(fileURLWithPath: args[2]))
            } catch {
                FileHandle.standardError.write(Data("analyze-content failed: \(error)\n".utf8))
                box.code = 1
            }
            sem.signal()
        }
        sem.wait()
        return box.code
    }

    private final class ExitBox: @unchecked Sendable { var code: Int32 = 0 }

    static func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
    static func round4(_ x: Double) -> Double {
        guard x != 0, x.isFinite else { return 0 }
        let mag = pow(10, 3 - floor(log10(abs(x))))     // 4 significant digits
        return (x * mag).rounded() / mag
    }
}
