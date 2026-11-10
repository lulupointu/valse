// BUG-CUT-AUDIO-HOLE part 5 (docs/investigations/BUG-METALLIC-AUDIO.md): standalone audio timing probe.
//
// No Valse module, no test framework: one Swift file built on the host for macOS 13 (scripts/audio_probe.sh), so the
// SAME binary runs on this Mac and in the macOS 13 VM (which has no Swift 6 toolchain nor Testing.framework). It
// rebuilds the shape of Valse's preview audio (an AVMutableComposition audio track, an audio mix input with a
// time-pitch algorithm and a POST-EFFECTS MTAudioProcessingTap, an AVPlayer) and measures, ON THE CONTENT, how the tap's
// stamps relate to the samples they carry. Same signal and method as TapProbeTests.previewLead (irregular 30 ms noise
// bursts at 120-320 ms intervals; lead = content time - stamp, positive = stamps EARLY).
//
// Commands (all print `PROBE ...` lines; nothing is asserted):
//   player   AVPlayer + post-effects tap (Valse preview shape)      --algo spectral|timeDomain|varispeed --rate R --speed S
//   export   AVAssetReaderAudioMixOutput + the same tap (Valse export shape)
//   aq       a bare AudioQueue + post-effects AudioQueueProcessingTap with the AQ time-pitch (below AVFoundation)
//   renderer replacement prototype: reader (with the tap) -> AVSampleBufferAudioRenderer + AVSampleBufferRenderSynchronizer
//            (`--notap`: no tap in the reader, samples labelled by the sample buffer PTS at enqueue time, where the
//            lane processing would run; `--ahead 0.15` paces the feeder to 150 ms past the clock)
//   clocks   AVPlayer slaved to the output's audio device clock + the synchronizer, started at one host time: drift
//   storm    AVPlayer seek storm (12 seeks 80 ms apart while playing), for comparison with the renderer's
//   au       kAudioUnitProperty_Latency of the system time-pitch units
//   devices  output devices (UID, nominal rate, IO buffer)
//   matrix   player / export / aq / renderer over the standard cases (what scripts/audio_probe.sh runs)
// Options: --seek 1.3  --seconds 2.5  --src 48000|44100  --device <UID>  --out-rate 44100 (sets the default output's
//   nominal rate for the run, restored after)  --pre (pre-effects tap)  --capture (macOS 14.2+: muted process tap of
//   this process's output, burst lead of what is actually played vs the player / synchronizer clock)  --ahead <s>
//   (renderer: keep at most that much audio enqueued ahead of the clock)  --bypass 0|1 (aq: kAudioQueueProperty_TimePitchBypass)
//   --dir <path> (generated media; default $TMPDIR)  --audible (volume 1: never in tests; the default is muted).
import AVFoundation
import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation
import MediaToolbox
import QuartzCore

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Arguments

var opts: [String: String] = [:]
let argv = CommandLine.arguments
let command = argv.count > 1 ? argv[1] : "help"
do {
    var i = 2
    while i < argv.count {
        let k = argv[i]
        guard k.hasPrefix("--") else { i += 1; continue }
        if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") { opts[String(k.dropFirst(2))] = argv[i + 1]; i += 2 }
        else { opts[String(k.dropFirst(2))] = "1"; i += 1 }
    }
}
func opt(_ k: String, _ d: Double) -> Double { opts[k].flatMap(Double.init) ?? d }
let workDir = URL(fileURLWithPath: opts["dir"] ?? NSTemporaryDirectory())
let muted = opts["audible"] == nil
let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
#if arch(arm64)
let arch = "arm64"
#else
let arch = "x86_64"
#endif

func spin(_ seconds: Double) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
@discardableResult func spin(until cond: () -> Bool, timeout: Double) -> Bool {
    let t0 = CACurrentMediaTime()
    while !cond() { if CACurrentMediaTime() - t0 > timeout { return false }; spin(0.002) }
    return true
}
func cm(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 48000 * 100) }
func f(_ x: Double, _ d: Int = 2) -> String { x.isFinite ? String(format: "%.\(d)f", x) : "nan" }
func median(_ a: [Double]) -> Double { let s = a.sorted(); return s.isEmpty ? .nan : s[s.count / 2] }

// MARK: - Signal (same as TapProbeTests.burstTimes / burstFile)

let burstTimes: [Double] = {
    var t = 0.05, seed: UInt64 = 12345, out: [Double] = []
    while t < 7.9 {
        out.append(t)
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        t += 0.12 + Double((seed >> 33) % 1000) / 1000 * 0.2
    }
    return out
}()

func burstSamples(rate: Double) -> [Float] {
    var s = [Float](repeating: 0, count: Int(8 * rate))
    var seed: UInt64 = 0x9E3779B97F4A7C15
    for b in burstTimes {
        let i0 = Int((b * rate).rounded())
        for i in i0..<(i0 + Int(0.03 * rate)) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            s[i] = i == i0 ? 0.8 : Float(Int64(bitPattern: seed >> 11) % 1000) / 1000 * 0.5
        }
    }
    return s
}

func burstFile(rate: Double) throws -> URL {
    let url = workDir.appendingPathComponent("probe-bursts-\(Int(rate)).wav")
    if FileManager.default.fileExists(atPath: url.path) { return url }
    let s = burstSamples(rate: rate)
    let tmp = workDir.appendingPathComponent("probe-bursts-\(UUID().uuidString).wav")
    do {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: tmp, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                                               AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 24,
                                                               AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false],
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(s.count))!
        b.frameLength = AVAudioFrameCount(s.count)
        s.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: s.count) }
        try file.write(from: b)
    }
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.moveItem(at: tmp, to: url)
    return url
}

// MARK: - Capture

/// One buffer: label = time of its first sample on the axis being measured (stamp, or clock time for output captures),
/// `step` = that axis' time per sample.
struct Buf {
    var label: Double
    var step: Double
    var frames: Int
    var sampleRate: Double
    var samples: [Float]
    var host: Double
    var flagsIn: UInt32 = 0
    var flagsOut: UInt32 = 0
    var duration: Double = .nan
    var firstSound: Int { samples.firstIndex { $0 != 0 } ?? -1 }
}

final class Capture {
    private let lock = NSLock()
    private var bufs: [Buf] = []
    private var events: [String] = []
    var enabled = true
    func add(_ b: Buf) { lock.lock(); if enabled { bufs.append(b) }; lock.unlock() }
    func event(_ e: String) { lock.lock(); events.append(String(format: "%.4f ", CACurrentMediaTime()) + e); lock.unlock() }
    func clear() { lock.lock(); bufs = []; events = []; lock.unlock() }
    var snapshot: [Buf] { lock.lock(); defer { lock.unlock() }; return bufs }
    var eventLog: [String] { lock.lock(); defer { lock.unlock() }; return events }
}

