import Testing
import Foundation
import MontageCore
import MontageEngine
import MontageTestSupport

@MainActor @Suite(.serialized) struct PlaybackTests {
    @Test func playbackDeliversFramesInRealTime() async throws {
        try await HeavyWorkGate.run {   // keep real-time probes / ML tests from starving each other
            var p = TestProject()
            try await p.addVideo(.movingBox(.red, .white), seconds: 3, audioHz: 440)
            let engine = PlaybackEngine(project: p.project)
            // Wall-clock delivery flakes when parallel builds oversubscribe the machine (the main-actor poll and the
            // player clock get preempted). The load-independent checks — compositor frame cost and composed frames per
            // advanced media second — always apply; the wall-clock fps check is retried, and only waived when the
            // machine is oversubscribed while the compositor is provably fast enough.
            var r = try await PlaybackProbe.measure(engine, seconds: 1.0)
            var attempt = 1
            while r.fps <= 20, attempt < 3 {
                attempt += 1
                try await Task.sleep(nanoseconds: 300_000_000)
                r = try await PlaybackProbe.measure(engine, seconds: 1.0)
            }
            let load = PlaybackProbe.loadPerCore()
            print("playback probe: \(String(format: "%.1f", r.fps)) fps wall, composed \(r.composed) in \(String(format: "%.2f", r.itemSeconds)) s item time, cost p95 \(String(format: "%.2f", r.composeCostP95Ms)) ms, load/core \(String(format: "%.2f", load)), attempts \(attempt)")
            #expect(r.composed > 0, "compositor never ran")
            // gross-regression bounds only (budgets: 30 fps sustainable, 20 fps composed); precise ones in scripts/perf.sh
            if let lim = TimingBudget.limit(1000 / 30, "compositor frame cost") {
                #expect(r.composeCostP95Ms < lim, "compositor p95 frame cost \(r.composeCostP95Ms) ms")
            }
            if r.itemSeconds > 0.3, let lim = TimingBudget.limit(1000 / 20, "composed frame interval") {
                #expect(1000 / max(r.composedFPS, 0.001) < lim, "composed \(r.composedFPS) fps of item time")
            }
            if r.fps <= 20 {
                if load > 1 || r.fps > 20 / TimingBudget.factor {
                    print("⚠️ wall-clock playback \(r.fps) fps (machine load \(load)/core) — gross-regression bound only, not failing")
                } else {
                    Issue.record("got \(r.fps) fps (load \(load)/core, compositor p95 \(r.composeCostP95Ms) ms)")
                }
            }
        }
    }

    @Test func propertyEditsDoNotRebuildTheComposition() async throws {
        var p = TestProject()
        let id = try await p.addVideo(.solid(.red), seconds: 2)
        let engine = PlaybackEngine(project: p.project)
        try await PlaybackProbe.waitReady(engine)
        var replaced = 0, redraws = 0
        engine.onItemReplaced = { replaced += 1 }
        engine.onRedrawNeeded = { redraws += 1 }
        p[id].opacity = 0.3
        engine.update(project: p.project)
        #expect(replaced == 0 && redraws == 1)
        try TimelineOps.trim(id, edge: .tail, to: 1, in: &p.project)
        engine.update(project: p.project)
        // the rebuild is async: wait for it (a fixed 0.3 s flaked under machine load)
        for _ in 0..<100 where replaced == 0 { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(replaced == 1)
        #expect(engine.duration == Time(1))
    }

    @Test func seekingCoalescesAndClamps() async throws {
        var p = TestProject()
        try await p.addVideo(.frameIndex, seconds: 2)
        let engine = PlaybackEngine(project: p.project)
        try await PlaybackProbe.waitReady(engine)
        for i in 0..<20 { engine.seek(to: Time(Double(i) * 0.05), exact: false) }
        engine.seek(to: Time(50))
        #expect(engine.currentTime == Time(2))
        engine.step(frames: -1)
        #expect(engine.currentTime == Time(2) - FrameRate.fps30.frameDuration)
    }

    @Test func previewSizeFollowsQualityAndAspect() {
        let s = PlaybackEngine.previewSize(canvas: Size2(1080, 1920), quality: .half)
        #expect(s.width == 540 && s.height == 960)
        let f = PlaybackEngine.previewSize(canvas: Size2(3840, 2160), quality: .full)
        #expect(f.height == 2160)
    }
}

@Suite(.serialized) struct CacheTests {
    @Test func proxyIsSmallAndKeyframeDense() async throws {
        let src = try await TestMedia.video(.movingBox(.blue, .white), seconds: 2, size: CGSize(width: 640, height: 360))
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-\(UUID()).mp4")
        try await ProxyManager.generate(source: src, to: dst, maxShortSide: 180)
        let info = try await MediaInfo.probe(dst)
        #expect(info.width == 320 && info.height == 180)
        #expect(info.videoCodec == "h264")
        #expect(!info.hasAudio)
    }

