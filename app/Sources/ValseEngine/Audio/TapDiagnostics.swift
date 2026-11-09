import CoreAudio
import Foundation
import os

/// BUG-CUT-AUDIO-HOLE: how many buffers early AVPlayer's post-effects tap stamps its buffers, for PREVIEW lanes
/// (`LaneProcessor.leadBuffers`). One buffer was measured on Apple Silicon / macOS 26 (BUG-METALLIC-AUDIO); an Intel
/// Mac on macOS 13 showed an 85 ms (one tap buffer) hole of exact zeros at a cut in preview only, as if the labelling
/// differed there. Diagnostic override, read once per composition build:
/// `defaults write fr.valse.Valse ValseTapLabelLead -int 0` (0 = stamps used as is, like export; 1 = one buffer, the
/// default; 2 = two buffers), `defaults delete fr.valse.Valse ValseTapLabelLead` = automatic. Env `VALSE_TAP_LABEL_LEAD`
/// (same values) wins over the defaults (tests). Export never applies a lead (its stamps are exact).
public enum TapLabelLead {
    public static let defaultsKey = "ValseTapLabelLead"
    public static let environmentKey = "VALSE_TAP_LABEL_LEAD"
    /// The automatic value for preview lanes.
    public static let automatic = 1

    /// Preview lead in buffers (0…2) and where it came from ("auto", "defaults", "env").
    public static func preview(defaults: UserDefaults = .standard,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> (buffers: Int, source: String) {
        if let s = environment[environmentKey], let v = Int(s.trimmingCharacters(in: .whitespaces)), (0...2).contains(v) {
            return (v, "env")
        }
        if let o = defaults.object(forKey: defaultsKey) {
            let v = (o as? NSNumber)?.intValue ?? (o as? String).flatMap { Int($0) }
            if let v, (0...2).contains(v) { return (v, "defaults") }
        }
        return (automatic, "auto")
    }

    /// "lead 1 (auto)": the active preview mode, for log lines.
    public static func describePreview() -> String {
        let m = preview()
        return "lead \(m.buffers) (\(m.source))"
    }
}

/// One buffer as the lane tap received it (BUG-CUT-AUDIO-HOLE probe).
public struct TapBufferRecord: Sendable, Equatable {
    /// Raw timestamp in seconds (NaN = none).
    public var stamp: Double
    public var frames: Int
    /// Reported duration in seconds (NaN = invalid).
    public var duration: Double
    public var sampleRate: Double
    /// The buffer had a non-zero sample BEFORE the lane gains (the source was sounding).
    public var sounding: Bool
    /// Index of its first non-zero sample before the lane gains (-1: silent).
    public var firstSound: Int = -1
    /// Composition time the lane gave its first frame (stamp + lead: what the gains used; NaN = none).
    public var label: Double = .nan
    static let empty = TapBufferRecord(stamp: .nan, frames: 0, duration: .nan, sampleRate: 0, sounding: false)
}

/// The first buffers each lane tap received after its last prepare / reset (each seek / play start). The lanes write
/// on the audio render thread with `withLockIfAvailable` only (never waits: a busy lock drops the publication until
/// the next buffer), into fixed storage (no allocation); `PlaybackEngine` takes the new captures off that thread.
public final class TapDiagnostics: @unchecked Sendable {
    public static let buffersPerCapture = 6
    static let slots = 16

    public struct Capture: Sendable, Equatable {
        public let lane: Int
        public let leadBuffers: Int
        public let buffers: [TapBufferRecord]
    }

    private struct Store: @unchecked Sendable {
        var records = [TapBufferRecord](repeating: .empty, count: TapDiagnostics.slots * TapDiagnostics.buffersPerCapture)
        var counts = [Int](repeating: 0, count: TapDiagnostics.slots)
        var leads = [Int](repeating: 0, count: TapDiagnostics.slots)
        var lanes = [Int](repeating: 0, count: TapDiagnostics.slots)
        /// Publication number per slot (0 = never), and the last one taken.
        var published = [Int](repeating: 0, count: TapDiagnostics.slots)
        var taken = [Int](repeating: 0, count: TapDiagnostics.slots)
        var serial = 0
    }
    private let store = OSAllocatedUnfairLock(initialState: Store())

    public init() {}

    /// Slot for a lane (`lane` = its index in the composition; slots are reused modulo 16).
    func slot(forLane lane: Int) -> Int { ((lane % Self.slots) + Self.slots) % Self.slots }

    /// Audio thread: publishes `count` records of a lane. false = the lock was busy (retry later).
    @discardableResult
    func publish(slot: Int, lane: Int, lead: Int, records: UnsafePointer<TapBufferRecord>, count: Int) -> Bool {
        let n = min(count, Self.buffersPerCapture)
        let r = UnsafeSendable(records)
        let done: Bool? = store.withLockIfAvailable { (s: inout Store) -> Bool in
            let base = slot * Self.buffersPerCapture
            for i in 0..<n { s.records[base + i] = r.pointer[i] }
            s.counts[slot] = n; s.leads[slot] = lead; s.lanes[slot] = lane
            s.serial &+= 1
            s.published[slot] = s.serial
            return true
        }
        return done == true
    }