// MARK: - Analysis (ports of TapProbeTests.envelopeLead / leads)

/// What the composition plays: a clip at `start` (item s), constant `speed`, source seconds from 0.
struct ClipMap {
    let start: Double, speed: Double, sourceSeconds: Double
    var end: Double { start + sourceSeconds / speed }
    func source(_ t: Double) -> Double { (t - start) * speed }
    var burstItemTimes: [Double] { burstTimes.filter { $0 < sourceSeconds }.map { start + $0 / speed } }
}

/// Lead (s) from 1 ms energy envelopes: captured output placed at its labels vs the source placed at its item time.
func envelopeLead(_ caps: [Buf], clip: ClipMap, source: [Float], sourceRate: Double, from: Double, to: Double) -> (lead: Double, corr: Double) {
    let t0 = max(clip.start, from), t1 = min(clip.end, to)
    guard t1 > t0 + 0.3 else { return (.nan, 0) }
    let bins = Int((t1 - t0) * 1000) + 1
    var got = [Double](repeating: 0, count: bins), want = [Double](repeating: 0, count: bins)
    var covered = [Bool](repeating: false, count: bins)
    for c in caps where c.label.isFinite {
        for (i, v) in c.samples.enumerated() {
            let b = Int(((c.label + Double(i) * c.step) - t0) * 1000)
            if b >= 0, b < bins { got[b] += Double(v * v); covered[b] = true }
        }
    }
    for b in 0..<bins {
        let s0 = Int(clip.source(t0 + Double(b) / 1000) * sourceRate), s1 = Int(clip.source(t0 + Double(b + 1) / 1000) * sourceRate)
        if s0 >= 0, s1 <= source.count, s1 > s0 { for j in s0..<s1 { want[b] += Double(source[j] * source[j]) } }
    }
    let valid = (0..<bins).filter { covered[$0] && $0 > 150 && $0 < bins - 150 }
    var best = (lead: Double.nan, corr: -1.0)
    for lag in -400...400 {
        var xy = 0.0, xx = 0.0, yy = 0.0
        for b in valid where b + lag >= 0 && b + lag < bins { xy += got[b] * want[b + lag]; xx += got[b] * got[b]; yy += want[b + lag] * want[b + lag] }
        let c = xx > 0 && yy > 0 ? xy / (xx * yy).squareRoot() : 0
        if c > best.corr { best = (Double(lag) / 1000, c) }
    }
    return best
}

/// Burst onsets: (stamp of the buffer, lead) per onset found, matched to the burst nearest to measured + coarse.
func burstLeads(_ caps: [Buf], clip: ClipMap, coarse: Double) -> [(stamp: Double, frames: Int, lead: Double)] {
    var out: [(Double, Int, Double)] = []
    var calm = 0
    var prevEnd = Double.nan
    let expected = clip.burstItemTimes
    for c in caps where c.label.isFinite {
        if !(abs(c.label - prevEnd) < 0.001) { calm = 0 }
        prevEnd = c.label + Double(c.samples.count) * c.step
        let quiet = Int(c.sampleRate * 0.005)
        for (i, v) in c.samples.enumerated() {
            if abs(v) > 0.1 {
                if calm >= quiet {
                    let measured = c.label + Double(i) * c.step
                    let m = measured + coarse
                    if let e = expected.min(by: { abs($0 - m) < abs($1 - m) }), abs(e - m) < 0.05 / clip.speed,
                       e > clip.start + 0.15, e < clip.end - 0.15 {
                        out.append((c.label, c.samples.count, e - measured))
                    }
                }
                calm = 0
            } else if abs(v) < 0.03 { calm += 1 } else { calm = 0 }
        }
    }
    return out
}

func leadSummary(_ name: String, _ caps: [Buf], clip: ClipMap, sourceRate: Double, from: Double, to: Double) -> (lead: Double, n: Int) {
    let source = burstSamples(rate: sourceRate)
    let env = envelopeLead(caps, clip: clip, source: source, sourceRate: sourceRate, from: from, to: to)
    let l = burstLeads(caps, clip: clip, coarse: env.lead.isFinite ? env.lead : 0).map { $0.lead * 1000 }.sorted()
    let frames = Set(caps.map(\.frames)).sorted()
    let rates = Set(caps.map(\.sampleRate)).sorted()
    print("PROBE \(name): ENVELOPE lead \(f(env.lead * 1000, 1)) ms (corr \(f(env.corr, 3))); BURSTS lead median \(l.isEmpty ? "nan" : f(median(l))) ms"
          + " (min \(f(l.first ?? .nan)), max \(f(l.last ?? .nan)), \(l.count) bursts); \(caps.count) buffers, frames \(frames.prefix(6)), tap rates \(rates)")
    return (l.isEmpty ? env.lead * 1000 : median(l), l.count)
}

/// First buffers after a seek / start: stamp - target, frames, Δstamp in frames of the previous buffer, flags, first
/// sounding sample, onset lead of the first burst found in it.
func structure(_ name: String, _ caps: [Buf], target: Double, clip: ClipMap, coarse: Double, count: Int = 8) {
    var line = "PROBE \(name) first buffers (target \(f(target, 4))):"
    var prev: Buf?
    for (i, c) in caps.prefix(count).enumerated() {
        line += " | #\(i) "
        line += c.label.isFinite ? "\(f((c.label - target) * 1000, 2))ms" : "nostamp"
        line += " \(c.frames)f"
        if let p = prev, p.label.isFinite, c.label.isFinite { line += " Δ\(f((c.label - p.label) / p.step, 0))f" }
        if c.duration.isFinite { line += " d\(f(c.duration * 1000, 2))" }
        line += String(format: " fl%x/%x", c.flagsIn, c.flagsOut)
        let s = c.firstSound
        line += s < 0 ? " silent" : " snd@\(s)"
        if let b = burstLeads([c], clip: clip, coarse: coarse).first { line += " burst lead \(f(b.lead * 1000, 2))ms" }
        prev = c
    }
    print(line)
}

// MARK: - Taps

final class TapCtx {
    let cap: Capture
    var sampleRate = 48000.0
    var playerRate: () -> Double
    init(_ cap: Capture, playerRate: @escaping () -> Double) { self.cap = cap; self.playerRate = playerRate }
}

