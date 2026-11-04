@preconcurrency import AVFoundation
import Testing
import Foundation
import ValseCore
import ValseEngine
@testable import ValseAI
import ValseTestSupport

/// BUG-AUDIO-RESAMPLE-ALL: the AI audio readers (speech extraction, stem separation input, voice isolation input,
/// AI-pilot activity levels) decode at the file's rate and resample with `AudioFileIO.stream`, never in the
/// AVAssetReader (which zeroed ~15 samples at random AAC packet boundaries). Per reader: repeated reads of 44.1 kHz AAC
/// footage are identical, the length is exact and a pulse lands on its frame.
@Suite(.serialized) struct AIAudioReadDeterminismTests {
    /// 2 s of stereo lossless WAV at `rate` with a raised-cosine pulse (peak 0.5) centred on 1 s.
    static func pulse(rate: Double) throws -> URL {
        let url = TestMedia.directory.appendingPathComponent("ai-resample-pulse-\(Int(rate)).wav")
        if TestMedia.isUsable(url) { return url }
        var s = [Float](repeating: 0, count: Int(rate * 2))
        let c = Int(rate), w = Int((0.00068 * rate).rounded())
        for k in -w...w { s[c + k] = Float(0.25 * (1 + cos(Double.pi * Double(k) / Double(w)))) }
        let tmp = TestMedia.directory.appendingPathComponent("ai-resample-pulse-\(UUID().uuidString).wav")
        try AudioFileIO.write(AudioBuffer([s, s], sampleRate: rate), to: tmp, format: .wav24)
        TestMedia.publishFile(tmp, as: url)
        return url
    }

    static func peak(_ x: [Float]) throws -> Double {
        let i = try #require(x.indices.max { x[$0] < x[$1] })
        guard i > 0, i < x.count - 1 else { return Double(i) }
        let a = Double(x[i - 1]), b = Double(x[i]), c = Double(x[i + 1])
        let d = a - 2 * b + c
        return d == 0 ? Double(i) : Double(i) + 0.5 * (a - c) / d
    }

    static let footage = RealLikeMedia.iPhoneHLGPortrait   // 44.1 kHz AAC stereo

    /// Speech engines' input: 16 kHz mono 16-bit PCM WAV (format tag 1, what whisper.cpp reads), range-exact.
    @Test func speechExtractionIsExactAndDeterministic() async throws {
        let u = try await ValseAI.AudioExtractor.wav16k(try Self.pulse(rate: 44100), range: TimeRange(start: Time(0.5), duration: Time(1.5)))
        defer { try? FileManager.default.removeItem(at: u) }
        let d = try Data(contentsOf: u)
        #expect(d.prefix(4) == Data("RIFF".utf8))
        let fmt = try #require(d.range(of: Data("fmt ".utf8)))
        let tag = UInt16(d[fmt.upperBound + 4]) | UInt16(d[fmt.upperBound + 5]) << 8
        #expect(tag == 1, "WAV format tag \(tag)")
        let x = try await AudioFileIO.read(u, sampleRate: 16000, channels: 1).channel(0)
        #expect(x.count == 24000)
        let at = try Self.peak(x)
        #expect(abs(at - 8000) < 0.15, "pulse at \(at)")
        var first: [Float]?
        for k in 0..<6 {
            let f = try await ValseAI.AudioExtractor.wav16k(Self.footage, range: nil)
            defer { try? FileManager.default.removeItem(at: f) }
            let y = try await AudioFileIO.read(f, sampleRate: 16000, channels: 1).channel(0)
            if let first { #expect(y == first, "speech extraction \(k) differs") } else { first = y; #expect(y.contains { abs($0) > 1e-3 }) }
        }
    }

    /// Stem separation input: 44.1 kHz stereo WAV (from a 48 kHz file: resampled), exact.
    @Test func stemInputIsExactAndDeterministic() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ai-stem-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("p.wav")
        try await StemSeparator.writeWAV(try Self.pulse(rate: 48000), to: out)
        let x = try await AudioFileIO.read(out, sampleRate: 44100, channels: 2).channel(0)
        #expect(x.count == 88200)
        let at = try Self.peak(x)
        #expect(abs(at - 44100) < 0.15, "pulse at \(at)")
        var first: [Float]?
        for k in 0..<5 {
            let f = dir.appendingPathComponent("s\(k).wav")
            try await StemSeparator.writeWAV(RealLikeMedia.speech, to: f)   // 48 kHz AAC → 44.1 kHz
            let y = try await AudioFileIO.read(f, sampleRate: 44100, channels: 2).channel(0)
            if let first { #expect(y == first, "stem input \(k) differs") } else { first = y; #expect(y.contains { abs($0) > 1e-3 }) }
        }
    }

    /// Voice isolation input: 48 kHz stereo float CAF, sample 0 = media time 0.
    @Test func isolatorInputIsExactAndDeterministic() async throws {
        let u = try await VoiceIsolator.decode(try Self.pulse(rate: 44100)) { _ in }
        defer { try? FileManager.default.removeItem(at: u) }
        let x = try await AudioFileIO.read(u, channels: 2).channel(0)
        #expect(x.count == 96000)
        let at = try Self.peak(x)
        #expect(abs(at - 48000) < 0.1, "pulse at \(at)")
        var first: [Float]?
        for k in 0..<5 {
            let f = try await VoiceIsolator.decode(Self.footage) { _ in }
            defer { try? FileManager.default.removeItem(at: f) }
            let y = try await AudioFileIO.read(f, channels: 2).channel(0)
            if let first { #expect(y == first, "isolator input \(k) differs") } else { first = y; #expect(y.contains { abs($0) > 1e-3 }) }
        }
    }

    /// AI pilot activity: one level per 50 ms window, the same on every read.
    @Test func activityLevelsAreDeterministic() async throws {
        let p = try await ActivityAnalyzer.levels(url: try Self.pulse(rate: 44100))
        #expect(p.count == 40)
        #expect(p.indices.max { p[$0] < p[$1] } == 19 || p.indices.max { p[$0] < p[$1] } == 20)   // the pulse straddles 1.0 s
        let first = try await ActivityAnalyzer.levels(url: Self.footage)
        #expect(abs(first.count - 80) <= 1)
        for k in 1..<6 {
            let again = try await ActivityAnalyzer.levels(url: Self.footage)
            #expect(again == first, "activity levels \(k) differ")
        }
    }
}
