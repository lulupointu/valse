@preconcurrency import AVFoundation
import Foundation
import MontageCore
import MontageEngine

/// Headless playback measurement: plays a PlaybackEngine for `seconds` and counts distinct frames delivered by its
/// video output (what the player view would present). Used by playback tests and the perf smoke test.
@MainActor
public enum PlaybackProbe {
    public struct Result: Sendable {
        /// Distinct frames seen by polling the video output (wall-clock delivery; sensitive to main-thread starvation).
        public let frames: Int
        public let seconds: Double
        public var fps: Double { Double(frames) / seconds }
        /// Item (media) time the player advanced during the measurement.
        public var itemSeconds: Double = 0
        /// Frames the compositor composed, and their per-frame cost (thread CPU + GPU, ms) — load-independent.
        public var composed: Int = 0
        public var composeCostP95Ms: Double = 0
        /// Composed frames per second of advanced item time (≈ source fps when the compositor keeps up).
        public var composedFPS: Double { itemSeconds > 0 ? Double(composed) / itemSeconds : 0 }
        /// Max fps the compositor could sustain at its p95 frame cost (with 3 frames in flight it overlaps CPU and GPU,
        /// so this is pessimistic).
        public var sustainableFPS: Double { composeCostP95Ms > 0 ? 1000 / composeCostP95Ms : .infinity }
    }

    /// 1-minute load average per CPU core (> 1 = the machine is oversubscribed, wall-clock checks are unreliable).
    public static func loadPerCore() -> Double {
        var l = [Double](repeating: 0, count: 3)
        guard getloadavg(&l, 3) > 0 else { return 0 }
        return l[0] / Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
    }

    /// Waits until the engine has a ready player item.
    public static func waitReady(_ engine: PlaybackEngine, timeout: Double = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while engine.player.currentItem?.status != .readyToPlay {
            if Date() > deadline { throw NSError(domain: "Montage", code: 90, userInfo: [NSLocalizedDescriptionKey: "player not ready"]) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    public static func measure(_ engine: PlaybackEngine, seconds: Double) async throws -> Result {
        try await waitReady(engine)
        engine.seek(to: .zero)
        try await Task.sleep(nanoseconds: 200_000_000)
        CompositorStats.shared.reset()
        let item0 = engine.player.currentTime().seconds
        engine.play()
        let start = CACurrentMediaTime()
        var frames = 0
        var last = CMTime.invalid
        while CACurrentMediaTime() - start < seconds {
            if let out = engine.videoOutput {
                let t = out.itemTime(forHostTime: CACurrentMediaTime())
                if out.hasNewPixelBuffer(forItemTime: t) {
                    var shown = CMTime.invalid
                    if out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &shown) != nil, shown != last { frames += 1; last = shown }
                }
            }
            try await Task.sleep(nanoseconds: 4_000_000)
        }
        let elapsed = CACurrentMediaTime() - start
        let item1 = engine.player.currentTime().seconds
        engine.pause()
        let stats = CompositorStats.shared.snapshot()
        let sorted = stats.costsMs.sorted()
        var r = Result(frames: frames, seconds: elapsed)
        r.itemSeconds = max(0, item1 - item0)
        r.composed = stats.frames
        r.composeCostP95Ms = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
        return r
    }
}