func makeTap(_ ctx: TapCtx, pre: Bool) -> MTAudioProcessingTap? {
    var cb = MTAudioProcessingTapCallbacks(
        version: kMTAudioProcessingTapCallbacksVersion_0,
        clientInfo: Unmanaged.passRetained(ctx).toOpaque(),
        init: { _, ci, so in so.pointee = ci },
        finalize: { tap in Unmanaged<TapCtx>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
        prepare: { tap, maxFrames, fmt in
            let c = Unmanaged<TapCtx>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
            c.sampleRate = fmt.pointee.mSampleRate
            c.cap.event("tap prepare maxFrames \(maxFrames) sr \(fmt.pointee.mSampleRate) ch \(fmt.pointee.mChannelsPerFrame)")
        },
        unprepare: { tap in Unmanaged<TapCtx>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().cap.event("tap unprepare") },
        process: { tap, n, flags, bl, nOut, flagsOut in
            var range = CMTimeRange()
            let st = MTAudioProcessingTapGetSourceAudio(tap, n, bl, flagsOut, &range, nOut)
            guard st == noErr else { return }
            let c = Unmanaged<TapCtx>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
            let abl = UnsafeMutableAudioBufferListPointer(bl)
            let frames = Int(nOut.pointee)
            guard frames > 0, let d = abl[0].mData else { return }
            let p = d.assumingMemoryBound(to: Float.self)
            c.cap.add(Buf(label: range.start.isNumeric ? range.start.seconds : .nan, step: c.playerRate() / c.sampleRate,
                          frames: frames, sampleRate: c.sampleRate, samples: Array(UnsafeBufferPointer(start: p, count: frames)),
                          host: CACurrentMediaTime(), flagsIn: UInt32(flags), flagsOut: UInt32(flagsOut.pointee),
                          duration: range.duration.isNumeric ? range.duration.seconds : .nan))
        })
    var tap: MTAudioProcessingTap?
    let err = MTAudioProcessingTapCreate(kCFAllocatorDefault, &cb, pre ? kMTAudioProcessingTapCreationFlag_PreEffects : kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
    return err == noErr ? tap : nil
}

func algorithm(_ s: String) -> AVAudioTimePitchAlgorithm {
    switch s { case "timeDomain": return .timeDomain; case "varispeed": return .varispeed; default: return .spectral }
}

// MARK: - Composition (the Valse preview shape: clip at 1 s, 6 s of source, optionally speed-scaled)

func composition(sourceRate: Double, speed: Double, clipStart: Double = 1.0, sourceSeconds: Double = 6.0) throws -> (AVMutableComposition, ClipMap) {
    let asset = AVURLAsset(url: try burstFile(rate: sourceRate))
    let comp = AVMutableComposition()
    let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
    let src = asset.tracks(withMediaType: .audio)[0]
    try track.insertTimeRange(CMTimeRange(start: .zero, duration: cm(sourceSeconds)), of: src, at: cm(clipStart))
    if speed != 1 { track.scaleTimeRange(CMTimeRange(start: cm(clipStart), duration: cm(sourceSeconds)), toDuration: cm(sourceSeconds / speed)) }
    return (comp, ClipMap(start: clipStart, speed: speed, sourceSeconds: sourceSeconds))
}

func audioMix(_ comp: AVComposition, algo: AVAudioTimePitchAlgorithm, tap: MTAudioProcessingTap?) -> AVMutableAudioMix {
    let mix = AVMutableAudioMix()
    mix.inputParameters = comp.tracks(withMediaType: .audio).map { t in
        let p = AVMutableAudioMixInputParameters(track: t)
        p.trackID = t.trackID
        p.audioTimePitchAlgorithm = algo
        p.audioTapProcessor = tap
        p.setVolumeRamp(fromStartVolume: 1, toEndVolume: 1, timeRange: CMTimeRange(start: .zero, duration: comp.duration))
        return p
    }
    return mix
}

// MARK: - Devices

func defaultOutputDevice() -> AudioObjectID {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var id = AudioObjectID(0), sz = UInt32(4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &id)
    return id
}
func deviceUID(_ id: AudioObjectID) -> String {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var uid: Unmanaged<CFString>?
    var sz = UInt32(MemoryLayout<CFString?>.size)
    AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &uid)
    return uid?.takeRetainedValue() as String? ?? "?"
}
func deviceRate(_ id: AudioObjectID) -> Double {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var r = 0.0, sz = UInt32(8)
    AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &r)
    return r
}
func deviceBuffer(_ id: AudioObjectID) -> UInt32 {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var n = UInt32(0), sz = UInt32(4)
    AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &n)
    return n
}
func deviceLatency(_ id: AudioObjectID) -> (latency: UInt32, safety: UInt32) {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyLatency, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var l = UInt32(0), s = UInt32(0), sz = UInt32(4)
    AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &l)
    a.mSelector = kAudioDevicePropertySafetyOffset
    AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &s)
    return (l, s)
}
@discardableResult func setDeviceRate(_ id: AudioObjectID, _ rate: Double) -> OSStatus {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var r = rate
    let st = AudioObjectSetPropertyData(id, &a, 0, nil, 8, &r)
    spin(until: { deviceRate(id) == rate }, timeout: 2)
    return st
}
func describeOutput() -> String {
    let id = defaultOutputDevice()
    let l = deviceLatency(id)
    return "default out \(deviceUID(id)) \(Int(deviceRate(id))) Hz / \(deviceBuffer(id)) f (latency \(l.latency) + safety \(l.safety) f)"
}

func listDevices() {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(0)
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    for id in ids {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var ss = UInt32(0)
        AudioObjectGetPropertyDataSize(id, &a, 0, nil, &ss)
        a.mSelector = kAudioDevicePropertyAvailableNominalSampleRates; a.mScope = kAudioObjectPropertyScopeGlobal
        var rs = UInt32(0)
        AudioObjectGetPropertyDataSize(id, &a, 0, nil, &rs)
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(rs) / MemoryLayout<AudioValueRange>.size)
        AudioObjectGetPropertyData(id, &a, 0, nil, &rs, &ranges)
        print("PROBE device \(deviceUID(id)) rate \(deviceRate(id)) buffer \(deviceBuffer(id)) outputStreams \(ss / 4) rates \(ranges.map { Int($0.mMinimum) })")
    }
    print("PROBE \(describeOutput())")
}

// MARK: - Output capture (macOS 14.2+: what this process actually sends to its output)

