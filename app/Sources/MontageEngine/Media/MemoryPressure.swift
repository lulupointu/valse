import Foundation
import Dispatch
import MontageCore

/// System memory-pressure handling (8 GB Airs swap long before the app runs out of address space). On a warning the
/// engine shrinks its rebuildable GPU caches; on critical it drops them and every preview keeps only the frame it
/// shows. Back to normal restores the `MemoryBudget` sizes. Started by `PlaybackEngine`; `apply` is public so the
/// policy is testable without real pressure.
public final class MemoryPressure: @unchecked Sendable {
    public static let shared = MemoryPressure()
    public enum Level: Int, Sendable { case normal, warning, critical }

    /// Posted (any thread) after a level change was applied; `userInfo["level"]` = `Level.rawValue`.
    public static let didChange = Notification.Name("montage.memoryPressure")

    private let lock = NSLock()
    private var source: DispatchSourceMemoryPressure?
    private var _level: Level = .normal
    public var level: Level { lock.withLock { _level } }

    /// Starts listening (idempotent).
    public func start() {
        lock.withLock {
            guard source == nil else { return }
            let s = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
            s.setEventHandler { [weak self, weak s] in
                guard let e = s?.data else { return }
                self?.apply(e.contains(.critical) ? .critical : (e.contains(.warning) ? .warning : .normal))
            }
            s.resume()
            source = s
        }
    }

    public func apply(_ level: Level) {
        lock.withLock { _level = level }
        let ctx = MetalContext.shared
        let text = FrameRenderer.shared.text
        switch level {
        case .normal:
            ctx.pool.idleBudget = MemoryBudget.texturePoolIdleBytes
            text.setBudgetFraction(1)
            FrameRenderer.shared.images.byteBudget = MemoryBudget.imageCacheBytes
        case .warning:
            ctx.pool.idleBudget = MemoryBudget.texturePoolIdleBytes / 4
            text.setBudgetFraction(0.5)
            FrameRenderer.shared.images.byteBudget = MemoryBudget.imageCacheBytes / 2
            ctx.flushCVTextures()
        case .critical:
            ctx.pool.idleBudget = 0
            text.setBudgetFraction(0.25)
            FrameRenderer.shared.images.byteBudget = MemoryBudget.imageCacheBytes / 4
            ctx.flushCVTextures()
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil, userInfo: ["level": level.rawValue])
    }
}
