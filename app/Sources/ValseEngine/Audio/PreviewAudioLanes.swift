@preconcurrency import AVFoundation
import Foundation

/// The reading side of `PreviewAudio` (BUG-CUT-AUDIO-HOLE phase A): one `AVAssetReader` over a preview composition,
/// one `AVAssetReaderAudioMixOutput` per composition audio lane (no tap, no volume ramps: the reader stamps exactly on
/// every OS, docs/investigations/BUG-METALLIC-AUDIO.md part 5), each lane's `LaneProcessor` run on the reader's
/// buffers labelled by their PTS (no lead; composition time per frame = 1 / sample rate, what the reader delivers,
/// speed-scaled segments included), and a mixer summing the lanes into fixed-size interleaved stereo chunks placed by
/// absolute frame index (`frame = time × sampleRate`).
/// Confined to the caller's serial queue: every `copyNextSampleBuffer` and the `cancelReading` run on it (export rule,
/// ReaderCancel.swift: never cancel a reader while a read may be in flight).
final class PreviewAudioLanes {
    static let sampleRate: Double = 48000
    nonisolated(unsafe) static let pcmSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    /// Absolute frame index of a composition time (48 kHz).
    static func frame(_ t: CMTime) -> Int {
        guard t.isNumeric else { return 0 }
        return Int(CMTimeConvertScale(t, timescale: Int32(sampleRate), method: .roundHalfAwayFromZero).value)
    }
    static func frame(_ seconds: Double) -> Int { Int((seconds * sampleRate).rounded()) }

    /// Processed audio of one lane, at absolute frames [start, start + count).
    struct Segment { let start: Int; var left: [Float]; var right: [Float]; var end: Int { start + left.count } }

    final class Lane {
        let output: AVAssetReaderAudioMixOutput
        let processor: LaneProcessor
        var segments: [Segment] = []
        /// End (absolute frame) of what the reader delivered so far.
        var readEnd: Int
        var done = false
        init(output: AVAssetReaderAudioMixOutput, processor: LaneProcessor, start: Int) {
            self.output = output; self.processor = processor; readEnd = start
        }
    }

