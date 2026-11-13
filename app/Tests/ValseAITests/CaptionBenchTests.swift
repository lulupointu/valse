import Testing
import Foundation
@testable import ValseAI
import ValseCore
import ValseEngine
import ValseTestSupport

/// PERF-CAPTIONS-1, opt-in: the full caption pipeline on a real project, timed per phase.
/// `VALSE_CAPTION_PROJECT=/path/to/a/COPY.valse VALSE_CAPTION_OUT=/empty/dir scripts/test.sh --filter CaptionBenchTests`
/// Media are taken from the copy's `media/` folder when present (never the original's). The per-range transcripts
/// land in `VALSE_CAPTION_OUT` (a fresh `TranscriptStore`: nothing comes from the app's cache), with `captions.txt`
/// (one caption per line) and `timings.txt`. `VALSE_CAPTION_LANG` forces the language (default: auto detect).
@Suite(.serialized) struct CaptionBenchTests {
    @Test func realProjectPipeline() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["VALSE_CAPTION_PROJECT"], let outPath = env["VALSE_CAPTION_OUT"] else { return }
        try await HeavyWorkGate.run {
            let pkg = URL(fileURLWithPath: path)
            var p = try ProjectPackage.load(from: pkg)
            let own = pkg.appendingPathComponent("media")
            for i in p.media.indices {
                let copy = own.appendingPathComponent(p.media[i].url.lastPathComponent)
                if FileManager.default.fileExists(atPath: copy.path) { p.media[i].url = copy }
            }
            let out = URL(fileURLWithPath: outPath)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let store = TranscriptStore(directory: out)
            let options = CaptionOptions(language: env["VALSE_CAPTION_LANG"], engine: .automatic, source: .allTracks)
            let t0 = CaptionTimings.now()
            let r = try await CaptionGenerator.run(project: p, options: options, store: store)
            let t1 = CaptionTimings.now()
            try r.command.apply(to: &p)
            let t2 = CaptionTimings.now()
            let caps = SpeechCaptions.captions(in: p.timeline)
            let lines = caps.map { String(format: "%.2f\t", $0.start.seconds) + (CaptionOps.text($0)?.string ?? "") }
            try lines.joined(separator: "\n").write(to: out.appendingPathComponent("captions.txt"), atomically: true, encoding: .utf8)
            let summary = r.timings.logLine + String(format: " | run %.2fs, insert %.2fs, language %@, %d captions",
                                                     t1 - t0, t2 - t1, r.language, r.count)
            try summary.write(to: out.appendingPathComponent("timings.txt"), atomically: true, encoding: .utf8)
            print("metric caption_bench " + summary)
            #expect(r.count > 0)
        }
    }
}