/// Muted Core Audio process tap of this process (nothing reaches the device), read through a private aggregate device.
/// Each IO cycle's first sample is placed on the player / synchronizer clock with `CMSyncConvertTime(hostTime → clock)`.
final class OutCapture {
    let cap = Capture()
    var clock: () -> CMTimebase?
    var rate: Double = 48000
    var playerRate: () -> Double
    private var tapID = AudioObjectID(0), aggID = AudioObjectID(0)
    private var proc: AudioDeviceIOProcID?
    init?(clock: @escaping () -> CMTimebase?, playerRate: @escaping () -> Double) {
        self.clock = clock; self.playerRate = playerRate
        guard #available(macOS 14.2, *) else { return nil }
        var pid = getpid()
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var process = AudioObjectID(0), size = UInt32(4)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process) == noErr, process != 0 else { return nil }
        let desc = CATapDescription(stereoMixdownOfProcesses: [process])
        desc.muteBehavior = .muted
        desc.isPrivate = true
        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else { print("PROBE capture: process tap failed"); return nil }
        let out = defaultOutputDevice()
        let uid = deviceUID(out)
        rate = deviceRate(out)
        let agg: [String: Any] = [kAudioAggregateDeviceNameKey: "ProbeCapture", kAudioAggregateDeviceUIDKey: UUID().uuidString,
                                  kAudioAggregateDeviceMainSubDeviceKey: uid, kAudioAggregateDeviceIsPrivateKey: true,
                                  kAudioAggregateDeviceIsStackedKey: false, kAudioAggregateDeviceTapAutoStartKey: true,
                                  kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
                                  kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]]]
        guard AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID) == noErr else { print("PROBE capture: aggregate failed"); return nil }
        let st = AudioDeviceCreateIOProcIDWithBlock(&proc, aggID, nil) { [unowned self] _, input, inputTime, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let b = abl.first, let d = b.mData, let tb = self.clock() else { return }
            let ch = Int(max(1, b.mNumberChannels))
            let n = Int(b.mDataByteSize) / 4 / ch
            let p = d.assumingMemoryBound(to: Float.self)
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n { s[i] = p[i * ch] }
            let host = CMClockMakeHostTimeFromSystemUnits(inputTime.pointee.mHostTime)
            let t = CMSyncConvertTime(host, from: CMClockGetHostTimeClock(), to: tb)
            self.cap.add(Buf(label: t.seconds, step: self.playerRate() / self.rate, frames: n, sampleRate: self.rate, samples: s,
                             host: AudioConvertHostTimeToNanos(inputTime.pointee.mHostTime) > 0 ? CMTimeGetSeconds(host) : 0))
        }
        guard st == noErr, AudioDeviceStart(aggID, proc) == noErr else { print("PROBE capture: start failed"); stop(); return nil }
    }
    func stop() {
        if let proc { AudioDeviceStop(aggID, proc); AudioDeviceDestroyIOProcID(aggID, proc) }
        proc = nil
        if aggID != 0 { AudioHardwareDestroyAggregateDevice(aggID); aggID = 0 }
        if #available(macOS 14.2, *), tapID != 0 { AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
    }
}

// MARK: - CPU

func cpuSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
}

// MARK: - player (Valse preview shape)

struct Case { var algo: String; var rate: Double; var speed: Double; var sourceRate: Double }
func caseName(_ c: Case) -> String { "algo \(c.algo) rate \(c.rate) speed \(c.speed) src \(Int(c.sourceRate))" }

func runPlayer(_ c: Case) throws {
    let seek = opt("seek", 1.3), seconds = opt("seconds", 2.5)
    let (comp, clip) = try composition(sourceRate: c.sourceRate, speed: c.speed)
    let cap = Capture()
    var rateNow = c.rate
    let ctx = TapCtx(cap, playerRate: { rateNow })
    let mix = audioMix(comp, algo: algorithm(c.algo), tap: makeTap(ctx, pre: opts["pre"] != nil))
    let item = AVPlayerItem(asset: comp)
    item.audioMix = mix
    item.audioTimePitchAlgorithm = .spectral
    let player = AVPlayer(playerItem: item)
    player.automaticallyWaitsToMinimizeStalling = false
    player.volume = muted && opts["capture"] == nil ? 0 : 1
    if let d = opts["device"] { player.audioOutputDeviceUniqueID = d }
    guard spin(until: { item.status == .readyToPlay }, timeout: 15) else { print("PROBE player: item not ready \(item.error.map { "\($0)" } ?? "")"); return }
    var out: OutCapture?
    if opts["capture"] != nil {
        out = OutCapture(clock: { item.timebase }, playerRate: { rateNow })
        if out == nil { print("PROBE capture unavailable: player muted"); player.volume = 0 }
    }
    // seek, then play (Valse: performSeek, then playImmediately once it lands)
    let tSeek = CACurrentMediaTime()
    var done = false
    player.seek(to: cm(seek), toleranceBefore: .zero, toleranceAfter: .zero) { _ in done = true }
    spin(until: { done }, timeout: 10)
    let tLanded = CACurrentMediaTime()
    cap.clear(); out?.cap.clear()
    let cpu0 = cpuSeconds()
    let tPlay = CACurrentMediaTime()
    player.playImmediately(atRate: Float(c.rate))
    var tClock = Double.nan
    var marks: [(host: Double, item: Double)] = []
    while CACurrentMediaTime() - tPlay < seconds / c.rate + 0.4, player.currentTime().seconds < clip.end - 0.3 {
        let it = player.currentTime().seconds
        if tClock.isNaN, it > seek + 0.0005 { tClock = CACurrentMediaTime() - (it - seek) / c.rate }
        if player.rate != 0 { marks.append((CACurrentMediaTime(), it)) }
        spin(0.004)
    }
    let cpu = cpuSeconds() - cpu0, wall = CACurrentMediaTime() - tPlay
    player.pause()
    rateNow = c.rate
    out?.stop()
    let caps = cap.snapshot
    let name = "player \(opts["pre"] != nil ? "pre" : "post") \(caseName(c))"
    let r = leadSummary(name, caps, clip: clip, sourceRate: c.sourceRate, from: seek, to: clip.end)
    structure(name, caps, target: seek, clip: clip, coarse: r.lead / 1000)
    // how far ahead of the playhead the tap processes (live-effect edit latency)
    var ahead: [Double] = []
    for b in caps where b.label.isFinite {
        guard let m = marks.min(by: { abs($0.host - b.host) < abs($1.host - b.host) }), abs(m.host - b.host) < 0.05 else { continue }
        ahead.append((b.label - (m.item + (b.host - m.host) * c.rate)) / c.rate * 1000)
    }
    print("PROBE \(name) timing: seek→landed \(f((tLanded - tSeek) * 1000, 1)) ms, play→clock start \(f((tClock - tPlay) * 1000, 1)) ms,"
          + " first tap buffer \(f(((caps.first?.host ?? .nan) - tPlay) * 1000, 1)) ms after play, tap ahead of playhead median \(f(median(ahead), 0)) ms (max \(f(ahead.max() ?? .nan, 0))),"
          + " CPU \(f(cpu / wall * 100, 1)) % of a core over \(f(wall, 2)) s; \(describeOutput())")
    if let out {
        let oc = out.cap.snapshot.filter { $0.label >= seek }
        _ = leadSummary(name + " OUTPUT vs clock", oc, clip: clip, sourceRate: c.sourceRate, from: seek, to: clip.end)
    }
    if opts["events"] != nil { for e in cap.eventLog { print("PROBE event \(e)") } }
}

