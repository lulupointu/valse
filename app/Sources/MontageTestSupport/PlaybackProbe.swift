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

    /// Waits until the engine has a ready player item. A failed build / item fails at once, with its error (before, a
    /// failed item looked like a slow one for the whole timeout).
    /// `timeout` is a hang bound in time the process could actually work, counted from the last PROGRESS — not wall
    /// time: the build and the item's readiness need the main actor (shared by every @MainActor test of the parallel
    /// suite) and queue behind other tests' builds (`CompositionBuilder.buildLock`). A poll iteration that came back
    /// late (the main actor was busy elsewhere) counts as one nominal tick; a finished build anywhere in the process
    /// or the item being installed restarts the bound. RealLikeFootageTests "player not ready" hit the old 30 s wall
    /// bound in a loaded gate run (the same test then took ~60 s for its HLG case, 3 s alone). `ceiling` (wall) ends
    /// a wait that never gets anywhere.
    public static func waitReady(_ engine: PlaybackEngine, timeout: Double = 60, ceiling: Double = 600) async throws {
        let t0 = Date()
        var worked = 0.0, lastTick = t0
        var last = (CompositionBuilder.finishedBuilds, engine.player.currentItem != nil)
        func fail(_ why: String) -> NSError {
            let item = engine.player.currentItem.map { "item status \($0.status.rawValue)" } ?? "no item"
            return NSError(domain: "Montage", code: 90, userInfo: [NSLocalizedDescriptionKey:
                "player not ready: \(why) (\(item), building \(engine.isBuilding), waited \(Int(Date().timeIntervalSince(t0))) s, "
                + "\(CompositionBuilder.finishedBuilds) builds finished in this process)"])
        }
        while engine.player.currentItem?.status != .readyToPlay {
            if let item = engine.player.currentItem, item.status == .failed { throw fail("item failed: \(item.error.map { "\($0)" } ?? "?")") }
            if let e = engine.lastBuildError, !engine.isBuilding { throw fail("composition build failed: \(e)") }
            let now = Date(), cur = (CompositionBuilder.finishedBuilds, engine.player.currentItem != nil)
            worked += min(now.timeIntervalSince(lastTick), 0.05); lastTick = now   // a late wake-up = starved, not working
            if cur != last { last = cur; worked = 0 }
            if worked > timeout { throw fail("no progress for \(Int(timeout)) s of available time") }
            if now.timeIntervalSince(t0) > ceiling { throw fail("still queued after \(Int(ceiling)) s") }
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