    /// Captures published since the last call (one per lane, the latest).
    public func take() -> [Capture] {
        store.withLock { (s: inout Store) -> [Capture] in
            var out: [Capture] = []
            for slot in 0..<Self.slots where s.published[slot] != s.taken[slot] {
                s.taken[slot] = s.published[slot]
                let base = slot * Self.buffersPerCapture
                out.append(Capture(lane: s.lanes[slot], leadBuffers: s.leads[slot],
                                   buffers: Array(s.records[base..<(base + s.counts[slot])])))
            }
            return out.sorted { $0.lane < $1.lane }
        }
    }

    /// Self-check of a capture against the seek target `target` (item time) at player rate `rate`
    /// (BUG-CUT-AUDIO-HOLE part 2, docs/investigations/BUG-METALLIC-AUDIO.md):
    /// - `firstStamp`: first raw stamp − target (s);
    /// - `rawOnset` / `onset`: composition time of the first sounding frame (before the gains) − target, from the raw
    ///   stamp / from the label the lane used. After a seek AVPlayer hands the taps preroll silence, then the item's
    ///   audio from exactly the target (measured on the content), so when the media sounds at the target `onset` ≈ 0
    ///   means the labels are right and `rawOnset` = −(the stamps' lead): −85.3 ms on Apple Silicon / macOS 26 (spectral
    ///   lanes, unscaled clip, rate 1). A NEGATIVE value means labels early; positive, labels late or media quiet at
    ///   the target (a quiet start only reads later). nil when the first sounding buffer had no stamp.
    public static func selfCheck(_ c: Capture, target: Double, rate: Double)
    -> (firstStamp: Double?, rawOnset: Double?, onset: Double?) {
        let first = c.buffers.first { !$0.stamp.isNaN }.map { $0.stamp - target }
        guard let b = c.buffers.first(where: \.sounding), !b.stamp.isNaN, b.sampleRate > 0, b.firstSound >= 0 else { return (first, nil, nil) }
        let offset = Double(b.firstSound) * max(rate, 1e-3) / b.sampleRate
        return (first, b.stamp + offset - target, b.label.isNaN ? nil : b.label + offset - target)
    }

    /// One log line (stamps to 0.1 ms; Δ = stamp step in frames, which a lead-labelled tap shows as the PREVIOUS
    /// buffer's frames; @n = first sounding sample), then, with `target`, the self-check against the seek target.
    public static func describe(_ c: Capture, target: Double? = nil, rate: Double = 1) -> String {
        var parts: [String] = []
        var prev: TapBufferRecord?
        for (i, b) in c.buffers.enumerated() {
            var s = "#\(i) "
            s += b.stamp.isNaN ? "nostamp" : String(format: "%.4f", b.stamp)
            s += " \(b.frames)f"
            s += b.duration.isNaN ? " d?" : String(format: " d%.2fms", b.duration * 1000)
            if let p = prev, !p.stamp.isNaN, !b.stamp.isNaN {
                s += String(format: " Δ%+.0ff", (b.stamp - p.stamp) * b.sampleRate)
            }
            s += String(format: " %.0fHz", b.sampleRate)
            s += b.sounding ? (b.firstSound >= 0 ? " snd@\(b.firstSound)" : " snd") : " sil"
            parts.append(s)
            prev = b
        }
        var line = "lane \(c.lane) tap lead \(c.leadBuffers): " + parts.joined(separator: " | ")
        if let target {
            func ms(_ v: Double?) -> String { v.map { String(format: "%+.1f ms", $0 * 1000) } ?? "?" }
            let k = selfCheck(c, target: target, rate: rate)
            line += " || vs target: first stamp \(ms(k.firstStamp)), sound onset raw \(ms(k.rawOnset)) / labelled \(ms(k.onset))"
        }
        return line
    }
}

/// A pointer handed into a `@Sendable` non-escaping closure on the same thread.
private struct UnsafeSendable<T>: @unchecked Sendable { let pointer: UnsafePointer<T>; init(_ p: UnsafePointer<T>) { pointer = p } }

extension AudioDevices {
    /// Nominal sample rate and IO buffer size (frames) of the system default output device (diagnostics).
    public static func defaultOutputFormat() -> (sampleRate: Double, bufferFrames: UInt32)? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        var rate = Float64(0)
        size = UInt32(MemoryLayout<Float64>.size)
        addr.mSelector = kAudioDevicePropertyNominalSampleRate
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate) == noErr else { return nil }
        var frames = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        addr.mSelector = kAudioDevicePropertyBufferFrameSize
        addr.mScope = kAudioObjectPropertyScopeOutput
        if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &frames) != noErr { frames = 0 }
        return (rate, frames)
    }
}