// MARK: - export (Valse export shape)

func runExport(_ c: Case) throws {
    let (comp, clip) = try composition(sourceRate: c.sourceRate, speed: c.speed)
    let cap = Capture()
    let ctx = TapCtx(cap, playerRate: { 1 })
    let mix = audioMix(comp, algo: algorithm(c.algo), tap: makeTap(ctx, pre: opts["pre"] != nil))
    let reader = try AVAssetReader(asset: comp)
    reader.timeRange = CMTimeRange(start: .zero, duration: cm(clip.end))
    let o = AVAssetReaderAudioMixOutput(audioTracks: comp.tracks(withMediaType: .audio), audioSettings: pcmSettings)
    o.audioMix = mix
    o.audioTimePitchAlgorithm = algorithm(c.algo)
    reader.add(o)
    reader.startReading()
    var pts: [Double] = []
    while let sb = o.copyNextSampleBuffer() { pts.append(CMSampleBufferGetPresentationTimeStamp(sb).seconds) }
    let name = "export \(opts["pre"] != nil ? "pre" : "post") \(caseName(c))"
    let r = leadSummary(name, cap.snapshot, clip: clip, sourceRate: c.sourceRate, from: 0, to: clip.end)
    structure(name, cap.snapshot.filter { $0.label >= clip.start - 0.2 }, target: clip.start, clip: clip, coarse: r.lead / 1000, count: 4)
}

let pcmSettings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                                  AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
                                  AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2]

// MARK: - aq (bare AudioQueue, below AVFoundation)

final class AQCtx {
    let src: [Float]
    var pos = 0
    let cap = Capture()
    var sampleRate: Double
    var rate: Double
    let frames = 4096
    init(src: [Float], sampleRate: Double, rate: Double) { self.src = src; self.sampleRate = sampleRate; self.rate = rate }
    func fill(_ q: AudioQueueRef, _ buf: AudioQueueBufferRef) {
        let p = buf.pointee.mAudioData.assumingMemoryBound(to: Float.self)
        let n = min(frames, max(0, src.count - pos))
        for i in 0..<n { p[i] = src[pos + i] }
        for i in n..<frames { p[i] = 0 }
        pos += frames
        buf.pointee.mAudioDataByteSize = UInt32(frames * 4)
        // explicit start time on the queue's timeline = source frame index (the tap's stamps are on that timeline)
        var ts = AudioTimeStamp()
        ts.mSampleTime = Double(pos - frames)
        ts.mFlags = .sampleTimeValid
        if timestamped {
            AudioQueueEnqueueBufferWithParameters(q, buf, 0, nil, 0, 0, 0, nil, &ts, nil)
        } else {
            AudioQueueEnqueueBuffer(q, buf, 0, nil)
        }
    }
    var timestamped = true
}

