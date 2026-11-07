import CoreAudio
import Foundation
import os
import QuartzCore

/// What THIS process actually sends to its audio output, after AVPlayer's audio queues and mixer (BUG-PLAY-SILENT): a
/// Core Audio process tap on our own process, MUTED (nothing reaches the device while it runs), read through a private
/// aggregate device. Lane taps (`AudioMixState.tapCapture`) see the audio before AVPlayer's queues; this sees what the
/// listener would hear. macOS 14.2+. Note: tests export `VALSE_MUTE_AUDIO` (player volume 0): set the player's volume
/// to 1 for a capture, and route it to a virtual output (`audioOutputDeviceUniqueID`) as a second guard.
@available(macOS 14.2, *)
public final class OutputCapture: @unchecked Sendable {
    /// One IO cycle of captured output: host time (CACurrentMediaTime base), RMS and peak over every channel.
    public struct Chunk: Sendable { public let host: Double; public let rms: Float; public let peak: Float }

    private let chunks = OSAllocatedUnfairLock(initialState: [Chunk]())
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    public enum Failure: Error { case status(String, OSStatus) }

    /// `clockDeviceUID`: the aggregate's clock device (a virtual output such as "SteamStreamingSpeakers_UID").
    public init(clockDeviceUID: String) throws {
        var pid = getpid()
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var process = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process)
        guard st == noErr, process != kAudioObjectUnknown else { throw Failure.status("process object", st) }
        let desc = CATapDescription(stereoMixdownOfProcesses: [process])
        desc.muteBehavior = .muted
        desc.isPrivate = true
        st = AudioHardwareCreateProcessTap(desc, &tapID)
        guard st == noErr else { throw Failure.status("process tap", st) }
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ValseOutputCapture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: clockDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clockDeviceUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        st = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggregateID)
        guard st == noErr else { AudioHardwareDestroyProcessTap(tapID); throw Failure.status("aggregate", st) }
        let store = chunks
        st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            var sum = 0.0, n = 0, peak: Float = 0
            for b in abl {
                guard let d = b.mData else { continue }
                let f = d.assumingMemoryBound(to: Float.self)
                for i in 0..<(Int(b.mDataByteSize) / 4) { let v = f[i]; sum += Double(v * v); peak = max(peak, abs(v)) }
                n += Int(b.mDataByteSize) / 4
            }
            let c = Chunk(host: CACurrentMediaTime(), rms: n > 0 ? Float((sum / Double(n)).squareRoot()) : 0, peak: peak)
            store.withLock { $0.append(c) }
        }
        guard st == noErr else { stop(); throw Failure.status("io proc", st) }
        st = AudioDeviceStart(aggregateID, procID)
        guard st == noErr else { stop(); throw Failure.status("start", st) }
    }

    /// Captured chunks with host time in `[from, to)`.
    public func chunks(from: Double, to: Double) -> [Chunk] { chunks.withLock { $0.filter { $0.host >= from && $0.host < to } } }

    public func stop() {
        if let procID, aggregateID != kAudioObjectUnknown { AudioDeviceStop(aggregateID, procID); AudioDeviceDestroyIOProcID(aggregateID, procID) }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = AudioObjectID(kAudioObjectUnknown) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
    }
    deinit { stop() }
}
