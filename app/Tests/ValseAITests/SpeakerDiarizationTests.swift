import Testing
import Foundation
@preconcurrency import AVFoundation
@testable import ValseAI
import ValseCore
import ValseEngine
import ValseTestSupport

/// Speaker ID (AI-005 / TX-038): a synthetic two-person conversation (two system TTS voices of different gender,
/// alternating sentences) → diarization error rate per sentence, with the statistics fallback and (when installed)
/// the WeSpeaker Core ML model; end to end through auto captions when whisper is installed.
@Suite(.serialized) struct SpeakerDiarizationTests {
    static let lines = [
        "Hello and welcome to the show, today we talk about video editing.",
        "Thanks for having me, I have been editing videos for ten years.",
        "What is the first thing you do when you open a new project?",
        "I always import everything and sort my clips into folders first.",
        "That sounds very organised. Do you use music from a library?",
        "Yes, mostly royalty free tracks that are safe for social media.",
        "Great tip. Let's talk about captions now, they matter a lot.",
        "Absolutely, most people watch videos on their phone without sound.",
    ]

    struct Conversation { let url: URL; let segments: [CaptionSegment]; let truth: [Int] }

    /// Two en voices of different gender (nil when the machine has only one).
    static func voices() -> (AVSpeechSynthesisVoice, AVSpeechSynthesisVoice)? {
        let en = SpeechSynthesis.voices(languages: ["en"]).filter { !$0.isNovelty }
            .compactMap { AVSpeechSynthesisVoice(identifier: $0.id) }
        guard let m = en.first(where: { $0.gender == .male }), let f = en.first(where: { $0.gender == .female }) else { return nil }
        return (m, f)
    }

    /// Alternating sentences written into one 16 kHz file (0.5 s gaps); segments with evenly spread words.
    static func conversation() async throws -> Conversation? {
        guard let (a, b) = voices() else { return nil }
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("valse-dialogue-\(a.identifier.hashValue)-\(b.identifier.hashValue).caf")
        try? FileManager.default.removeItem(at: out)
        let file = try AVAudioFile(forWriting: out, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var t = 0.3
        var segs: [CaptionSegment] = [], truth: [Int] = []
        func silence(_ s: Double) throws {
            let n = AVAudioFrameCount(s * 16000)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!; buf.frameLength = n
            for i in 0..<Int(n) { buf.floatChannelData![0][i] = 0 }
            try file.write(from: buf)
        }
        try silence(0.3)
        for (i, line) in lines.enumerated() {
            let voice = i % 2 == 0 ? a : b
            let url = try await SpeechSynthesis.synthesize(line, voice: voice.identifier)
            let wav = try await AudioExtractor.wav16k(url, range: nil)
            defer { try? FileManager.default.removeItem(at: wav) }
            let src = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buf = AVAudioPCMBuffer(pcmFormat: src.processingFormat, frameCapacity: AVAudioFrameCount(src.length))!
            try src.read(into: buf)
            try file.write(from: buf)
            let dur = Double(buf.frameLength) / 16000
            let tokens = line.split(separator: " ").map(String.init)
            let step = dur / Double(tokens.count)
            let words = tokens.enumerated().map { (k, w) in (text: w, start: t + Double(k) * step, end: t + Double(k + 1) * step - 0.03) }
            segs.append(CaptionSegment(text: line, start: t, end: t + dur, words: words))
            truth.append(i % 2)
            t += dur
            try silence(0.5); t += 0.5
        }
        return Conversation(url: out, segments: segs, truth: truth)
    }

    /// Fraction of sentences whose majority speaker matches the truth (best of the two label permutations).
    static func accuracy(_ turns: [SpeakerTurn], _ c: Conversation) -> Double {
        let predicted = c.segments.map { s -> Int in
            var votes: [Int: Int] = [:]
            for w in s.words { if let k = SpeakerCaptions.speaker(at: (w.start + w.end) / 2, in: turns) { votes[k, default: 0] += 1 } }
            return votes.max { $0.value < $1.value }?.key ?? -1
        }
        let same = zip(predicted, c.truth).filter { $0 == $1 }.count
        let swapped = zip(predicted, c.truth).filter { $0 == 1 - $1 }.count
        return Double(max(same, swapped)) / Double(c.truth.count)
    }

    func run(_ embedder: any SpeakerEmbedder, count: Int? = nil) async throws -> (Double, Int)? {
        guard let c = try await Self.conversation() else { print("skip: needs a male and a female English voice"); return nil }
        var p = TestProject()
        let id = try await p.addMedia(c.url, at: .zero, target: .newTrack)
        let clip = try #require(p.project.timeline.clip(id))
        let turns = try await SpeakerDiarizer.turns(segments: c.segments, clips: [clip], project: p.project, speakerCount: count, embedder: embedder)
        return (Self.accuracy(turns, c), Set(turns.map(\.speaker)).count)
    }

    @Test func statisticsFallbackSeparatesTwoVoices() async throws {
        try await HeavyWorkGate.run {
            guard let (acc, n) = try await run(StatisticsEmbedder()) else { return }
            print("metric diarization_stats_accuracy=\(acc) speakers=\(n)")
            #expect(n == 2)
            #expect(acc >= 0.85)
            // forced number of speakers
            guard let (acc2, n2) = try await run(StatisticsEmbedder(), count: 2) else { return }
            #expect(n2 == 2 && acc2 >= 0.85)
        }
    }

    @Test func weSpeakerSeparatesTwoVoices() async throws {
        guard WeSpeakerEmbedder.isAvailable else { print("skip: WeSpeaker model not installed"); return }
        try await HeavyWorkGate.run {
            guard let (acc, n) = try await run(try WeSpeakerEmbedder()) else { return }
            print("metric diarization_wespeaker_accuracy=\(acc) speakers=\(n)")
            #expect(n == 2)
            #expect(acc >= 0.95)
        }
    }

    /// Auto captions with "Identify speakers": captions tagged 1 / 2 alternately, project speakers coloured.
    @Test func autoCaptionsIdentifySpeakers() async throws {
        guard WhisperRuntime.isAvailable else { print("skip: whisper not installed"); return }
        try await HeavyWorkGate.run {
            guard let c = try await Self.conversation() else { return }
            var p = TestProject()
            _ = try await p.addMedia(c.url, at: .zero, target: .newTrack)
            var o = CaptionOptions(language: "en", engine: .whisper, source: .allTracks)
            o.identifySpeakers = true
            let r = try await CaptionGenerator.run(project: p.project, options: o)
            try r.command.apply(to: &p.project)
            #expect(TimelineOps.validate(p.project.timeline).isEmpty)
            let caps = SpeechCaptions.captions(in: p.project.timeline)
            let tags = caps.map { CaptionOps.text($0)?.caption?.speaker }
            print("speaker tags: \(tags)")
            #expect(Set(tags.compactMap { $0 }) == ["1", "2"])
            #expect(p.project.speakers?.count == 2)
            // captions starting inside sentence i belong to i's speaker (up to label permutation)
            var agree = 0, total = 0
            for cap in caps {
                let mid = (cap.start.seconds + cap.end.seconds) / 2
                guard let i = c.segments.firstIndex(where: { $0.start <= mid && mid <= $0.end }), let tag = CaptionOps.text(cap)?.caption?.speaker else { continue }
                total += 1
                if (Int(tag)! - 1) == c.truth[i] { agree += 1 }
            }
            let acc = Double(max(agree, total - agree)) / Double(max(total, 1))
            print("metric diarization_captions_accuracy=\(acc)")
            #expect(acc >= 0.85)
        }
    }
}
