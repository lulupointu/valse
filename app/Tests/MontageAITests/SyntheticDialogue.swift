import Foundation
@preconcurrency import AVFoundation
@testable import MontageAI
import MontageCore
import MontageEngine

/// A synthetic two-person conversation (two system TTS voices of different gender, alternating sentences) used by
/// the long-video-to-shorts tests (kept from the removed speaker-ID tests, CAP-NOSPEAKER).
enum SyntheticDialogue {
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

    struct Conversation { let url: URL; let segments: [CaptionSegment] }

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
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("montage-dialogue-\(a.identifier.hashValue)-\(b.identifier.hashValue).caf")
        try? FileManager.default.removeItem(at: out)
        let file = try AVAudioFile(forWriting: out, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var t = 0.3
        var segs: [CaptionSegment] = []
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
            t += dur
            try silence(0.5); t += 0.5
        }
        return Conversation(url: out, segments: segs)
    }
}