    let reader: AVAssetReader?
    let lanes: [Lane]
    /// First frame read and end of the composition (frames).
    let start: Int, end: Int
    /// Readers alive in the process (leak check in tests).
    nonisolated(unsafe) static var live = 0
    private static let liveLock = NSLock()
    static var liveCount: Int { liveLock.withLock { live } }
    /// Readers alive for one owner (per-instance leak check: the process-wide count also sees other engines).
    final class ReaderCount: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var value: Int { lock.withLock { n } }
        func add(_ d: Int) { lock.withLock { n += d } }
    }
    private let owner: ReaderCount?

    private var interleaved = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 8192)
    private var capacity = 8192
    private var left = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
    private var right = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
    private let abl = AudioBufferList.allocate(maximumBuffers: 2)
    private var cancelled = false

    /// Opens a reader on `built` from absolute frame `start` (nil reader: no audio lane, past the end, or the reader
    /// failed: the mixer then delivers silence, so the clock still runs).
    init(built: BuiltComposition, state: AudioMixState, start: Int, counter: ReaderCount? = nil) {
        self.start = start
        owner = counter
        end = max(start, Self.frame(built.duration.cmTime))
        var lanes: [Lane] = []
        var reader: AVAssetReader?
        if !built.audioLanes.isEmpty, start < end, let r = try? AVAssetReader(asset: built.composition) {
            r.timeRange = CMTimeRange(start: CMTime(value: CMTimeValue(start), timescale: Int32(Self.sampleRate)),
                                      end: built.duration.cmTime)
            for (i, lane) in built.audioLanes.enumerated() {
                let o = AVAssetReaderAudioMixOutput(audioTracks: [lane.track], audioSettings: Self.pcmSettings)
                o.audioTimePitchAlgorithm = CompositionBuilder.laneTimePitch   // .spectral (never varispeed: export hangs)
                o.alwaysCopiesSampleData = false
                guard r.canAdd(o) else { continue }
                r.add(o)
                let p = LaneProcessor(clips: lane.clips, state: state, skip: lane.skip, gains: lane.gains, lane: i)
                p.prepare(sampleRate: Self.sampleRate, channels: 2, maxFrames: 8192)
                lanes.append(Lane(output: o, processor: p, start: start))
            }
            if !lanes.isEmpty, r.startReading() {
                reader = r
                Self.liveLock.withLock { Self.live += 1 }
                counter?.add(1)
            } else {
                if r.status == .failed { EngineLog.error("preview audio: reader failed: \(r.error.map { "\($0)" } ?? "?")") }
                lanes = []
            }
        }
        self.reader = reader
        self.lanes = lanes
    }

    deinit {
        cancel()
        interleaved.deallocate(); left.deallocate(); right.deallocate(); free(abl.unsafeMutablePointer)
    }

    /// Stops the reader (on the owning queue: no read can be in flight).
    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        if let reader {
            reader.cancelReading()
            Self.liveLock.withLock { Self.live -= 1 }
            owner?.add(-1)
        }
    }

    /// Reads (and processes) every lane until it covers `frame` or ends. Blocks in `copyNextSampleBuffer`.
    func fill(upTo frame: Int) {
        for lane in lanes { pull(lane, upTo: frame) }
    }

    private func pull(_ lane: Lane, upTo target: Int) {
        while !lane.done, lane.readEnd < target {
            guard !cancelled, let sb = lane.output.copyNextSampleBuffer() else { lane.done = true; break }
            let n = CMSampleBufferGetNumSamples(sb)
            guard n > 0, let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            if n > capacity {
                interleaved.deallocate(); left.deallocate(); right.deallocate()
                capacity = n
                interleaved = .allocate(capacity: 2 * n); left = .allocate(capacity: n); right = .allocate(capacity: n)
            }
            let bytes = min(CMBlockBufferGetDataLength(bb), 2 * n * MemoryLayout<Float>.size)
            guard CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: bytes, destination: interleaved) == noErr else { continue }
            let frames = bytes / (2 * MemoryLayout<Float>.size)
            for i in 0..<frames { left[i] = interleaved[2 * i]; right[i] = interleaved[2 * i + 1] }
            abl[0] = CoreAudioTypes.AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: left)
            abl[1] = CoreAudioTypes.AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: right)
            // the lane processing (gains, fades, live chains, clip routing) on samples labelled by their own PTS
            lane.processor.process(abl, frames: frames, time: pts,
                                   duration: CMTime(value: CMTimeValue(frames), timescale: Int32(Self.sampleRate)))
            let at = Self.frame(pts)
            lane.segments.append(Segment(start: at, left: Array(UnsafeBufferPointer(start: left, count: frames)),
                                         right: Array(UnsafeBufferPointer(start: right, count: frames))))
            lane.readEnd = max(lane.readEnd, at + frames)
        }
    }

    /// Sums the lanes over absolute frames [from, from + count) into `out` (interleaved stereo, zeroed first), then
    /// drops what lies before the chunk's end. Frames a lane did not deliver are silence.
    func mix(from: Int, count: Int, into out: UnsafeMutablePointer<Float>) {
        out.update(repeating: 0, count: 2 * count)
        let to = from + count
        fill(upTo: to)
        for lane in lanes {
            for s in lane.segments where s.end > from && s.start < to {
                let a = max(s.start, from), b = min(s.end, to)
                s.left.withUnsafeBufferPointer { l in
                    s.right.withUnsafeBufferPointer { r in
                        for f in a..<b {
                            let o = 2 * (f - from), i = f - s.start
                            out[o] += l[i]; out[o + 1] += r[i]
                        }
                    }
                }
            }
            lane.segments.removeAll { $0.end <= to }
        }
    }
}
