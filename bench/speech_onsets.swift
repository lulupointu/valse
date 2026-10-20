// Speech fixture with KNOWN word onsets and known silences / noise (caption timing, CaptionOnsetTests).
//   swift bench/speech_onsets.swift <fr|en> <out.wav> <out.tsv>
// Each sentence is synthesised on its own (AVSpeechSynthesizer.write, `say` voices Thomas / Samantha); a word's onset is
// the sample count when the synthesizer announced it (willSpeakRange, 256-sample buffers), moved forward to the first
// 5 ms frame above −45 dBFS of the clean voice when the announcement falls in the synthesizer's own silence. The
// sentences are then laid out at fixed times over a deterministic room tone (−66 dBFS), with the owner's IMG_7251 case
// reproduced in front of sentence 1 and 4: seconds of rustle (−52 dBFS) + footsteps (40 ms clicks, −40 dBFS) before
// the first word. 16 kHz mono 16-bit WAV; TSV lines "<word>\t<onset seconds>\t<sentence index>".
import AVFoundation

let args = CommandLine.arguments
guard args.count == 4, ["fr", "en"].contains(args[1]) else {
    FileHandle.standardError.write("usage: speech_onsets <fr|en> <out.wav> <out.tsv>\n".data(using: .utf8)!); exit(2)
}
let lang = args[1]
let sentences: [String] = lang == "fr" ? [
    "Vous allez rentrer chez vous, madame Martin.",
    "Les résultats sont excellents, et vos progrès sont vraiment réels.",
    "Nous reprendrons la séance la semaine prochaine.",
    "Merci beaucoup, et à bientôt.",
] : [
    "You can go back home now, Missus Martin.",
    "Your results are excellent, and your progress is really impressive.",
    "We will continue the session next week.",
    "Thank you very much, and see you soon.",
]
/// Gap before each sentence (seconds) and whether it is noisy (rustle + footsteps) rather than room tone.
let gaps: [(seconds: Double, noisy: Bool)] = [(3.4, true), (1.6, false), (0.8, false), (2.6, true)]
let tail = 1.5
let rate = 16000.0
let voiceName = lang == "fr" ? "Thomas" : "Samantha"

final class Recorder: NSObject, AVSpeechSynthesizerDelegate {
    var events: [(frames: Int, range: NSRange)] = []
    var frames = 0
    func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString r: NSRange, utterance: AVSpeechUtterance) {
        events.append((frames, r))
    }
}

/// Synthesises one sentence → (16 kHz mono samples, [(word, onset seconds)]).
func synth(_ text: String) -> ([Float], [(String, Double)]) {
    let rec = Recorder()
    let s = AVSpeechSynthesizer()
    s.delegate = rec
    let u = AVSpeechUtterance(string: text)
    u.voice = AVSpeechSynthesisVoice.speechVoices().first { $0.name == voiceName && $0.language.hasPrefix(lang) }
        ?? AVSpeechSynthesisVoice(language: lang == "fr" ? "fr-FR" : "en-US")
    var native: [Float] = []
    var srcRate = 22050.0
    var done = false
    s.write(u) { buf in
        guard let pcm = buf as? AVAudioPCMBuffer else { return }
        if pcm.frameLength == 0 { done = true; return }
        srcRate = pcm.format.sampleRate
        let n = Int(pcm.frameLength)
        if let f = pcm.floatChannelData { native += UnsafeBufferPointer(start: f[0], count: n) }
        else if let i = pcm.int16ChannelData { native += UnsafeBufferPointer(start: i[0], count: n).map { Float($0) / 32768 } }
        rec.frames += n
    }
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    // resample to 16 kHz (AVAudioConverter, proper low-pass)
    let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: srcRate, channels: 1, interleaved: false)!
    let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(native.count))!
    inBuf.frameLength = AVAudioFrameCount(native.count)
    native.withUnsafeBufferPointer { inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: native.count) }
    let conv = AVAudioConverter(from: inFmt, to: outFmt)!
    conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
    let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: AVAudioFrameCount(Double(native.count) * rate / srcRate) + 1024)!
    var fed = false
    var err: NSError?
    conv.convert(to: outBuf, error: &err) { _, status in
        if fed { status.pointee = .endOfStream; return nil }
        fed = true; status.pointee = .haveData; return inBuf
    }
    let out = Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
    // onsets: announcement time, moved forward out of the synthesizer's silence
    let hop = 80   // 5 ms
    func loud(_ i: Int) -> Bool {
        guard i + hop <= out.count else { return false }
        var acc: Float = 0
        for k in i..<(i + hop) { acc += out[k] * out[k] }
        return 10 * log10(Double(acc) / Double(hop) + 1e-12) > -45
    }
    let ns = text as NSString
    var words: [(String, Double)] = []
    for e in rec.events {
        let w = ns.substring(with: e.range)
        var i = Int(Double(e.frames) / srcRate * rate)
        let lim = min(out.count, i + Int(0.3 * rate))
        while i < lim, !loud(i) { i += hop }
        words.append((w, Double(i) / rate))
    }
    return (out, words)
}

