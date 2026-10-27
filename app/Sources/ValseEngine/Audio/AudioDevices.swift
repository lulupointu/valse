@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// Tests run silently: `VALSE_MUTE_AUDIO=1` (exported by the test scripts) or a UI-test run (`--uitest`) silences every
/// sound the app plays (preview, scrub grains, library previews, TTS sample, notification sounds). Renders and exports
/// are unaffected.
public enum AudioOutput {
    public static let isSilenced = ProcessInfo.processInfo.environment["VALSE_MUTE_AUDIO"] == "1"
        || CommandLine.arguments.contains("--uitest")
    /// `v`, or 0 when silenced.
    public static func volume(_ v: Float) -> Float { isSilenced ? 0 : v }
}

/// CoreAudio device lists for Settings ▸ Audio (SE-011 / AU-024): output device of the preview, default input of the
/// voice-over recorder.
public enum AudioDevices {
    public struct Device: Identifiable, Hashable, Sendable {
        public let id: AudioDeviceID
        public let name: String
        public let uid: String
    }

    public static func outputs() -> [Device] { devices(scope: kAudioDevicePropertyScopeOutput) }
    public static func inputs() -> [Device] { devices(scope: kAudioDevicePropertyScopeInput) }

    /// Device id for a persisted UID (nil when it is gone, e.g. headphones unplugged → system default).
    public static func id(forUID uid: String?, in list: [Device]) -> AudioDeviceID? {
        guard let uid else { return nil }
        return list.first { $0.uid == uid }?.id
    }

    static func devices(scope: AudioObjectPropertyScope) -> [Device] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope,
                                               mElement: kAudioObjectPropertyElementMain)
            var s: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &s) == noErr, s > 0 else { return nil }
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(s), alignment: 16)
            defer { raw.deallocate() }
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, raw) == noErr else { return nil }
            let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
            guard list.reduce(0, { $0 + Int($1.mNumberChannels) }) > 0 else { return nil }
            return Device(id: id, name: string(id, kAudioObjectPropertyName) ?? "?", uid: string(id, kAudioDevicePropertyDeviceUID) ?? "\(id)")
        }
    }

    private static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var s = UInt32(MemoryLayout<CFString?>.size)
        var v: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &v) == noErr, let v else { return nil }
        return v.takeRetainedValue() as String
    }
}

/// Valse's own short UI sounds (AU-040 "Send a notification sound when export is complete"): synthesized chimes,
/// no bundled audio files. Success = two rising soft sine notes, failure = two falling low notes.
@MainActor
public enum NotificationSounds {
    public enum Kind: Sendable { case success, failure }
    private static var players: [AVAudioPlayer] = []

    public static func play(_ kind: Kind) {
        guard let data = wav(kind), let p = try? AVAudioPlayer(data: data) else { return }
        p.volume = AudioOutput.volume(0.6)
        players.removeAll { !$0.isPlaying }
        players.append(p)
        p.play()
    }

    /// 16-bit mono WAV of the chime.
    public nonisolated static func wav(_ kind: Kind) -> Data? {
        let sr = 44_100.0
        let notes: [(Double, Double)] = kind == .success ? [(880, 0.12), (1318.5, 0.28)] : [(392, 0.16), (261.6, 0.32)]
        var samples: [Int16] = []
        for (f, d) in notes {
            let n = Int(d * sr)
            for i in 0..<n {
                let t = Double(i) / sr
                let env = min(1, t / 0.01) * exp(-t * (kind == .success ? 9 : 6))
                let v = (sin(2 * .pi * f * t) + 0.25 * sin(4 * .pi * f * t)) * env * 0.5
                samples.append(Int16(max(-1, min(1, v)) * 32_000))
            }
        }
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sr)); u32(UInt32(sr) * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in samples { u16(UInt16(bitPattern: s)) }
        return d
    }
}
