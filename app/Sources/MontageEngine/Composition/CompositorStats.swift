import Foundation
@preconcurrency import Metal

/// Load-independent cost accounting of composed frames (perf harness, playback tests): per frame, the encoding
/// thread's CPU time (`CLOCK_THREAD_CPUTIME_ID`, excludes preemption) plus the command buffer's GPU time. Wall-clock
/// delivery depends on how busy the machine is (parallel builds); this measures what a frame actually costs.
public final class CompositorStats: @unchecked Sendable {
    public static let shared = CompositorStats()
    public struct Snapshot: Sendable {
        /// Frames composed since the last `reset()` (including render-cache hits).
        public let frames: Int
        /// Per-frame cost in ms (CPU encode + GPU), most recent last (bounded ring).
        public let costsMs: [Double]
        public let cpuMs: [Double]
        public let gpuMs: [Double]
    }
    private let lock = NSLock()
    private var frames = 0
    private var cpu: [Double] = [], gpu: [Double] = []
    private let capacity = 4096

    public func reset() { lock.withLock { frames = 0; cpu.removeAll(); gpu.removeAll() } }

    public func snapshot() -> Snapshot {
        lock.withLock { Snapshot(frames: frames, costsMs: zip(cpu, gpu).map { $0 + $1 }, cpuMs: cpu, gpuMs: gpu) }
    }

    /// Thread CPU clock (ns) to pass back to `record`.
    @inline(__always) public static func threadClock() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

    /// Call from the command buffer's completed handler; `cpuNs` = encoding thread CPU time.
    func record(cpuNs: UInt64, commandBuffer cb: MTLCommandBuffer) {
        let g = max(0, (cb.gpuEndTime - cb.gpuStartTime) * 1000)
        let c = Double(cpuNs) / 1e6
        lock.withLock {
            frames += 1
            if cpu.count >= capacity { cpu.removeFirst(capacity / 2); gpu.removeFirst(capacity / 2) }
            cpu.append(c); gpu.append(g)
        }
    }
}
