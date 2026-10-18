@preconcurrency import AVFoundation
import Foundation
import MontageCore
import MontageEngine

/// Headless playback measurement: plays a PlaybackEngine for `seconds` and counts distinct frames delivered by its
/// video output (what the player view would present). Used by playback tests and the perf smoke test.
@MainActor
public enum PlaybackProbe {
    public struct Result: Sendable { public let frames: Int; public let seconds: Double; public var fps: Double { Double(frames) / seconds } }

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
        engine.pause()
        return Result(frames: frames, seconds: elapsed)
    }
}