func runAQ(algo: String, rate: Double, bypass: UInt32, sourceRate: Double) {
    let src = burstSamples(rate: sourceRate)
    let ctx = AQCtx(src: src, sampleRate: sourceRate, rate: rate)
    let ud = Unmanaged.passRetained(ctx).toOpaque()
    var fmt = AudioStreamBasicDescription(mSampleRate: sourceRate, mFormatID: kAudioFormatLinearPCM,
                                          mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
                                          mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    var q: AudioQueueRef?
    var st = AudioQueueNewOutput(&fmt, { ud, q, buf in Unmanaged<AQCtx>.fromOpaque(ud!).takeUnretainedValue().fill(q, buf) }, ud, nil, nil, 0, &q)
    guard st == noErr, let q else { print("PROBE aq: new output \(st)"); return }
    var one: UInt32 = 1
    st = AudioQueueSetProperty(q, kAudioQueueProperty_EnableTimePitch, &one, 4)
    var a: UInt32 = algo == "timeDomain" ? kAudioQueueTimePitchAlgorithm_TimeDomain : algo == "varispeed" ? kAudioQueueTimePitchAlgorithm_Varispeed : kAudioQueueTimePitchAlgorithm_Spectral
    AudioQueueSetProperty(q, kAudioQueueProperty_TimePitchAlgorithm, &a, 4)
    var bp = bypass
    AudioQueueSetProperty(q, kAudioQueueProperty_TimePitchBypass, &bp, 4)
    AudioQueueSetParameter(q, kAudioQueueParam_PlayRate, AudioQueueParameterValue(rate))
    AudioQueueSetParameter(q, kAudioQueueParam_Volume, muted ? 0 : 1)
    var maxFrames: UInt32 = 0
    var pfmt = AudioStreamBasicDescription()
    var tap: AudioQueueProcessingTapRef?
    st = AudioQueueProcessingTapNew(q, { ud, tap, n, ts, flags, nOut, data in
        let c = Unmanaged<AQCtx>.fromOpaque(ud).takeUnretainedValue()
        let fin = flags.pointee.rawValue
        let st = AudioQueueProcessingTapGetSourceAudio(tap, n, ts, flags, nOut, data)
        guard st == noErr else { return }
        let abl = UnsafeMutableAudioBufferListPointer(data)
        let frames = Int(nOut.pointee)
        guard frames > 0, let d = abl[0].mData else { return }
        let p = d.assumingMemoryBound(to: Float.self)
        let valid = ts.pointee.mFlags.contains(.sampleTimeValid)
        // label in SOURCE seconds: the queue's sample time counts source frames from the start (frame 0 = source 0)
        c.cap.add(Buf(label: valid ? ts.pointee.mSampleTime / c.sampleRate : .nan, step: c.rate / c.sampleRate, frames: frames,
                      sampleRate: c.sampleRate, samples: Array(UnsafeBufferPointer(start: p, count: frames)), host: CACurrentMediaTime(),
                      flagsIn: fin, flagsOut: flags.pointee.rawValue))
    }, ud, [.postEffects], &maxFrames, &pfmt, &tap)
    guard st == noErr else { print("PROBE aq: tap \(st)"); return }
    var bufs: [AudioQueueBufferRef] = []
    for _ in 0..<3 {
        var b: AudioQueueBufferRef?
        AudioQueueAllocateBuffer(q, UInt32(ctx.frames * 4), &b)
        if let b { bufs.append(b); ctx.fill(q, b) }
    }
    var prepared: UInt32 = 0
    AudioQueuePrime(q, 0, &prepared)
    AudioQueueStart(q, nil)
    spin(2.2 / rate + 0.3)
    AudioQueueStop(q, true)
    AudioQueueDispose(q, true)
    // the queue's timeline does not start at source frame 0 (device-based): stamps relative to the first tap buffer,
    // so the lead below = −(output frames the tap delivered before source frame 0)
    var caps = ctx.cap.snapshot
    if let s0 = caps.first(where: { $0.label.isFinite })?.label {
        print("PROBE aq raw first stamp \(f(s0, 4)) s; StartOfStream (0x100) on buffers \(caps.indices.filter { caps[$0].flagsOut & 0x100 != 0 })")
        for i in caps.indices { caps[i].label -= s0 }
    }
    let clip = ClipMap(start: 0, speed: 1, sourceSeconds: 7.9)
    let name = "aq post algo \(algo) rate \(rate) bypass \(bypass) src \(Int(sourceRate)) (tap fmt \(Int(pfmt.mSampleRate)) Hz, max \(maxFrames) f)"
    let r = leadSummary(name, caps, clip: clip, sourceRate: sourceRate, from: 0, to: 2.0)
    structure(name, caps, target: 0, clip: clip, coarse: r.lead / 1000, count: 6)
}

// MARK: - renderer (replacement prototype: the export pipeline feeding AVSampleBufferAudioRenderer)

/// One "preview session": a reader from `target` (fresh tap, exact stamps like export), the renderer fed on a serial
/// queue (optionally paced to `ahead` seconds before the clock), the synchronizer started once `startAfter` seconds of
/// audio are enqueued.
final class RendererSession {
    let sync = AVSampleBufferRenderSynchronizer()
    let renderer = AVSampleBufferAudioRenderer()
    let queue = DispatchQueue(label: "probe.renderer")
    let cap = Capture()
    var rate: Double
    var reader: AVAssetReader?
    var output: AVAssetReaderAudioMixOutput?
    var enqueuedEnd = -Double.infinity
    var firstEnqueued = Double.nan
    var generation = 0
    var feeder: DispatchSourceTimer?
    let processesAtEnqueue = opts["notap"] != nil
    let ahead: Double
    init(rate: Double, ahead: Double) {
        self.rate = rate; self.ahead = ahead
        renderer.audioTimePitchAlgorithm = .spectral
        renderer.volume = muted && opts["capture"] == nil ? 0 : 1
        if let d = opts["device"] { renderer.audioOutputDeviceUniqueID = d }
        sync.addRenderer(renderer)
    }

    /// Seek (or start) at `target`: returns once the clock runs. Times: reader ready, first buffer enqueued, clock started.
    func start(_ comp: AVComposition, algo: AVAudioTimePitchAlgorithm, at target: Double, end: Double, startAfter: Double = 0.1) throws -> (firstPCM: Double, clock: Double) {
        let t0 = CACurrentMediaTime()
        generation += 1
        let gen = generation
        sync.rate = 0
        renderer.stopRequestingMediaData()
        feeder?.cancel(); feeder = nil
        renderer.flush()
        queue.sync { reader?.cancelReading() }   // (probe: the queue is idle once stopRequestingMediaData returned)
        let ctx = TapCtx(cap, playerRate: { 1 })
        let mix = audioMix(comp, algo: algo, tap: processesAtEnqueue ? nil : makeTap(ctx, pre: false))
        let r = try AVAssetReader(asset: comp)
        r.timeRange = CMTimeRange(start: cm(target), duration: cm(end - target))
        let o = AVAssetReaderAudioMixOutput(audioTracks: comp.tracks(withMediaType: .audio), audioSettings: pcmSettings)
        o.audioMix = mix
        o.audioTimePitchAlgorithm = algo
        r.add(o)
        r.startReading()
        reader = r; output = o
        firstEnqueued = .nan; enqueuedEnd = -.infinity
        let lock = NSLock()
        var enq = 0.0
        /// Feeds while the renderer wants data; paced (`ahead` > 0): only up to `ahead` past the clock (the target
        /// before the clock runs, plus what the start needs).
        let feed: () -> Bool = { [weak self] in
            guard let self, gen == self.generation else { return false }
            while self.renderer.isReadyForMoreMediaData {
                if self.ahead > 0 {
                    let clock = self.sync.rate != 0 ? self.sync.currentTime().seconds : target
                    if self.enqueuedEnd - clock > max(self.ahead, self.sync.rate != 0 ? 0 : startAfter) { return true }
                }
                guard let sb = o.copyNextSampleBuffer() else { return false }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds, d = CMSampleBufferGetDuration(sb).seconds
                // `--notap`: the lane processing would run HERE, at enqueue time, on samples labelled by the buffer's
                // PTS (no MTAudioProcessingTap); the probe records what it would process (left channel)
                if self.processesAtEnqueue, let bb = CMSampleBufferGetDataBuffer(sb) {
                    var len = 0
                    var ptr: UnsafeMutablePointer<CChar>?
                    if CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr) == noErr, let ptr {
                        let n = CMSampleBufferGetNumSamples(sb)
                        let p = UnsafeRawPointer(ptr).assumingMemoryBound(to: Float.self)
                        let ch = len / 4 / max(n, 1)
                        self.cap.add(Buf(label: pts, step: 1 / 48000, frames: n, sampleRate: 48000,
                                         samples: (0..<n).map { p[$0 * ch] }, host: CACurrentMediaTime()))
                    }
                }
                self.renderer.enqueue(sb)
                lock.lock()
                if self.firstEnqueued.isNaN { self.firstEnqueued = CACurrentMediaTime() }
                self.enqueuedEnd = pts + d
                enq = pts + d - target
                lock.unlock()
            }
            return true
        }
        if ahead > 0 {
            feeder?.cancel()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(5))
            t.setEventHandler { if !feed() { t.cancel() } }
            t.resume()
            feeder = t
        } else {
            renderer.requestMediaDataWhenReady(on: queue) { [weak self] in if !feed() { self?.renderer.stopRequestingMediaData() } }
        }
        spin(until: { lock.lock(); defer { lock.unlock() }; return enq >= startAfter }, timeout: 5)
        lock.lock(); let first = firstEnqueued; lock.unlock()
        sync.setRate(Float(rate), time: cm(target))
        // the synchronizer may hold its clock until the renderer can play: time to a MOVING clock (like AVPlayer's
        // play → clock start), extrapolated back to the instant it left the target
        spin(until: { self.sync.currentTime().seconds > target + 0.0005 }, timeout: 5)
        let moved = CACurrentMediaTime() - (sync.currentTime().seconds - target) / rate
        return (first - t0, moved - t0)
    }

}

