@preconcurrency import AVFoundation
import Foundation

/// Preview audio without AVPlayer (BUG-CUT-AUDIO-HOLE, owner decision 2026-11-09; phase B: `PlaybackEngine`'s audio and
/// clock, the player renders the video only). AVFoundation on macOS 26 mislabels post-effects tap stamps by the time-pitch unit's
/// latency (macOS 13 is exact: docs/investigations/BUG-METALLIC-AUDIO.md part 5), so preview audio no longer goes
/// through AVPlayer and taps:
///   AVAssetReader (one `AVAssetReaderAudioMixOutput` per composition audio lane, exact PTS on every OS)
///   → `LaneProcessor` per lane at ENQUEUE time on PTS-labelled samples (`PreviewAudioLanes`)
///   → mixed stereo chunks → `AVSampleBufferAudioRenderer` (spectral time-pitch for J/K/L rates)
///   under an `AVSampleBufferRenderSynchronizer`, whose `timebase` is the preview clock (the engine starts the video's
///   timebase, on the same device clock, with the same (time, host time) pair: `start(rate:time:atHostTime:)`).
/// The feeder runs on a private serial queue, paced `feedAhead` of the clock: max(`ahead` (150 ms), output latency +
/// `feedMargin` (200 ms)), about 0.2 s on wired / built-in outputs and 0.37 s on AirPods (BUG-AIRPODS-SILENT: a
/// horizon shorter than the output latency leaves the output silent, no error). A live-effect edit is heard after at
/// most that much (plus one chunk). Nothing runs on the main thread; every public call only takes a lock, sets the
/// synchronizer and dispatches to the queue.
///
/// Transport: `seek` stops the clock at the target at once (the video can follow `timebase` right away), flushes the
/// renderer and opens a new reader there; the clock (re)starts once `prime` of audio is enqueued (or at the requested
/// host time if later). `pause` / `play` keep what is enqueued (no flush: continuous). `replace` swaps the composition
/// while playing without a gap: the new reader continues where the queue ends (edit heard after ≤ `feedAhead` + a chunk).
/// Rates ≤ 0 (reverse shuttle) pause the audio: reverse stays silent, as with AVPlayer today.
public final class PreviewAudio: @unchecked Sendable {
    public static let sampleRate = PreviewAudioLanes.sampleRate
    /// Frames per enqueued chunk (21 ms at 48 kHz).
    static let chunkFrames = 1024

    /// The clock: phase B drives the video from `synchronizer.timebase`.
    public let synchronizer = AVSampleBufferRenderSynchronizer()
    public var timebase: CMTimebase { synchronizer.timebase }
    public let audioState: AudioMixState
    /// Minimum media seconds kept enqueued past the clock while playing (× the rate when > 1), and before a start; the
    /// feeder uses `feedAhead`, which also covers the output latency.
    public let ahead: Double
    public let prime: Double
    let renderer = AVSampleBufferAudioRenderer()
    private let queue = DispatchQueue(label: "valse.preview-audio", qos: .userInteractive)

    // MARK: caller-side state (lock)
    private let lock = NSLock()
    private var wantsRate: Double = 0
    private var startHostTime: CMTime?
    private var pendingSeek: Double?
    private var pendingBuilt: BuiltComposition?
    private var generation = 0
    private var _capture: Capture?
    private var _stats = Stats()
    /// `whenPrimed` callbacks waiting for the queue to hold `prime` of audio past the clock.
    private var primedHandlers: [@Sendable () -> Void] = []
    private var _onReanchor: (@Sendable () -> Void)?

    // MARK: queue-confined state
    private var built: BuiltComposition?
    private var lanes: PreviewAudioLanes?
    private let readerCounter = PreviewAudioLanes.ReaderCount()
    /// Absolute frame of the next chunk to enqueue.
    private var cursor = 0
    private var endFrame = 0
    private var timer: DispatchSourceTimer?
    private var format: CMAudioFormatDescription?
    private let chunk = UnsafeMutablePointer<Float>.allocate(capacity: 2 * PreviewAudio.chunkFrames)
    private var observer: NSObjectProtocol?

    /// Test / diagnostics hook: every chunk handed to the renderer (composition time of its first frame, interleaved
    /// stereo samples). Called on the feeder queue: copy and return.
    public typealias Capture = @Sendable (_ time: Double, _ interleaved: UnsafeBufferPointer<Float>) -> Void
    public var capture: Capture? {
        get { lock.withLock { _capture } }
        set { lock.withLock { _capture = newValue } }
    }