    @Test func thumbnailsAreGeneratedAndCached() async throws {
        let a = try await MediaProbe.probe(try await TestMedia.video(.solid(.green), seconds: 2))
        let img = try #require(await ThumbnailCache.shared.thumbnail(a, at: Time(1), height: 64))
        #expect(img.height == 64)
        #expect(ThumbnailCache.shared.cached(a, at: Time(1.1), height: 64) != nil)
    }

    @Test func waveformPeaksMatchToneAmplitude() async throws {
        let w = try await WaveformCache.compute(try await TestMedia.audio(seconds: 1, hz: 440))
        #expect(abs(w.peaks.count - 100) <= 2)
        // 0.3 amplitude stereo tone; the mono downmix may apply equal-power gain (≈0.42)
        #expect((0.25...0.5).contains(w.peak(from: 0.2, to: 0.8)))
    }

    @Test func jobQueueRunsByPriorityAndCancels() async throws {
        let q = JobQueue(maxConcurrent: 1)
        let log = LogBox()
        let blocker = await q.enqueue(titleKey: "t") { _ in try await Task.sleep(nanoseconds: 100_000_000) }
        let low = await q.enqueue(titleKey: "low", priority: -1) { _ in log.add("low") }
        let high = await q.enqueue(titleKey: "high", priority: 5) { p in p.report(0.5); log.add("high") }
        let doomed = await q.enqueue(titleKey: "doomed", priority: -5) { _ in log.add("doomed") }
        await q.cancel(doomed)
        _ = await q.wait(blocker); _ = await q.wait(low); _ = await q.wait(high)
        #expect(log.items == ["high", "low"])
        #expect(await q.wait(doomed) == .cancelled)
    }
}

final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [String] = []
    func add(_ s: String) { lock.withLock { _items.append(s) } }
    var items: [String] { lock.withLock { _items } }
}

@MainActor @Suite struct StructureKeyCacheTests {
    @Test func incrementalKeyTracksStructuralEditsOnly() async throws {
        var p = TestProject()
        let a = try await p.addVideo(.solid(.red), seconds: 2)
        let b = try await p.addVideo(.solid(.blue), seconds: 2, target: .newTrack)
        let cache = StructureKeyCache()
        let src = PlaybackEngine.proxySources
        let k0 = cache.key(p.project, sources: src)
        #expect(cache.key(p.project, sources: src) == k0)
        p[a].opacity = 0.3                     // live property: same key
        #expect(cache.key(p.project, sources: src) == k0)
        p[b].start = Time(0.5)                 // structural edit on the other track: new key
        let k1 = cache.key(p.project, sources: src)
        #expect(k1 != k0)
        p[a].audio.volume = 0.2                // audio structure
        #expect(cache.key(p.project, sources: src) != k1)
        // a fresh cache agrees with the warmed one
        #expect(StructureKeyCache().key(p.project, sources: src) == cache.key(p.project, sources: src))
        p.project.media[0].duration = Time(99) // media change flushes the cache
        _ = cache.key(p.project, sources: src)
        #expect(StructureKeyCache().key(p.project, sources: src) == cache.key(p.project, sources: src))
    }
}