func runRenderer(_ c: Case) throws {
    let seek = opt("seek", 1.3), seconds = opt("seconds", 2.5), ahead = opt("ahead", 0)
    let (comp, clip) = try composition(sourceRate: c.sourceRate, speed: c.speed)
    let s = RendererSession(rate: c.rate, ahead: ahead)
    var out: OutCapture?
    if opts["capture"] != nil {
        out = OutCapture(clock: { s.sync.timebase }, playerRate: { c.rate })
        if out == nil { print("PROBE capture unavailable: renderer muted"); s.renderer.volume = 0 }
    }
    // warm-up seek (first reader creation pays the asset load), then the measured one
    _ = try s.start(comp, algo: algorithm(c.algo), at: 0.2, end: clip.end)
    spin(0.3)
    s.cap.clear(); out?.cap.clear()
    let cpu0 = cpuSeconds()
    let t = try s.start(comp, algo: algorithm(c.algo), at: seek, end: clip.end)
    let tPlay = CACurrentMediaTime()
    var marks: [(host: Double, item: Double)] = []
    var stalls = 0, lastItem = -1.0
    while CACurrentMediaTime() - tPlay < seconds / c.rate + 0.4, s.sync.currentTime().seconds < clip.end - 0.3 {
        let it = s.sync.currentTime().seconds
        marks.append((CACurrentMediaTime(), it))
        if it == lastItem { stalls += 1 }
        lastItem = it
        spin(0.004)
    }
    let cpu = cpuSeconds() - cpu0, wall = CACurrentMediaTime() - tPlay
    let clockRate = marks.count > 2 ? (marks.last!.item - marks.first!.item) / (marks.last!.host - marks.first!.host) : .nan
    s.sync.rate = 0
    out?.stop()
    let caps = s.cap.snapshot
    let name = "renderer \(caseName(c))\(ahead > 0 ? " ahead \(ahead)" : "")"
    let r = leadSummary(name, caps, clip: clip, sourceRate: c.sourceRate, from: seek, to: clip.end)
    structure(name, caps, target: seek, clip: clip, coarse: r.lead / 1000, count: 4)
    var aheadMs: [Double] = []
    for b in caps where b.label.isFinite && b.host > tPlay + 0.05 {
        guard let m = marks.min(by: { abs($0.host - b.host) < abs($1.host - b.host) }), abs(m.host - b.host) < 0.05 else { continue }
        aheadMs.append((b.label - (m.item + (b.host - m.host) * c.rate)) / c.rate * 1000)
    }
    print("PROBE \(name) timing: seek→first PCM \(f(t.firstPCM * 1000, 1)) ms, seek→clock start \(f(t.clock * 1000, 1)) ms, clock rate \(f(clockRate, 3)),"
          + " tap ahead of clock median \(f(median(aheadMs), 0)) ms (max \(f(aheadMs.max() ?? .nan, 0))), clock stalls \(stalls) polls,"
          + " CPU \(f(cpu / wall * 100, 1)) % of a core over \(f(wall, 2)) s; \(describeOutput())")
    if let out {
        let oc = out.cap.snapshot.filter { $0.label >= seek }
        _ = leadSummary(name + " OUTPUT vs clock", oc, clip: clip, sourceRate: c.sourceRate, from: seek, to: clip.end)
    }
    // seek storm: 12 seeks 80 ms apart while playing, then time to a running clock and sound
    var lat: [Double] = []
    for k in 0..<12 {
        let tt = 1.5 + (Double(k) * 0.31).truncatingRemainder(dividingBy: max(0.5, clip.end - 2.2))   // inside the clip
        let r = try s.start(comp, algo: algorithm(c.algo), at: tt, end: clip.end)
        lat.append(r.clock * 1000)
        spin(0.08)
    }
    print("PROBE \(name) seek storm (12 seeks while playing, 80 ms apart): seek→clock median \(f(median(lat), 1)) ms, max \(f(lat.max() ?? .nan, 1)) ms")
    s.sync.rate = 0
}

/// AVPlayer seek storm for comparison: seeks 80 ms apart while playing (performSeek + playImmediately once landed).
func runPlayerSeekStorm(_ c: Case) throws {
    let (comp, clip) = try composition(sourceRate: c.sourceRate, speed: c.speed)
    let cap = Capture()
    let mix = audioMix(comp, algo: algorithm(c.algo), tap: makeTap(TapCtx(cap, playerRate: { c.rate }), pre: false))
    let item = AVPlayerItem(asset: comp)
    item.audioMix = mix
    let player = AVPlayer(playerItem: item)
    player.automaticallyWaitsToMinimizeStalling = false
    player.volume = 0
    guard spin(until: { item.status == .readyToPlay }, timeout: 15) else { return }
    player.playImmediately(atRate: Float(c.rate))
    spin(0.3)
    var lat: [Double] = []
    for k in 0..<12 {
        let tt = 1.5 + (Double(k) * 0.31).truncatingRemainder(dividingBy: max(0.5, clip.end - 2.2))   // inside the clip
        let t0 = CACurrentMediaTime()
        player.rate = 0
        var done = false
        player.seek(to: cm(tt), toleranceBefore: .zero, toleranceAfter: .zero) { _ in done = true }
        spin(until: { done }, timeout: 5)
        player.playImmediately(atRate: Float(c.rate))
        spin(until: { player.currentTime().seconds > tt + 0.0005 }, timeout: 5)
        lat.append((CACurrentMediaTime() - t0 - (player.currentTime().seconds - tt) / c.rate) * 1000)
        spin(0.08)
    }
    player.pause()
    _ = clip
    print("PROBE player seek storm \(caseName(c)) (12 seeks while playing, 80 ms apart): seek→clock median \(f(median(lat), 1)) ms, max \(f(lat.max() ?? .nan, 1)) ms")
}

