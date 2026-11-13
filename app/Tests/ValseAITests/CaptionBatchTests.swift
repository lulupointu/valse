@preconcurrency import AVFoundation
import Testing
import Foundation
@testable import ValseAI
import ValseCore
import ValseEngine
import ValseTestSupport

/// PERF-CAPTIONS-1: the ranges of one caption request are recognised in one engine run over a joined WAV, words mapped
/// back to their range.
@Suite struct CaptionBatchTests {
    static func w(_ text: String, _ s: Double, _ e: Double) -> TranscriptWord { TranscriptWord(text: text, start: s, end: e) }

    @Test func groupsAndOffsets() {
        #expect(CaptionBatch.offsets([2, 3, 1.5], gap: 1) == [0, 3, 7])
        #expect(CaptionBatch.groups([2, 3, 1.5], gap: 1, maxSeconds: 600) == [[0, 1, 2]])
        // 2 + 1 + 3 = 6 fits, + 1 + 1.5 doesn't; a piece longer than the cap is alone
        #expect(CaptionBatch.groups([2, 3, 1.5, 9, 1], gap: 1, maxSeconds: 6) == [[0, 1], [2], [3], [4]])
        #expect(CaptionBatch.groups([], gap: 1, maxSeconds: 6).isEmpty)
    }

    /// Pieces of 2 s and 3 s at 0 and 3 (gap 2…3), then 1.5 s at 7.
    @Test func wordsMapBackToTheirPiece() {
        let offs = [0.0, 3, 7], durs = [2.0, 3, 1.5]
        let words = [
            Self.w("a", 0.1, 0.5),
            Self.w("straddle", 1.8, 2.6),     // starts in piece 0, ends in the gap: clamped to piece 0's end
            Self.w("early", 2.9, 3.3),        // starts in the gap, reaches into piece 1: piece 1, from its start
            Self.w("b", 3.5, 3.9),
            Self.w("lonely", 2.05, 2.2),      // wholly in the gap, nearer piece 0
            Self.w("c", 7.2, 7.6),
            Self.w("late", 8.4, 9.2),         // ends after the last piece: clamped
        ]
        let parts = CaptionBatch.split(words, offsets: offs, durations: durs)
        #expect(parts.map { $0.map(\.text) } == [["a", "straddle", "lonely"], ["early", "b"], ["c", "late"]])
        #expect(parts.flatMap { $0 }.count == words.count)   // nothing dropped
        let s = parts[0][1]
        #expect(abs(s.start - 1.8) < 1e-9 && abs(s.end - 2.0) < 1e-9)
        let e = parts[1][0]
        #expect(e.start == 0 && abs(e.end - 0.3) < 1e-9)
        let lonely = parts[0][2]
        #expect(abs(lonely.start - 1.98) < 1e-9 && abs(lonely.end - 2.0) < 1e-9)
        #expect(abs(parts[1][1].start - 0.5) < 1e-9 && abs(parts[2][0].start - 0.2) < 1e-9)
        #expect(abs(parts[2][1].start - 1.4) < 1e-9 && abs(parts[2][1].end - 1.5) < 1e-9)
        // a word nearer the next piece (in the gap, not reaching it) goes there
        let near = CaptionBatch.split([Self.w("x", 2.8, 2.95)], offsets: offs, durations: durs)
        #expect(near[1].map(\.text) == ["x"] && near[1][0].start == 0)
    }

    static func writeWav(_ samples: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("valse-batch-\(UUID().uuidString).wav")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        for i in samples.indices { buf.floatChannelData![0][i] = samples[i] }
        try f.write(from: buf)
        return url
    }

