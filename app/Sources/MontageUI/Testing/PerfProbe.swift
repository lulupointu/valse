import Foundation
import Darwin
@preconcurrency import Metal
import MontageCore
import MontageEngine

/// Process memory + timeline frame timing for the perf harness (scripts/perf.sh, `perf` / `metric` UI test steps).
nonisolated public enum ProcessMemory {
    /// (current, lifetime peak) physical footprint in bytes — the number Activity Monitor's "Memory" column shows.
    public static func footprint() -> (current: UInt64, peak: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        return (info.phys_footprint, UInt64(info.ledger_phys_footprint_peak))
    }
}

nonisolated public struct Percentiles: Sendable {
    public let p50: Double, p95: Double, max: Double, mean: Double
    public init(_ xs: [Double]) {
        let s = xs.sorted()
        func q(_ f: Double) -> Double { s.isEmpty ? 0 : s[min(s.count - 1, Int((Double(s.count - 1) * f).rounded()))] }
        p50 = q(0.5); p95 = q(0.95); max = s.last ?? 0; mean = s.isEmpty ? 0 : s.reduce(0, +) / Double(s.count)
    }
}

/// Measures one timeline frame the way `TimelineView.draw` does it (build the Canvas2D on the CPU, encode on the GPU),
/// into an offscreen texture so it works in an occluded/offscreen window.
@MainActor
final class TimelineFrameProbe {
    private let renderer = Canvas2DRenderer()
    private var target: MTLTexture?

    /// (cpu ms, gpu ms)
    func measure(_ view: TimelineView) -> (Double, Double) {
        let s = view.window?.backingScaleFactor ?? 2
        let w = max(1, Int(view.bounds.width * s)), h = max(1, Int(view.bounds.height * s))
        if target?.width != w || target?.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            target = MetalContext.shared.device.makeTexture(descriptor: d)
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let canvas = view.buildCanvas()
        guard let target, let cmd = MetalContext.shared.queue.makeCommandBuffer() else { return (0, 0) }
        renderer.encode(canvas, into: target, scale: s, clear: RGBA(hex: 0x1B1B1C), commandBuffer: cmd)
        cmd.commit()
        let cpu = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        cmd.waitUntilCompleted()  // tests only (ARCHITECTURE §13 exception)
        let gpu = max(0, (cmd.gpuEndTime - cmd.gpuStartTime) * 1000)
        return (cpu, gpu)
    }
}
