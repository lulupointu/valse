@preconcurrency import AVFoundation
import Foundation
import MontageCore

/// Audio scrubbing (TL-032 / AU-023, Settings ▸ "Play audio while scrubbing"): while the playhead is dragged, a short
/// grain (≈ 90 ms) of every audible clip under it is decoded from the source media and played through its own
/// `AVAudioEngine`, independent of the preview `AVPlayer` (no rate changes or extra seeks there). Requests are
/// coalesced: while a grain is being decoded only the latest position is kept. Clip gain and track mute/solo apply;
/// effects/voice changers are not rendered in the grains.
@MainActor
public final class ScrubAudio {
    public static let shared = ScrubAudio()

    public nonisolated static let grain: Double = 0.09
    nonisolated static let sampleRate: Double = 44_100

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: ScrubAudio.sampleRate, channels: 2)!
    private var started = false
    private var busy = false
    private var pending: (Project, Time)?
    private var lastTime: Time?
    /// Grains played (tests).
    public private(set) var playedCount = 0

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    /// Plays the audio at `t` (call on every scrub move). Cheap when nothing is audible there.
    public func scrub(_ project: Project, at t: Time) {
        if let last = lastTime, abs((last - t).seconds) < 0.01 { return }
        lastTime = t
        if busy { pending = (project, t); return }
        let sources = Self.sources(in: project, at: t)
        guard !sources.isEmpty else { return }
        busy = true
        // `mix` blocks (semaphore around the track load, copyNextSampleBuffer): a GCD thread, not the cooperative pool
        let fmt = UncheckedSendable(format)
        DispatchQueue.global(qos: .userInitiated).async {
            let buffer = UncheckedSendable(Self.mix(sources, format: fmt.value))
            Task { @MainActor in self.finish(buffer.value) }
        }
    }

    /// Stops the current grain (end of a scrub).
    public func stop() {
        pending = nil; lastTime = nil
        if started { node.stop() }
    }

    private func finish(_ buffer: AVAudioPCMBuffer?) {
        busy = false
        if let buffer { play(buffer) }
        if let (p, t) = pending { pending = nil; lastTime = nil; scrub(p, at: t) }
    }

    private func play(_ buffer: AVAudioPCMBuffer) {
        if !started {
            engine.mainMixerNode.outputVolume = AudioOutput.volume(1)
            do { try engine.start(); started = true } catch { EngineLog.error("scrub audio: \(error)"); return }
        }
        node.stop()
        node.scheduleBuffer(buffer, at: nil, options: .interrupts)
        node.play()
        playedCount += 1
    }

    /// A media span to read for one grain.
    public struct Source: Sendable, Equatable {
        public var url: URL
        public var sourceTime: Time
        public var gain: Float
        public var stream: Int
    }

    /// Audible audio-bearing clips at `t` (top-level tracks; mute, solo, clip mute/gain, enabled flags honoured).
    public nonisolated static func sources(in project: Project, at t: Time) -> [Source] {
        var out: [Source] = []
        let lookup = project.mediaLookup
        for track in project.timeline.tracks where project.timeline.isAudible(track) && track.kind != .text {
            for c in track.clips(at: t) where c.isEnabled && c.audio.isAudible && c.audio.volume * track.gain > 0.001 {
                guard let id = c.mediaID, let a = lookup[id], a.hasAudio else { continue }
                let url = PlayableMediaCache.shared.resolvedURL(for: a)
                out.append(Source(url: url, sourceTime: c.sourceTime(at: t), gain: Float(min(c.audio.volume * track.gain, 4)),
                                  stream: c.audioStreamIndex ?? 0))
            }
        }
        return out
    }

    /// Decodes and sums one grain of every source (with 5 ms fades so grains don't click).
    nonisolated static func mix(_ sources: [Source], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(grain * sampleRate)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        out.frameLength = frames
        guard let l = out.floatChannelData?[0], let r = out.floatChannelData?[1] else { return nil }
        for i in 0..<Int(frames) { l[i] = 0; r[i] = 0 }
        var any = false
        for s in sources {
            guard let pcm = read(s) else { continue }
            any = true
            let n = min(Int(frames), pcm.count / 2)
            for i in 0..<n { l[i] += pcm[2 * i] * s.gain; r[i] += pcm[2 * i + 1] * s.gain }
        }
        guard any else { return nil }
        let fade = Int(0.005 * sampleRate)
        for i in 0..<fade {
            let g = Float(i) / Float(fade)
            l[i] *= g; r[i] *= g
            let j = Int(frames) - 1 - i
            l[j] *= g; r[j] *= g
        }
        return out
    }

    /// Interleaved stereo float samples of one grain starting at the source time.
    nonisolated static func read(_ s: Source) -> [Float]? {
        let asset = AVURLAsset(url: s.url)
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var tracks: [AVAssetTrack] = []
        asset.loadTracks(withMediaType: .audio) { t, _ in tracks = t ?? []; sem.signal() }
        sem.wait()
        guard !tracks.isEmpty, let reader = try? AVAssetReader(asset: asset) else { return nil }
        let track = tracks[min(max(s.stream, 0), tracks.count - 1)]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2])
        reader.add(output)
        reader.timeRange = CMTimeRange(start: s.sourceTime.cmTime, duration: CMTime(seconds: grain + 0.02, preferredTimescale: 44_100))
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }
        var samples: [Float] = []
        let want = Int(grain * sampleRate) * 2
        while samples.count < want, let sb = output.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            var len = 0
            var ptr: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr) == noErr,
                  let ptr else { continue }
            ptr.withMemoryRebound(to: Float.self, capacity: len / 4) { f in samples.append(contentsOf: UnsafeBufferPointer(start: f, count: len / 4)) }
        }
        return samples.isEmpty ? nil : samples
    }
}
