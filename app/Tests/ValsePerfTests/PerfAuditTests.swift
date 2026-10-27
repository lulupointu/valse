import Testing
import Foundation
import Darwin
@preconcurrency import AVFoundation
@preconcurrency import Metal
import ValseCore
import ValseEngine
import ValseTestSupport

/// W14 Air audit (opt-in like PerfSmokeTests: VALSE_PERF=1, bench/media). Every number is emitted as a JSON line
/// that scripts/perf.sh picks up and checks against bench/perf_thresholds.json. Frame costs come from
/// `CompositorStats` (thread CPU + GPU per composed frame), so they hold up when other processes load the machine.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["VALSE_PERF"] == "1"))
struct PerfAuditTests {
    static let media = TestMedia.repoRoot().appendingPathComponent("bench/media")

    func emit(_ metric: String, _ value: Double, _ unit: String) {
        print("{\"stack\":\"valse\",\"metric\":\"\(metric)\",\"value\":\((value * 100).rounded() / 100),\"unit\":\"\(unit)\"}")
    }

    static func p95(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count - 1) * 0.95))]
    }

    /// A typical edit: two 4K clips with a dissolve, blur + filter on the first, vignette adjustment layer, an animated
    /// title and a picture-in-picture overlay.
    func complexProject(canvas: Size2) async throws -> TestProject {
        var p = TestProject(canvas: canvas)
        let a = Self.media.appendingPathComponent("a.mp4"), b = Self.media.appendingPathComponent("b.mp4")
        try #require(FileManager.default.fileExists(atPath: a.path), "run bench/make_media.sh first")
        let c1 = try await p.addMedia(a, duration: Time(6))
        let c2 = try await p.addMedia(b, at: Time(6), duration: Time(6))
        p[c1].effects = [EffectInstance(typeID: "valse.effect.blur"), EffectInstance(typeID: "valse.filter.warm")]
        try TimelineOps.setTransition(c1, TransitionInstance(typeID: "valse.transition.dissolve", duration: Time(1)), in: &p.project.timeline)
        let pip = try await p.addMedia(Self.media.appendingPathComponent("c.mp4"), at: Time(1), target: .newTrack, duration: Time(10))
        p[pip].transform.scale = Vec2(0.35, 0.35)
        p[pip].transform.position = Vec2(0.3, -0.3)
        try p.addAdjustment([EffectInstance(typeID: "valse.effect.vignette")], at: .zero, duration: Time(12))
        let title = try p.addText("Valse — perf audit", at: Time(0.5), duration: Time(8))
        p[title].animations.inAnim = AnimationInstance(typeID: "valse.anim.in.fade")
        _ = c2
        return p
    }

    /// Plays `seconds` and reports composed fps (per advanced media second), dropped-frame % and compositor cost.
    func measurePlayback(_ name: String, _ p: TestProject, seconds: Double = 4, proxies: Bool) async throws {
        let engine = PlaybackEngine(project: p.project)
        if !proxies { engine.sourceChooser = PlaybackEngine.originalSources }
        engine.forceRebuild()
        try await PlaybackProbe.waitReady(engine)
        let r = try await PlaybackProbe.measure(engine, seconds: seconds)
        let fps = p.project.settings.frameRate.fps
        let expected = r.itemSeconds * fps
        let dropped = expected > 0 ? max(0, 1 - Double(r.composed) / expected) * 100 : 100
        emit("\(name)_composed_fps", r.composedFPS, "fps")
        emit("\(name)_compose_p95_ms", r.composeCostP95Ms, "ms")
        emit("\(name)_dropped_pct", dropped, "%")
        emit("\(name)_render_size", Double(engine.renderSize.height), "px")
        #expect(r.composed > 0)
    }

    @Test func playbackComplex1080p() async throws {
        let p = try await complexProject(canvas: Size2(1920, 1080))
        try await measurePlayback("preview_complex_1080p", p, proxies: true)
    }

    @Test func playbackComplex4K() async throws {
        let p = try await complexProject(canvas: Size2(3840, 2160))
        try await measurePlayback("preview_complex_4k", p, proxies: true)
    }

    /// 8 GB policy: 4K media gets a proxy automatically (auto policy), and preview then decodes the proxy.
    @Test func proxiesKickInAutomatically() async throws {
        let asset = try await MediaProbe.probe(Self.media.appendingPathComponent("d.mp4"))
        #expect(ProxyManager.shared.shouldGenerate(asset), "auto policy must proxy 4K media")
        let t0 = Date()
        await ProxyManager.shared.request([asset])
        while ProxyManager.shared.readyProxyURL(for: asset) == nil, Date().timeIntervalSince(t0) < 60 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        emit("proxy_auto_ready_seconds", Date().timeIntervalSince(t0), "s")
        let url = try #require(ProxyManager.shared.readyProxyURL(for: asset))
        #expect(PlaybackEngine.proxySources(asset).video == url, "preview must use the ready proxy")
        let info = try await MediaInfo.probe(url)
        #expect(min(info.width, info.height) <= 720)
    }

    /// Round 2 target: 4K footage with 3 effects and an animated title on an 8 GB Air. The engine queues a proxy for the
    /// (never seen before) 4K clip by itself, switches the preview to it when ready, and then plays a steady 30 fps.
    @Test func playback4KEffectsTextAutoProxy() async throws {
        // fresh content hash: no proxy can exist yet (the bench clips' proxies are cached by earlier runs)
        let fresh = FileManager.default.temporaryDirectory.appendingPathComponent("valse-fresh4k-\(UUID().uuidString).mp4")
        let seed = UInt8.random(in: 0...200)
        try await SyntheticMedia.writeVideo(to: fresh, size: CGSize(width: 3840, height: 2160), seconds: 6, fps: 30, codec: .hevc,
                                            audioHz: nil) { f, n in
            SyntheticMedia.Paint(background: (seed, UInt8(f * 255 / max(n, 1)), 90),
                                 box: (CGRect(x: Double(f) / Double(max(n, 1)) * 0.7, y: 0.3, width: 0.3, height: 0.4), (240, 240, 240)))
        }
        defer { try? FileManager.default.removeItem(at: fresh) }
        var p = TestProject(canvas: Size2(3840, 2160))
        let c1 = try await p.addMedia(fresh, duration: Time(6))
        let c2 = try await p.addMedia(Self.media.appendingPathComponent("d.mp4"), at: Time(6), duration: Time(6))
        for c in [c1, c2] {
            p[c].effects = [EffectInstance(typeID: "valse.effect.blur"), EffectInstance(typeID: "valse.filter.warm"),
                            EffectInstance(typeID: "valse.effect.vignette")]
        }
        let title = try p.addText("4K + 3 effects", at: Time(0.5), duration: Time(10))
        p[title].animations.inAnim = AnimationInstance(typeID: "valse.anim.in.fade")
        let asset = try #require(p.project.media.first { $0.url.lastPathComponent == fresh.lastPathComponent })
        #expect(ProxyManager.shared.shouldGenerate(asset), "auto policy must proxy 4K media")
        #expect(ProxyManager.shared.readyProxyURL(for: asset) == nil)

        let engine = PlaybackEngine(project: p.project)   // default chooser: proxies when ready
        try await PlaybackProbe.waitReady(engine)
        let t0 = Date()
        while ProxyManager.shared.readyProxyURL(for: asset) == nil, Date().timeIntervalSince(t0) < 90 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        emit("proxy_auto_kickin_seconds", Date().timeIntervalSince(t0), "s")
        let proxy = try #require(ProxyManager.shared.readyProxyURL(for: asset), "engine must queue the proxy itself")
        // the engine rebuilds onto the proxy when it is ready
        try await Task.sleep(nanoseconds: 300_000_000)
        try await PlaybackProbe.waitReady(engine)
        let tracks = engine.player.currentItem?.asset as? AVComposition
        let files = Set(tracks?.tracks.flatMap { $0.segments.compactMap { $0.sourceURL?.lastPathComponent } } ?? [])
        #expect(files.contains(proxy.lastPathComponent), "preview must decode the proxy")
        #expect(!files.contains(fresh.lastPathComponent), "preview must not decode the 4K original")

        let r = try await PlaybackProbe.measure(engine, seconds: 5)
        let expected = r.itemSeconds * 30
        let dropped = expected > 0 ? max(0, 1 - Double(r.composed) / expected) * 100 : 100
        emit("preview_4k_fx_text_composed_fps", r.composedFPS, "fps")
        emit("preview_4k_fx_text_dropped_pct", dropped, "%")
        emit("preview_4k_fx_text_compose_p95_ms", r.composeCostP95Ms, "ms")
        try? FileManager.default.removeItem(at: proxy)
        ProxyManager.shared.reloadFromDisk()
    }

    /// Paused scrubbing: exact seek → the frame for that time is available from the player's video output.
    func scrubLatencies(_ engine: PlaybackEngine, count: Int, span: Double) async throws -> [Double] {
        var lat: [Double] = []
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<count {
            let t = Double.random(in: 0.2..<span, using: &rng)
            let target = Time(t).cmTime
            let t0 = CACurrentMediaTime()
            engine.seek(to: Time(t), exact: true)
            while CACurrentMediaTime() - t0 < 3 {
                if let out = engine.videoOutput, out.hasNewPixelBuffer(forItemTime: target) {
                    var shown = CMTime.invalid
                    if out.copyPixelBuffer(forItemTime: target, itemTimeForDisplay: &shown) != nil, abs(shown.seconds - t) < 0.05 { break }
                }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            lat.append((CACurrentMediaTime() - t0) * 1000)
        }
        return lat
    }

    @Test func scrubLatency() async throws {
        let p = try await complexProject(canvas: Size2(1920, 1080))
        for proxies in [true, false] {
            let engine = PlaybackEngine(project: p.project)
            if !proxies { engine.sourceChooser = PlaybackEngine.originalSources }
            engine.forceRebuild()
            try await PlaybackProbe.waitReady(engine)
            _ = try await scrubLatencies(engine, count: 3, span: 11)  // warm decoders
            let lat = try await scrubLatencies(engine, count: 25, span: 11)
            emit(proxies ? "scrub_proxy_p95_ms" : "scrub_original_p95_ms", Self.p95(lat), "ms")
        }
    }

    /// Paused live edit (inspector slider): re-render of the current frame from cached sources with the new project.
    @Test func pausedEditRerender() async throws {
        var p = try await complexProject(canvas: Size2(1920, 1080))
        let engine = PlaybackEngine(project: p.project)
        try await PlaybackProbe.waitReady(engine)
        engine.seek(to: Time(2))
        try await Task.sleep(nanoseconds: 600_000_000)
        let size = engine.renderSize
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width), height: Int(size.height), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
        let out = try #require(MetalContext.shared.device.makeTexture(descriptor: d))
        let id = p.mainClips[0]
        var cpu: [Double] = [], total: [Double] = []
        for i in 0..<60 {
            p[id].opacity = 0.5 + 0.5 * Double(i % 2)
            let c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            engine.update(project: p.project)
            guard let cmd = MetalContext.shared.queue.makeCommandBuffer() else { continue }
            let ok = engine.renderCurrentFrame(into: out, commandBuffer: cmd)
            cmd.commit()
            let c = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - c0) / 1e6
            await cmd.completed()
            if ok { cpu.append(c); total.append(c + max(0, (cmd.gpuEndTime - cmd.gpuStartTime) * 1000)) }
        }
        try #require(!cpu.isEmpty, "no cached sources to re-render from")
        emit("paused_edit_main_cpu_p95_ms", Self.p95(cpu), "ms")
        emit("paused_edit_frame_p95_ms", Self.p95(total), "ms")
    }

    /// Lifetime peak physical footprint of the test process after the playback / export / scrub tests (8 GB policy
    /// under --air). Runs last in this suite (Swift Testing runs serialized suites in declaration order).
    @Test func zzMemoryPeak() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        #expect(kr == KERN_SUCCESS)
        emit("engine_memory_peak_mb", Double(info.ledger_phys_footprint_peak) / 1_048_576, "MB")
    }
}