/// Replacement plan's video side: AVPlayer keeps rendering video (custom compositor in Valse) with its clock driven by
/// the output's audio device clock (`sourceClock`), started at the same host time as the synchronizer; how far apart
/// do the two clocks run (A/V sync of the replacement), after a start and after seeks?
func runClocks(_ c: Case) throws {
    let (comp, clip) = try composition(sourceRate: c.sourceRate, speed: c.speed)
    let item = AVPlayerItem(asset: comp)
    let player = AVPlayer(playerItem: item)
    player.automaticallyWaitsToMinimizeStalling = false
    player.volume = 0
    guard spin(until: { item.status == .readyToPlay }, timeout: 15) else { return }
    var clock: CMClock?
    let st = CMAudioDeviceClockCreate(allocator: kCFAllocatorDefault, deviceUID: opts["device"] as CFString?, clockOut: &clock)
    guard st == noErr, let clock else { print("PROBE clocks: audio device clock \(st)"); return }
    player.sourceClock = clock
    let s = RendererSession(rate: c.rate, ahead: opt("ahead", 0.15))
    let src = s.sync.timebase.sourceClock.map { CFEqual($0, clock) } ?? false
    print("PROBE clocks: synchronizer source clock is the same device clock object: \(src)")
    var lines: [String] = []
    for (k, target) in [1.3, 2.4, 3.1, 1.8].enumerated() {
        // seek both (video: exact seek; audio: new reader), then start both at one host time 150 ms ahead
        s.sync.rate = 0
        player.rate = 0
        var done = false
        player.seek(to: cm(target), toleranceBefore: .zero, toleranceAfter: .zero) { _ in done = true }
        let a = try s.start(comp, algo: .spectral, at: target, end: clip.end, startAfter: 0.1)   // (starts the synchronizer)
        s.sync.rate = 0
        spin(until: { done }, timeout: 5)
        let host = CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(seconds: 0.15, preferredTimescale: 1_000_000_000)
        player.setRate(Float(c.rate), time: cm(target), atHostTime: host)
        s.sync.setRate(Float(c.rate), time: cm(target), atHostTime: host)
        var d: [Double] = []
        let t0 = CACurrentMediaTime()
        while CACurrentMediaTime() - t0 < 2.5 {
            let pt = player.currentTime().seconds, at = s.sync.currentTime().seconds
            if pt > target + 0.01 && at > target + 0.01 { d.append((at - pt) * 1000) }
            spin(0.01)
        }
        lines.append("seek \(k) to \(target): audio − video clock median \(f(median(d), 2)) ms, range \(f(d.min() ?? .nan, 2))..\(f(d.max() ?? .nan, 2)) ms over \(d.count) polls (audio first PCM \(f(a.firstPCM * 1000, 0)) ms)")
    }
    s.sync.rate = 0; player.pause()
    for l in lines { print("PROBE clocks \(caseName(c)) \(l)") }
}

// MARK: - au

func runAU() {
    for (name, sub) in [("NewTimePitch nutp", kAudioUnitSubType_NewTimePitch), ("TimePitch tmpt", kAudioUnitSubType_TimePitch),
                        ("Varispeed vari", kAudioUnitSubType_Varispeed), ("iPodTimeOther ipto", kAudioUnitSubType_AUiPodTimeOther)] {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_FormatConverter, componentSubType: sub,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { print("PROBE AU \(name): not found"); continue }
        var unit: AudioUnit?
        AudioComponentInstanceNew(comp, &unit)
        guard let u = unit else { continue }
        var fmt = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                              mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked,
                                              mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, UInt32(MemoryLayout.size(ofValue: fmt)))
        AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &fmt, UInt32(MemoryLayout.size(ofValue: fmt)))
        AudioUnitInitialize(u)
        var line = "PROBE AU \(name):"
        for rate in [1.0, 2.0, 0.5] {
            AudioUnitSetParameter(u, sub == kAudioUnitSubType_Varispeed ? kVarispeedParam_PlaybackRate : kNewTimePitchParam_Rate, kAudioUnitScope_Global, 0, AudioUnitParameterValue(rate), 0)
            var lat = 0.0, sz = UInt32(8)
            let st = AudioUnitGetProperty(u, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &lat, &sz)
            line += String(format: " rate %.1f latency %.0f frames (status %d);", rate, lat * 48000, st)
        }
        print(line)
        AudioUnitUninitialize(u)
        AudioComponentInstanceDispose(u)
    }
}

// MARK: - main

print("PROBE host: macOS \(osVersion) \(arch); \(describeOutput())")
var restoreRate: (AudioObjectID, Double)?
if let r = opts["out-rate"].flatMap(Double.init) {
    let id = defaultOutputDevice()
    let old = deviceRate(id)
    let st = setDeviceRate(id, r)
    print("PROBE out-rate \(old) → \(r): status \(st), now \(describeOutput())")
    restoreRate = (id, old)
}
defer { if let (id, r) = restoreRate { setDeviceRate(id, r) } }

let single = Case(algo: opts["algo"] ?? "spectral", rate: opt("rate", 1), speed: opt("speed", 1), sourceRate: opt("src", 48000))
do {
    switch command {
    case "player": try runPlayer(single)
    case "export": try runExport(single)
    case "renderer": try runRenderer(single)
    case "aq": runAQ(algo: single.algo, rate: single.rate, bypass: UInt32(opt("bypass", 0)), sourceRate: single.sourceRate)
    case "au": runAU()
    case "devices": listDevices()
    case "storm": try runPlayerSeekStorm(single)
    case "clocks": try runClocks(single)
    case "matrix":
        let algos = (opts["algos"] ?? "spectral,timeDomain,varispeed").split(separator: ",").map(String.init)
        let pairs: [(Double, Double)] = [(1, 1), (2, 1), (0.5, 1), (1, 2), (2, 2), (1, 0.5), (2, 0.5)]
        runAU()
        for a in algos { for (r, s) in pairs { try runPlayer(Case(algo: a, rate: r, speed: s, sourceRate: 48000)) } }
        try runPlayer(Case(algo: "spectral", rate: 1, speed: 1, sourceRate: 44100))
        for a in algos { try runExport(Case(algo: a, rate: 1, speed: 1, sourceRate: 48000)) }
        try runExport(Case(algo: "spectral", rate: 1, speed: 2, sourceRate: 48000))
        for a in algos { for b: UInt32 in [0, 1] { runAQ(algo: a, rate: 1, bypass: b, sourceRate: 48000) } }
        runAQ(algo: "spectral", rate: 2, bypass: 0, sourceRate: 48000)
    case "replacement":
        for (r, s) in [(1.0, 1.0), (2.0, 1.0), (0.5, 1.0), (1.0, 2.0), (1.0, 0.5)] {
            try runRenderer(Case(algo: "spectral", rate: r, speed: s, sourceRate: 48000))
        }
        try runRenderer(Case(algo: "spectral", rate: 1, speed: 1, sourceRate: 44100))
        try runPlayerSeekStorm(Case(algo: "spectral", rate: 1, speed: 1, sourceRate: 48000))
    default:
        print("usage: AudioTimingProbe player|export|aq|renderer|clocks|au|devices|storm|matrix|replacement [--notap] [--algo spectral|timeDomain|varispeed] [--rate R] [--speed S] [--src 48000|44100] [--seek s] [--seconds s] [--device UID] [--out-rate Hz] [--pre] [--capture] [--ahead s] [--bypass 0|1] [--dir path] [--events]")
    }
} catch {
    print("PROBE error: \(error)")
}