    static func samples(_ url: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: url)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    }

    @Test func joinWritesPiecesWithSilenceBetween() throws {
        let a = try Self.writeWav([Float](repeating: 0.5, count: 16000 * 2 + 37))
        let b = try Self.writeWav([Float](repeating: -0.25, count: 8000))
        defer { for u in [a, b] { try? FileManager.default.removeItem(at: u) } }
        let (joined, offs) = try CaptionBatch.join([a, b], gap: 1)
        defer { try? FileManager.default.removeItem(at: joined) }
        let n = 16000 * 2 + 37
        #expect(offs == [0, Double(n + 16000) / 16000])
        let s = try Self.samples(joined)
        #expect(s.count == n + 16000 + 8000)
        #expect(abs(s[0] - 0.5) < 1e-3 && abs(s[n - 1] - 0.5) < 1e-3)
        #expect(s[n..<(n + 16000)].allSatisfy { $0 == 0 })
        #expect(abs(s[n + 16000] + 0.25) < 1e-3 && abs(s.last! + 0.25) < 1e-3)
        #expect(abs(CaptionBatch.duration(joined) - Double(s.count) / 16000) < 1e-9)
    }

    /// Fake engine: one word per run of sound (digital silence = the gaps), 0.1…0.4 s into it; records its inputs.
    final class FakeEngine: @unchecked Sendable {
        private let lock = NSLock()
        private var _inputs: [Double] = []
        var inputs: [Double] { lock.withLock { _inputs } }
        var recognizer: CaptionBatch.Recognizer {
            { [self] wav, request, progress in
                let s = try CaptionBatchTests.samples(wav)
                lock.withLock { _inputs.append(Double(s.count) / 16000) }
                var words: [TranscriptWord] = []
                var i = 0
                while i < s.count {
                    guard abs(s[i]) > 1e-3 else { i += 1; continue }
                    var j = i
                    while j < s.count, s[j..<min(s.count, j + 1600)].contains(where: { abs($0) > 1e-3 }) { j += 1600 }
                    let t = Double(i) / 16000
                    words.append(TranscriptWord(text: "w\(words.count)", start: t + 0.1, end: t + 0.4))
                    i = j
                }
                progress?(1)
                return Transcript(engine: "fake", language: request.language ?? "fr", words: words)
            }
        }
    }

    /// Three media with sound + one silent: one engine run over the three sound pieces; each range gets its own word at
    /// its media time; a cached run skips the engine; a new range alone is sent next time.
    @Test func runBatchesUncachedRangesOnly() async throws {
        let store = TranscriptStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("valse-ts-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var p = TestProject()
        _ = try await p.addVideo(.solid(.black), seconds: 12)
        _ = try await p.addMedia(try await TestMedia.audio(seconds: 2, hz: 440), at: .zero, target: .newTrack)
        _ = try await p.addMedia(try await TestMedia.audio(seconds: 2.5, hz: 660), at: Time(3), target: .newTrack)
        _ = try await p.addMedia(try await TestMedia.audio(seconds: 1.5, hz: 0), at: Time(6), target: .newTrack)
        let fake = FakeEngine()
        let o = CaptionOptions(language: "fr", engine: .automatic, source: .allTracks)
        let r = try await CaptionGenerator.run(project: p.project, options: o, store: store, recognizer: fake.recognizer)
        #expect(fake.inputs.count == 1)
        #expect(r.timings.ranges == 3 && r.timings.silent == 1 && r.timings.transcribed == 2 && r.timings.engineRuns == 1)
        // joined = 2 + 1 + 2.5 s (± AAC padding)
        #expect(abs((fake.inputs.first ?? 0) - 5.5) < 0.2)
        var q = p.project
        try r.command.apply(to: &q)
        let starts = SpeechCaptions.captions(in: q.timeline).map(\.start.seconds)
        #expect(starts.count == 2)
        #expect(abs((starts.first ?? -1) - 0.1) < 0.08)
        #expect(abs((starts.last ?? -1) - 3.1) < 0.08)

        // all cached: no engine run
        _ = try await CaptionGenerator.run(project: p.project, options: o, store: store, recognizer: fake.recognizer)
        #expect(fake.inputs.count == 1)
        // one more range: only it goes to the engine
        _ = try await p.addMedia(try await TestMedia.audio(seconds: 1.8, hz: 550), at: Time(8), target: .newTrack)
        let r3 = try await CaptionGenerator.run(project: p.project, options: o, store: store, recognizer: fake.recognizer)
        #expect(fake.inputs.count == 2)
        #expect(abs(fake.inputs[1] - 1.8) < 0.2)
        #expect(r3.timings.cached == 3 && r3.timings.transcribed == 1)
        #expect(r3.count == 3)
    }
}
