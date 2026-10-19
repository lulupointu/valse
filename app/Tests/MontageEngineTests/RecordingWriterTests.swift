import Testing
import Foundation
@preconcurrency import AVFoundation
import CoreMedia
@testable import MontageCore
@testable import MontageEngine

/// MI-015 / MI-017: the capture writer, fed with synthetic sample buffers (no real capture / permission needed).
@Suite struct RecordingWriterTests {
    static func videoSample(_ t: Double, width: Int = 320, height: Int = 181, grey: UInt8 = 128) -> CMSampleBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        memset(CVPixelBufferGetBaseAddress(pb!), Int32(grey), CVPixelBufferGetDataSize(pb!))
        CVPixelBufferUnlockBaseAddress(pb!, [])
        var fmt: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb!, formatDescriptionOut: &fmt)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(seconds: t, preferredTimescale: 600),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb!, formatDescription: fmt!, sampleTiming: &timing, sampleBufferOut: &sb)
        return sb!
    }

    /// 1/30 s of 48 kHz stereo float PCM (a 440 Hz tone).
    static func audioSample(_ t: Double) -> CMSampleBuffer {
        let frames = 1600
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
                                               mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                       extensions: nil, formatDescriptionOut: &fmt)
        var samples = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames { let v = Float(sin(2 * .pi * 440 * (t + Double(i) / 48_000)) * 0.3); samples[2 * i] = v; samples[2 * i + 1] = v }
        var block: CMBlockBuffer?
        let bytes = samples.count * 4
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                                           offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
        samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes) }
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: fmt!, sampleCount: frames,
                                                             presentationTimeStamp: CMTime(seconds: t, preferredTimescale: 48_000),
                                                             packetDescriptions: nil, sampleBufferOut: &sb)
        return sb!
    }

    func tmp(_ name: String) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(name)-\(UUID().uuidString).mov") }

    @Test func writesVideoAndAudioWithPauseRemoved() async throws {
        let url = tmp("av")
        defer { try? FileManager.default.removeItem(at: url) }
        let w = RecordingWriter(url: url, recordsAudio: true, realTime: false)
        let base = 1000.0   // host-clock-like times
        w.appendAudio(Self.audioSample(base - 0.5))   // before the first frame: dropped
        for i in 0..<30 { let t = base + Double(i) / 30; w.appendAudio(Self.audioSample(t)); w.appendVideo(Self.videoSample(t)) }
        w.pause(at: CMTime(seconds: base + 1, preferredTimescale: 600))
        for i in 30..<60 { w.appendVideo(Self.videoSample(base + Double(i) / 30)) }   // paused: dropped
        w.resume(at: CMTime(seconds: base + 2, preferredTimescale: 600))
        #expect(!w.isPaused)
        for i in 60..<90 { let t = base + Double(i) / 30; w.appendAudio(Self.audioSample(t)); w.appendVideo(Self.videoSample(t)) }
        #expect(w.videoFrames == 60)
        #expect(abs(w.recordedSeconds - 59.0 / 30) < 0.01)
        let out = try await w.finish()
        let asset = AVURLAsset(url: out)
        let d = try await asset.load(.duration).seconds
        #expect(d > 1.9 && d < 2.15, "duration \(d)")
        let v = try await asset.loadTracks(withMediaType: .video)
        let a = try await asset.loadTracks(withMediaType: .audio)
        #expect(v.count == 1 && a.count == 1)
        let size = try await v[0].load(.naturalSize)
        #expect(size == CGSize(width: 320, height: 180))   // made even
    }

    @Test func noFramesThrowsAndCleansUp() async {
        let url = tmp("empty")
        let w = RecordingWriter(url: url, recordsAudio: true)
        w.appendAudio(Self.audioSample(1))
        await #expect(throws: RecordingWriter.WriterError.noFrames) { _ = try await w.finish() }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func captureSizeAndFileNames() {
        #expect(ScreenCapture.captureSize(points: CGSize(width: 1440, height: 900), scale: 2) == (2880, 1800))
        let (w, h) = ScreenCapture.captureSize(points: CGSize(width: 3008, height: 1692), scale: 2)
        #expect(w == 3840 && h <= 2160 && h % 2 == 0)
        let s = RecordingSession(options: .init(mode: .screen), folder: URL(fileURLWithPath: "/tmp/r"),
                                 date: Date(timeIntervalSince1970: 0))
        #expect(s.fileURL(.screen, baseName: "Screen recording").lastPathComponent.hasPrefix("Screen recording 19"))
        #expect(s.fileURL(.screen, baseName: "Screen recording").pathExtension == "mov")
    }

    @Test func permissionOverrideNeverPrompts() async {
        RecordingPermission.override = [:]
        defer { RecordingPermission.override = nil }
        #expect(RecordingPermission.status(.screen) == .notDetermined)
        #expect(await RecordingPermission.request(.screen) == .denied)
        #expect(RecordingPermission.status(.screen) == .denied)
        #expect(RecordingPermission.settingsURL(.screen).absoluteString.contains("Privacy_ScreenCapture"))
    }
}
