import Testing
import Foundation
import MontageCore
import MontageEngine
import MontageTestSupport

/// Perf smoke tests on the shared 4K bench media (bench/make_media.sh). Opt-in: `MONTAGE_PERF=1 swift test --filter Perf`
/// (scripts/test.sh --perf). Prints JSON lines like the stack benchmark.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MONTAGE_PERF"] == "1"))
struct PerfSmokeTests {
    static let media = TestMedia.repoRoot().appendingPathComponent("bench/media")
    static let seconds = Double(ProcessInfo.processInfo.environment["MONTAGE_PERF_SECONDS"] ?? "") ?? 5

    func project(layers: Int) async throws -> TestProject {
        var p = TestProject(canvas: Size2(1920, 1080))
        let names = ["a", "b", "c", "d"]
        for i in 0..<layers {
            let url = Self.media.appendingPathComponent("\(names[i % 4]).mp4")
            try #require(FileManager.default.fileExists(atPath: url.path), "run bench/make_media.sh first")
            let id = try await p.addMedia(url, target: i == 0 ? .automatic : .newTrack, duration: Time(20))
            if i > 0 {
                p[id].transform.scale = Vec2(0.5, 0.5)
                p[id].transform.position = Vec2(i % 2 == 0 ? 0.25 : -0.25, i < 3 ? -0.25 : 0.25)
                p[id].opacity = 0.8
            }
        }
        return p
    }

    func emit(_ metric: String, _ value: Double, _ unit: String) {
        print("{\"stack\":\"montage\",\"metric\":\"\(metric)\",\"value\":\((value * 100).rounded() / 100),\"unit\":\"\(unit)\"}")
    }

    @Test func playback4x4K() async throws {
        let p = try await project(layers: 4)
        let engine = PlaybackEngine(project: p.project)
        engine.sourceChooser = { MediaSourceChoice(video: $0.url, audio: $0.url) }  // originals, no proxies
        engine.forceRebuild()
        try await PlaybackProbe.waitReady(engine)
        let c0 = engine.state.framesComposed
        let r = try await PlaybackProbe.measure(engine, seconds: Self.seconds)
        emit("preview4k_fps", r.fps, "fps")
        let composed = Double(engine.state.framesComposed - c0) / r.seconds
        emit("preview4k_composed_fps", composed, "fps")
        // Headless polling under-counts delivered frames; the compositor rate is the reliable number.
        #expect(composed > 27)
    }

    @Test func export10s1080p() async throws {
        let p = try await project(layers: 4)
        let t0 = Date()
        let r = try await exportProject(p.project, seconds: 10)
        emit("export_10s_1080p_seconds", Date().timeIntervalSince(t0), "s")
        #expect(r.probe.width == 1920)
    }

    /// W11: 4K HEVC 10 s from 4×4K layers (hardware encoder, GPU compositor 3 frames ahead of the encoder).
    @Test func export10s4KHEVC() async throws {
        let p = try await project(layers: 4)
        var s = ExportSettings(); s.codec = .hevc; s.resolution = .p2160
        let t0 = Date()
        let r = try await exportProject(p.project, seconds: 10, settings: s)
        let secs = Date().timeIntervalSince(t0)
        emit("export_10s_4k_hevc_seconds", secs, "s")
        #expect(r.probe.width == 3840 && r.probe.videoCodec == "hevc")
        #expect(secs < 30)
    }

    @Test func proxyGeneration() async throws {
        let src = Self.media.appendingPathComponent("a.mp4")
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("perf-proxy.mp4")
        let t0 = Date()
        try await ProxyManager.generate(source: src, to: dst)
        emit("proxy_60s_4k_seconds", Date().timeIntervalSince(t0), "s")
    }
}