// deterministic noise
var seed: UInt64 = lang == "fr" ? 0x5eed_f00d : 0x5eed_beef
func rnd() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(Int64(bitPattern: seed >> 11) % 2_000_001 - 1_000_000) / 1_000_000 }
func gain(_ db: Double) -> Float { Float(pow(10, db / 20)) }

var parts: [([Float], [(String, Double)])] = sentences.map(synth)
// normalise the voice: loudest 10 ms frames ≈ −18 dBFS
var peak: Float = 0
for (s, _) in parts {
    var i = 0
    while i + 160 <= s.count { var a: Float = 0; for k in i..<(i + 160) { a += s[k] * s[k] }; peak = max(peak, (a / 160).squareRoot()); i += 160 }
}
let norm = gain(-18) / max(peak, 1e-6)
var total = tail
for (k, p) in parts.enumerated() { total += gaps[k].seconds + Double(p.0.count) / rate }
var mix = [Float](repeating: 0, count: Int(total * rate))
// room tone everywhere: one-pole low-passed white noise at ≈ −66 dBFS RMS
var lp: Float = 0
for i in mix.indices { lp = 0.92 * lp + 0.08 * rnd(); mix[i] = lp * gain(-66) * 7 }
var t = 0
var tsv = ""
for (k, p) in parts.enumerated() {
    let g = Int(gaps[k].seconds * rate)
    if gaps[k].noisy {
        // rustle (slowly modulated low-passed noise) + footsteps every ≈ 0.6 s
        var l: Float = 0
        for i in 0..<g {
            l = 0.8 * l + 0.2 * rnd()
            let mod: Float = 0.6 + 0.4 * sin(Float(i) / Float(rate) * 2 * .pi * 0.7)
            mix[t + i] += l * gain(-52) * 3 * mod
        }
        var s = Int(0.25 * rate)
        while s + Int(0.05 * rate) < g - Int(0.25 * rate) {
            for i in 0..<Int(0.04 * rate) {
                let env = Float(exp(-Double(i) / (0.012 * rate)))
                mix[t + s + i] += rnd() * gain(-40) * 1.7 * env
            }
            s += Int((0.55 + 0.1 * Double(rnd())) * rate)
        }
    }
    t += g
    for (i, x) in p.0.enumerated() where t + i < mix.count { mix[t + i] += x * norm }
    for (w, on) in p.1 { tsv += "\(w)\t\(String(format: "%.4f", Double(t) / rate + on))\t\(k)\n" }
    t += p.0.count
}
// plain 44-byte-header 16-bit WAV (AVAudioFile adds an FLLR chunk whisper.cpp's reader rejects)
var wav = Data()
func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
let dataBytes = UInt32(mix.count * 2)
wav.append(contentsOf: Array("RIFF".utf8)); put32(36 + dataBytes); wav.append(contentsOf: Array("WAVE".utf8))
wav.append(contentsOf: Array("fmt ".utf8)); put32(16); put16(1); put16(1); put32(UInt32(rate)); put32(UInt32(rate) * 2); put16(2); put16(16)
wav.append(contentsOf: Array("data".utf8)); put32(dataBytes)
for x in mix { put16(UInt16(bitPattern: Int16(max(-32767, min(32767, x * 32767))))) }
try wav.write(to: URL(fileURLWithPath: args[2]))
try tsv.write(toFile: args[3], atomically: true, encoding: .utf8)