    public struct Stats: Sendable {
        /// Seeks performed on the queue (coalesced seeks count once), hot swaps.
        public var seeks = 0, swaps = 0
        /// Composition time enqueued up to (s).
        public var enqueuedEnd = 0.0
        /// Host time (CACurrentMediaTime) of the last seek request, of its first enqueued chunk, of the clock start.
        public var seekRequested = 0.0, firstChunkAfterSeek = 0.0, clockStarted = 0.0
        public var outputChanges = 0
        /// Last hot swap, as the feeder performed it: the clock (frame) when it ran, the frame the new composition starts
        /// at (the queue's end), and the host time (CACurrentMediaTime) it ran at.
        public var swapClockFrame = 0, swapFrame = 0
        public var swapRan = 0.0
    }
    public var stats: Stats { lock.withLock { _stats } }

    /// `outputDeviceUID`: nil = the system default output.
    public init(audioState: AudioMixState, outputDeviceUID: String? = nil, ahead: Double = 0.15, prime: Double = 0.1) {
        self.audioState = audioState
        self.ahead = ahead
        self.prime = prime
        renderer.audioTimePitchAlgorithm = .spectral
        renderer.volume = AudioOutput.volume(1)
        if let outputDeviceUID { renderer.audioOutputDeviceUniqueID = outputDeviceUID }
        refreshOutputLatency()
        synchronizer.addRenderer(renderer)
        synchronizer.setRate(0, time: .zero)
        observer = NotificationCenter.default.addObserver(forName: .AVSampleBufferAudioRendererOutputConfigurationDidChange,
                                                          object: renderer, queue: nil) { [weak self] _ in
            self?.outputConfigurationChanged()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        timer?.cancel()
        lanes?.cancel()   // (no queue block holds self: no read in flight)
        chunk.deallocate()
    }

    // MARK: - Public transport (any thread; never blocks on the feeder)

    /// Clock time (composition seconds).
    public var currentTime: Double { synchronizer.currentTime().seconds }
    /// Requested rate (0 = paused).
    public var rate: Double { lock.withLock { wantsRate } }
    public var volume: Float {
        get { renderer.volume }
        set { renderer.volume = AudioOutput.volume(newValue) }
    }
    public var isMuted: Bool {
        get { renderer.isMuted }
        set { renderer.isMuted = newValue }
    }
    /// The clock is running (rate ≠ 0, or scheduled to start at a host time).
    public var isRunning: Bool { synchronizer.rate != 0 }

    /// Slaved mode (`PlaybackEngine`): when set, an output change or a failed renderer only stops the clock and calls
    /// this (any thread) instead of re-seeking and restarting on its own, so that the owner can restart the audio AND
    /// its video together (`seek` + `start`). nil = re-anchor alone (standalone use, `PreviewAudioCheck`).
    public var onReanchor: (@Sendable () -> Void)? {
        get { lock.withLock { _onReanchor } }
        set { lock.withLock { _onReanchor = newValue } }
    }
    public var outputDeviceUID: String? {
        get { renderer.audioOutputDeviceUniqueID }
        set {
            renderer.audioOutputDeviceUniqueID = newValue   // posts OutputConfigurationDidChange → re-anchor
            refreshOutputLatency()
        }
    }

    // MARK: Output latency (BUG-AIRPODS-SILENT)

    /// Shortest lead of a scheduled clock start, and the margin kept past the output latency.
    public static let minStartLead = 0.012
    public static let latencyMargin = 0.025
    /// Host-time lead a scheduled start (`setRate(_:time:atHostTime:)`) needs on an output with `outputLatency`:
    /// a start scheduled closer than the output latency drops the first samples (AirPods, latency ≈ 171 ms: a 12 ms lead
    /// lost 0.26-0.9 s of the first 2 s, a 196 ms lead ~0.07 s). Steady silence comes from a short enqueue horizon
    /// instead (`feedAhead`).
    public static func startLead(outputLatency: Double) -> Double {
        max(minStartLead, outputLatency + latencyMargin)
    }
    /// Margin the enqueue horizon keeps past the output latency (measured on AirPods, latency 0.171 s: a horizon of
    /// 0.15 s left 85-100 % of the IO cycles silent, 0.25 s 0-1 %, 0.40 s none).
    public static let feedMargin = 0.2
    /// Media seconds (at 1×) the feeder keeps enqueued past the clock: the renderer needs each sample about one output
    /// latency before the clock reaches it and silently drops the late ones, so the horizon must exceed the latency.
    public static func feedAhead(_ ahead: Double, outputLatency: Double) -> Double {
        max(ahead, outputLatency + feedMargin)
    }
    /// The enqueue horizon on the current output (`feedAhead(ahead, outputLatency:)`).
    public var feedAhead: Double { Self.feedAhead(ahead, outputLatency: outputLatency) }
    /// Total output latency (s) of the current output (cached; refreshed on a device / configuration change).
    public var outputLatency: Double { lock.withLock { _outputLatency } }
    /// Lead to schedule a start with on the current output (`startLead(outputLatency:)`).
    public var startLead: Double { Self.startLead(outputLatency: outputLatency) }
    /// Reads the output latency of a device UID (nil = system default). Tests inject a fixed value; setting it refreshes.
    public var latencyProvider: @Sendable (String?) -> Double? {
        get { lock.withLock { _latencyProvider } }
        set { lock.withLock { _latencyProvider = newValue }; refreshOutputLatency() }
    }
    private var _latencyProvider: @Sendable (String?) -> Double? = { AudioDevices.outputLatency(uid: $0) }
    private var _outputLatency: Double = 0

    /// Re-reads the output latency (CoreAudio; any thread).
    public func refreshOutputLatency() {
        let provider = lock.withLock { _latencyProvider }
        let latency = max(0, provider(renderer.audioOutputDeviceUniqueID) ?? 0)
        lock.withLock { _outputLatency = latency }
    }

    /// Installs `built` and seeks to `time` (first load, or a rebuild when a gap is fine).
    public func load(_ built: BuiltComposition, at time: Double) {
        lock.withLock { pendingBuilt = built }
        seek(to: time)
    }

    /// Edit while playing: swaps in `built` without a gap (paused: re-reads at the clock).
    public func replace(_ built: BuiltComposition) {
        lock.withLock { pendingBuilt = built }
        queue.async { self.drain() }
    }

    /// Stops the clock at `time` now; the audio (and the clock, if playing) restart from there once primed.
    /// Coalesces: a seek storm opens one reader per queue turn, for the latest target.
    public func seek(to time: Double) {
        lock.withLock {
            pendingSeek = max(0, time)
            generation &+= 1
            _stats.seekRequested = CACurrentMediaTime()
            synchronizer.setRate(0, time: CMTime(seconds: max(0, time), preferredTimescale: Int32(Self.sampleRate)))
        }
        queue.async { self.drain() }
    }

    /// Plays at `rate` (> 0) from the clock's time; starts at `hostTime` when given and the audio is primed by then
    /// (else as soon as it is). `rate` ≤ 0 pauses (reverse is silent).
    public func play(rate: Double = 1, atHostTime hostTime: CMTime? = nil) {
        guard rate > 0 else { pause(); return }
        lock.withLock { wantsRate = rate; startHostTime = hostTime }
        queue.async { self.ensureTimer(); self.tick() }
    }

    /// Slaved start (`PlaybackEngine`): the clock reads `time` at `hostTime` and runs at `rate` from there, whether the
    /// audio is primed or not (call it from `whenPrimed`), so that a video timebase started with the same pair stays in
    /// step. A host time already past is honoured too (the clock is then already ahead by the difference, like the video).
    public func start(rate: Double, time: Double, atHostTime hostTime: CMTime) {
        guard rate > 0 else { pause(); return }
        lock.withLock {
            wantsRate = rate; startHostTime = nil
            synchronizer.setRate(Float(rate), time: CMTime(seconds: max(0, time), preferredTimescale: Int32(Self.sampleRate)),
                                 atHostTime: hostTime)
            _stats.clockStarted = CACurrentMediaTime()
        }
        queue.async { self.ensureTimer(); self.tick() }
    }

    /// Calls `handler` (on the feeder queue) once `prime` of audio past the clock is enqueued for the latest seek (or
    /// nothing is left to enqueue): right away when it already is.
    public func whenPrimed(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { primedHandlers.append(handler) }
        queue.async { self.ensureTimer(); self.tick() }
    }

    public func pause() {
        lock.withLock {
            wantsRate = 0; startHostTime = nil
            synchronizer.rate = 0
        }
    }

    /// J/K/L: changes the rate of a running clock (the renderer time-stretches, spectral); starts it if paused.
    public func setRate(_ rate: Double) {
        guard rate > 0 else { pause(); return }
        let running: Bool = lock.withLock {
            wantsRate = rate
            guard synchronizer.rate != 0 else { return false }
            synchronizer.rate = Float(rate)
            return true
        }
        if !running { play(rate: rate) }
    }

    /// Output device / route / format change (AVSampleBufferAudioRendererOutputConfigurationDidChange, or called by
    /// the owner on a default-device change): Apple's rule is flush and re-enqueue from the current time.
    public func outputConfigurationChanged() {
        refreshOutputLatency()   // the default output may have changed (AirPods connected): before the re-anchor
        let handler: (@Sendable () -> Void)? = lock.withLock {
            _stats.outputChanges += 1
            guard let h = _onReanchor else { return nil }
            wantsRate = 0; startHostTime = nil
            synchronizer.rate = 0
            return h
        }
        if let handler { handler() } else { seek(to: currentTime) }
    }

    /// Stops everything (clock, feeder, reader). The instance can be reused with `load`.
    public func stop() {
        pause()
        lock.withLock { generation &+= 1; pendingSeek = nil }
        queue.async {
            self.timer?.cancel(); self.timer = nil
            self.lanes?.cancel(); self.lanes = nil
            self.renderer.flush()
        }
    }

    /// Readers currently open in the process (tests: leaks after seek storms).
    public static var openReaders: Int { PreviewAudioLanes.liveCount }
    /// Readers currently open for this instance only. Read from another thread while the feeder works, this can be 2
    /// for a moment by design: a hot swap (`replace`) opens the new reader and decodes its first chunk before it drops
    /// the old one (gapless). A leak check reads `settledOpenReaderCount()` instead.
    public var openReaderCount: Int { readerCounter.value }
    /// Readers open for this instance between two feeder operations (after everything requested so far has run on the
    /// feeder queue): a seek or a swap never leaves more than one reader open, whatever the load (FLAKY-PB).
    public func settledOpenReaderCount() async -> Int {
        await withCheckedContinuation { (k: CheckedContinuation<Int, Never>) in
            queue.async { k.resume(returning: self.readerCounter.value) }
        }
    }

    // MARK: - Queue

    private func drain() {
        let (built, seek, gen) = lock.withLock { () -> (BuiltComposition?, Double?, Int) in
            defer { pendingBuilt = nil; pendingSeek = nil }
            return (pendingBuilt, pendingSeek, generation)
        }
        if let built { self.built = built; endFrame = PreviewAudioLanes.frame(built.duration.cmTime) }
        if let seek {
            performSeek(seek, generation: gen)
        } else if built != nil {
            swap(generation: gen)
        }
    }

    private func clockFrame() -> Int { PreviewAudioLanes.frame(synchronizer.currentTime()) }

    private func performSeek(_ time: Double, generation gen: Int) {
        renderer.flush()
        lanes?.cancel(); lanes = nil
        let f = PreviewAudioLanes.frame(time)
        cursor = f
        if let built { lanes = PreviewAudioLanes(built: built, state: audioState, start: f, counter: readerCounter) }
        lock.withLock { _stats.seeks += 1; _stats.firstChunkAfterSeek = 0; _stats.enqueuedEnd = time }
        ensureTimer()
        tick()
    }

    /// Hot swap of the composition while playing: the new reader continues exactly where the queue ends (no flush,
    /// no gap); the edit is heard once the queued audio (`feedAhead`, + one chunk) has played.
    /// (`renderer.flush(fromSourceTime:)` to drop the queued tail was tried: the renderer refused it even 80 ms ahead
    /// of the clock with 40 ms queued past that point — it has already consumed the paced queue.)
    private func swap(generation gen: Int) {
        guard let built else { return }
        guard synchronizer.rate != 0, lanes != nil else { performSeek(currentTime, generation: gen); return }
        let clock = clockFrame()
        let next = PreviewAudioLanes(built: built, state: audioState, start: cursor, counter: readerCounter)
        next.fill(upTo: cursor + Self.chunkFrames)   // first decode before dropping the old reader
        lanes?.cancel()
        lanes = next
        lock.withLock {
            _stats.swaps += 1
            _stats.swapClockFrame = clock; _stats.swapFrame = cursor; _stats.swapRan = CACurrentMediaTime()
        }
        ensureTimer(); tick()
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// Feeds the renderer up to the pacing limit, starts the clock when primed, idles the timer when nothing is left.
    private func tick() {
        if renderer.status == .failed {
            EngineLog.error("preview audio: renderer failed (\(renderer.error.map { "\($0)" } ?? "?")): re-anchoring")
            renderer.flush()
            refreshOutputLatency()
            if let handler = lock.withLock({ () -> (@Sendable () -> Void)? in
                guard let h = _onReanchor else { return nil }
                wantsRate = 0; startHostTime = nil; synchronizer.rate = 0
                return h
            }) {
                // slaved: the owner re-seeks (audio and video together); keep the timer off until then
                timer?.cancel(); timer = nil
                handler()
                return
            }
            lock.withLock { pendingSeek = currentTime; generation &+= 1 }
            drain()
            return
        }
        // a seek / swap requested since: perform it first (a tick before its `drain` would feed — and report primed —
        // from the old position)
        if lock.withLock({ pendingSeek != nil || pendingBuilt != nil }) { drain() }
        let (rate, gen, latency) = lock.withLock { (wantsRate, generation, _outputLatency) }
        // the horizon must exceed the output latency, else every sample reaches the renderer late: silence, no error
        let horizon = Self.feedAhead(ahead, outputLatency: latency)
        let limit = Int((rate > 0 ? horizon * max(1, rate) : max(horizon, prime)) * Self.sampleRate)
        var clock = clockFrame()
        while cursor < endFrame, cursor - clock < limit, renderer.isReadyForMoreMediaData {
            let n = min(Self.chunkFrames, endFrame - cursor)
            if let lanes { lanes.mix(from: cursor, count: n, into: chunk) } else { chunk.update(repeating: 0, count: 2 * n) }
            guard lock.withLock({ generation }) == gen else { return }   // a seek came in during the read: drop
            if let sb = makeSampleBuffer(frames: n, at: cursor) { renderer.enqueue(sb) }
            capture?(Double(cursor) / Self.sampleRate, UnsafeBufferPointer(start: chunk, count: 2 * n))
            cursor += n
            lock.withLock {
                _stats.enqueuedEnd = Double(cursor) / Self.sampleRate
                if _stats.firstChunkAfterSeek == 0 { _stats.firstChunkAfterSeek = CACurrentMediaTime() }
            }
            clock = clockFrame()
        }
        // start the clock once primed (or nothing more to enqueue)
        let primed = cursor - clock >= Int(prime * Self.sampleRate) || cursor >= endFrame
        if primed {
            lock.withLock {
                guard generation == gen, wantsRate > 0, synchronizer.rate == 0 else { return }
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                if let h = startHostTime, CMTimeCompare(h, now) > 0 {
                    // never closer than the output latency (silent renderer otherwise): start a little later instead
                    let earliest = now + CMTime(seconds: Self.startLead(outputLatency: _outputLatency), preferredTimescale: 1_000_000)
                    synchronizer.setRate(Float(wantsRate), time: synchronizer.currentTime(), atHostTime: CMTimeMaximum(h, earliest))
                } else {
                    synchronizer.rate = Float(wantsRate)
                }
                startHostTime = nil
                _stats.clockStarted = CACurrentMediaTime()
            }
            let handlers: [@Sendable () -> Void] = lock.withLock {
                guard generation == gen else { return [] }
                defer { primedHandlers = [] }
                return primedHandlers
            }
            for h in handlers { h() }
        }
        // idle: paused and primed, or everything enqueued
        if (rate == 0 && primed) || cursor >= endFrame { timer?.cancel(); timer = nil }
    }

    private func makeSampleBuffer(frames n: Int, at frame: Int) -> CMSampleBuffer? {
        if format == nil {
            var asbd = AudioStreamBasicDescription(mSampleRate: Self.sampleRate, mFormatID: kAudioFormatLinearPCM,
                                                   mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                   mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                                   mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                           magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        }
        guard let format else { return nil }
        let bytes = n * 8
        var bb: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &bb) == noErr,
              let bb, CMBlockBufferReplaceDataBytes(with: chunk, blockBuffer: bb, offsetIntoDestination: 0, dataLength: bytes) == noErr
        else { return nil }
        var sb: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: bb, formatDescription: format, sampleCount: n,
            presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: Int32(Self.sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }
}
