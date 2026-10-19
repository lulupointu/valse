import Testing
import Foundation
@testable import MontageAI
import MontageCore
import MontageEngine
import MontageTestSupport

/// C4 on real speech (bench/media/speech_fr.wav, whisper.cpp): a clip that starts and ends on silence gets its leading
/// and trailing pauses cut by "Remove filler words", every word is kept and stays in order. Skipped without the
/// whisper model / runtime or the bench media.
@Suite(.serialized) struct FillerRemovalSpeechTests {
    /// 16 kHz mono PCM16 WAV with `pad` seconds of silence before and after.
    static func padded(_ wav16k: URL, pad: Double) throws -> URL {
        let d = try Data(contentsOf: wav16k)
        // find the "data" chunk
        var i = 12
        var pcm = Data()
        while i + 8 <= d.count {
            let id = String(decoding: d[i..<i + 4], as: UTF8.self)
            let n = Int(d[i + 4]) | Int(d[i + 5]) << 8 | Int(d[i + 6]) << 16 | Int(d[i + 7]) << 24
            if id == "data" { pcm = d[(i + 8)..<min(d.count, i + 8 + n)]; break }
            i += 8 + n + (n & 1)
        }
        let silence = Data(count: Int(pad * 16000) * 2)
        let body = silence + pcm + silence
        func le32(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)]) }
        func le16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)]) }
        var out = Data("RIFF".utf8) + le32(36 + body.count) + Data("WAVE".utf8)
        out += Data("fmt ".utf8) + le32(16) + le16(1) + le16(1) + le32(16000) + le32(32000) + le16(2) + le16(16)
        out += Data("data".utf8) + le32(body.count) + body
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("montage-fill-\(UUID().uuidString).wav")
        try out.write(to: u)
        return u
    }

    @Test func leadingAndTrailingSilenceOfARealClipIsCut() async throws {
        try await HeavyWorkGate.run {
            guard WhisperRuntime.isAvailable, let src = AIFixtures.speechFR else { print("skip: whisper model/runtime or bench media missing"); return }
            let wav16 = try await AudioExtractor.wav16k(src, range: nil)
            defer { try? FileManager.default.removeItem(at: wav16) }
            let wav = try Self.padded(wav16, pad: 2.5)
            defer { try? FileManager.default.removeItem(at: wav) }
            let t = try await Transcriber.transcribe(wav: wav, request: .init(language: "fr", engine: .whisper, keepFillers: true))
            let first = try #require(t.words.first), last = try #require(t.words.last)
            #expect(first.start > 2.0, "speech starts at \(first.start)")
            // a project with that media on the main track
            let seconds = 45.3 + 5
            let a = MediaAsset(name: "speech", kind: .video, url: wav, duration: Time(seconds), pixelSize: .hd1080, frameRate: .fps30,
                               hasVideo: true, hasAudio: true, contentHash: "speech-padded")
            var p = Project(name: "s")
            p.media = [a]
            var c = TimelineOps.makeClip(for: a, at: .zero)
            c.duration = Time(seconds)
            try TimelineOps.insert(c, into: &p)
            let tr = [a.id: t]
            let placed = TranscriptEditing.placedWords(transcripts: tr, timeline: p.timeline)
            let found = FillerCleanup.candidates(words: placed, transcripts: tr, timeline: p.timeline, options: .init(kinds: [], minPause: 1.0))
            let lead = try #require(found.first { $0.edge == .leading })
            let trail = try #require(found.first { $0.edge == .trailing })
            #expect(abs(lead.seconds - first.start) < 0.01 && lead.seconds > 2)
            #expect(trail.seconds > 2, "trailing silence \(trail.seconds) (last word ends \(last.end))")
            try FillerCleanup.apply(found, in: &p)
            #expect(TimelineOps.validate(p.timeline).isEmpty)
            let after = TranscriptEditing.placedWords(transcripts: tr, timeline: p.timeline)
            #expect(after.filter { !$0.isDeleted }.count == placed.count)            // no word lost
            let s0 = try #require(FillerCleanup.span(after.first!, in: p.timeline)), s1 = try #require(FillerCleanup.span(after.last!, in: p.timeline))
            #expect(s0.start.seconds < 0.2, "speech now starts at \(s0.start.seconds)")
            #expect(p.timeline.duration.seconds - s1.end.seconds < 0.2)
            print("metric fillers_real_speech_removed_s=\(seconds - p.timeline.duration.seconds) candidates=\(found.count)")
        }
    }
}
