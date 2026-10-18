@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import MontageCore

/// Microphone recording for voice-overs (MI-016 / AU-020): AVAudioEngine input → CAF file, live input level,
/// optional Apple voice processing ("Echo reduction", AU-026), input device selection.
public final class VoiceRecorder: @unchecked Sendable {
    public struct InputDevice: Identifiable, Hashable, Sendable {
        public let id: AudioDeviceID
        public let name: String
        public let uid: String
    }

    public enum Permission: Sendable { case granted, denied, undetermined }

    public static var permission: Permission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .undetermined
        default: return .denied
        }
    }

    public static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Input-capable devices (CoreAudio).
    public static func inputDevices() -> [InputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput,
                                               mElement: kAudioObjectPropertyElementMain)
            var s: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &s) == noErr, s > 0 else { return nil }
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(s), alignment: 16)
            defer { raw.deallocate() }
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, raw) == noErr else { return nil }
            let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
            guard list.reduce(0, { $0 + Int($1.mNumberChannels) }) > 0 else { return nil }
            return InputDevice(id: id, name: string(id, kAudioObjectPropertyName) ?? "?", uid: string(id, kAudioDevicePropertyDeviceUID) ?? "\(id)")
        }
    }

    private static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var s = UInt32(MemoryLayout<CFString?>.size)
        var v: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &v) == noErr, let v else { return nil }
        return v.takeRetainedValue() as String
    }

    private let engine = AVAudioEngine()
    private var writer: AVAudioFile?
    private let lock = NSLock()
    private var _level: Float = 0
    private var _frames: AVAudioFramePosition = 0
    private var sampleRate: Double = 48000
    public private(set) var url: URL?
    public var gain: Float = 1

    public init() {}

    /// Peak input level 0…1 of the last buffer (for the meter).
    public var level: Float { lock.withLock { _level } }
    /// Recorded duration so far.
    public var duration: Time { lock.withLock { Time(Double(_frames) / max(sampleRate, 1)) } }
    public var isRunning: Bool { engine.isRunning }

    /// Starts metering (and recording if `url` is given). `echoReduction` enables the system voice-processing unit.
    public func start(device: AudioDeviceID? = nil, echoReduction: Bool = false, recordTo url: URL?) throws {
        stop()
        let input = engine.inputNode
        if echoReduction { try? input.setVoiceProcessingEnabled(true) } else if input.isVoiceProcessingEnabled { try? input.setVoiceProcessingEnabled(false) }
        if let device, let unit = input.audioUnit {
            var d = device
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw NSError(domain: "Montage.record", code: 1) }
        sampleRate = format.sampleRate
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            writer = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false],
                commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        self.url = url
        lock.withLock { _frames = 0; _level = 0 }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buf, _ in self?.handle(buf) }
        engine.prepare()
        try engine.start()
    }

    private func handle(_ buf: AVAudioPCMBuffer) {
        guard let data = buf.floatChannelData else { return }
        let n = Int(buf.frameLength)
        var peak: Float = 0
        for c in 0..<Int(buf.format.channelCount) {
            let p = data[c]
            if gain != 1 { for i in 0..<n { p[i] *= gain } }
            for i in 0..<n { peak = max(peak, abs(p[i])) }
        }
        try? writer?.write(from: buf)
        lock.withLock { _level = peak; if writer != nil { _frames += AVAudioFramePosition(n) } }
    }

    /// Stops; returns the recorded file (nil when only metering).
    @discardableResult
    public func stop() -> URL? {
        if engine.isRunning || engine.inputNode.numberOfInputs > 0 {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        let had = writer != nil
        writer = nil   // closes the file
        return had ? url : nil
    }
}
