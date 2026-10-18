// Word-onset ground truth for bench/media/speech_fr.wav (caption timing tests, CaptionTimingTests).
// Synthesizes bench/speech_fr.txt with the same voice as `say -v Thomas` through AVSpeechSynthesizer.write and records,
// for every word, how many samples had been produced when the synthesizer announced it (willSpeakRange: 256-sample
// buffers → ±12 ms). The audio is byte-identical to `say -v Thomas -o x.aiff` resampled to 16 kHz, so the onsets
// apply to speech_fr.wav. Output: "<word>\t<onset seconds>" lines.
//   swiftc -O bench/speech_words.swift -o /tmp/speech_words && /tmp/speech_words bench/speech_fr.txt > bench/speech_fr_words.tsv
import AVFoundation

let args = CommandLine.arguments
guard args.count >= 2, let text = try? String(contentsOfFile: args[1], encoding: .utf8) else {
    FileHandle.standardError.write("usage: speech_words <text file> [voice name] [out.caf]\n".data(using: .utf8)!); exit(2)
}
let string = text.trimmingCharacters(in: .whitespacesAndNewlines)
let voiceName = args.count > 2 ? args[2] : "Thomas"

final class Recorder: NSObject, AVSpeechSynthesizerDelegate {
    var events: [(frames: Int, range: NSRange)] = []
    var frames = 0
    func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString r: NSRange, utterance: AVSpeechUtterance) {
        events.append((frames, r))
    }
}
let rec = Recorder()
let synth = AVSpeechSynthesizer()
synth.delegate = rec
let u = AVSpeechUtterance(string: string)
u.voice = AVSpeechSynthesisVoice.speechVoices().first { $0.name == voiceName && $0.language.hasPrefix("fr") }
    ?? AVSpeechSynthesisVoice(language: "fr-FR")
var rate = 22050.0
var file: AVAudioFile?
var finished = false
synth.write(u) { buf in
    guard let pcm = buf as? AVAudioPCMBuffer else { return }
    if pcm.frameLength == 0 { finished = true; return }
    rate = pcm.format.sampleRate
    if args.count > 3, file == nil {
        file = try? AVAudioFile(forWriting: URL(fileURLWithPath: args[3]), settings: pcm.format.settings,
                                commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
    }
    try? file?.write(from: pcm)
    rec.frames += Int(pcm.frameLength)
}
while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
let ns = string as NSString
for e in rec.events { print("\(ns.substring(with: e.range))\t\(String(format: "%.4f", Double(e.frames) / rate))") }
