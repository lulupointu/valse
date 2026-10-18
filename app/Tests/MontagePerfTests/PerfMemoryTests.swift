import Testing
import Foundation
import Darwin
@preconcurrency import Metal
import MontageCore
import MontageEngine
import MontageTestSupport

/// Engine memory of a typical 1080p edit (perf round 2 target: < 1 GB peak). Opt-in like the other perf suites
/// (MONTAGE_PERF=1, bench/media). scripts/perf.sh runs it in its OWN test process: the metric is the process's lifetime
/// peak physical footprint, so nothing else (4K smoke tests, export of other projects) may run before it.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MONTAGE_PERF"] == "1"))
struct PerfMemoryTests {
    static let media = TestMedia.repoRoot().appendingPathComponent("bench/media")

    func emit(_ metric: String, _ value: Double, _ unit: String) {
        print("{\"stack\":\"montage\",\"metric\":\"\(metric)\",\"value\":\((value * 100).rounded() / 100),\"unit\":\"\(unit)\"}")
    }

    static func footprint() -> (now: Double, peak: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
    }

    /// Phase breakdown on stdout (not a metric): footprint, Metal allocations, idle pooled textures.
    func diag(_ phase: String) {
        let f = Self.footprint()
        let gpu = Double(MetalContext.shared.device.currentAllocatedSize) / 1_048_576
        let pool = Double(MetalContext.shared.pool.idleBytes) / 1_048_576
        print(String(format: "MEMDIAG %@ footprint %.0f peak %.0f metal %.0f poolIdle %.0f", phase, f.now, f.peak, gpu, pool))
    }

    /// 18 s of 1080p footage in three cuts with a dissolve, a picture-in-picture, blur + filter, a vignette adjustment
    /// layer, an animated title, 12 karaoke captions and a voice track.
    func typicalProject() async throws -> TestProject {
        var p = TestProject(canvas: Size2(1920, 1080))
        let v = Self.media.appendingPathComponent("h264_1080.mp4")
        try #require(FileManager.default.fileExists(atPath: v.path), "run bench/make_media.sh first")
        var main: [ClipID] = []
        for i in 0..<3 { main.append(try await p.addMedia(v, at: Time(Double(i) * 6), duration: Time(6))) }
        p[main[0]].effects = [EffectInstance(typeID: "montage.effect.blur"), EffectInstance(typeID: "montage.filter.warm")]
        try TimelineOps.setTransition(main[0], TransitionInstance(typeID: "montage.transition.dissolve", duration: Time(1)), in: &p.project.timeline)
        let pip = try await p.addMedia(v, at: Time(2), target: .newTrack, duration: Time(8))
        p[pip].transform.scale = Vec2(0.35, 0.35)
        p[pip].transform.position = Vec2(0.3, -0.3)
        try p.addAdjustment([EffectInstance(typeID: "montage.effect.vignette")], at: .zero, duration: Time(18))
        let title = try p.addText("Montage — memory audit", at: Time(0.5), duration: Time(5))
        p[title].animations.inAnim = AnimationInstance(typeID: "montage.anim.in.fade")
        CaptionOps.addCaptionTrack((0..<12).map { i in
            CaptionSegment(text: "Caption \(i) for the memory audit", start: Double(i) * 1.5, end: Double(i) * 1.5 + 1.4)
        }, to: &p.project)
        _ = try await p.addMedia(Self.media.appendingPathComponent("speech_fr.wav"), target: .newTrack, duration: Time(18))
        return p
    }

    /// Play, scrub, live edits while paused, then a 1080p export of the same project.
    @Test func typical1080pProjectMemory() async throws {
        var p = try await typicalProject()
        let engine = PlaybackEngine(project: p.project)
        try await PlaybackProbe.waitReady(engine)
        diag("ready")
        _ = try await PlaybackProbe.measure(engine, seconds: 5)
        engine.pause()
        diag("played")
        for i in 0..<30 {
            engine.seek(to: Time(Double((i * 7) % 17) + 0.3), exact: true)
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        let size = engine.renderSize
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width), height: Int(size.height), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
        let out = try #require(MetalContext.shared.device.makeTexture(descriptor: d))
        let id = p.mainClips[1]
        for i in 0..<30 {
            p[id].opacity = 0.5 + 0.5 * Double(i % 2)
            engine.update(project: p.project)
            guard let cmd = MetalContext.shared.queue.makeCommandBuffer() else { continue }
            _ = engine.renderCurrentFrame(into: out, commandBuffer: cmd)
            cmd.commit()
            await cmd.completed()
        }
        diag("edited")
        let afterEdit = Self.footprint()
        let watch = Task { @MainActor in
            while !Task.isCancelled { diag("export"); try? await Task.sleep(nanoseconds: 500_000_000) }
        }
        _ = try await exportProject(p.project, seconds: 10)
        watch.cancel()
        diag("exported")
        let end = Self.footprint()
        emit("engine_memory_1080p_edit_peak_mb", afterEdit.peak, "MB")
        emit("engine_memory_1080p_peak_mb", end.peak, "MB")
        emit("engine_memory_1080p_end_mb", end.now, "MB")
    }
}
