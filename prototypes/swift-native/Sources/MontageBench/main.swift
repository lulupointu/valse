import AppKit
import SwiftUI
import AVFoundation
import Vision
import MontageEngine

// MARK: - argument parsing
let argv = CommandLine.arguments
let mode = argv.count > 1 ? argv[1] : "help"
func opt(_ name: String, _ def: String) -> String {
    if let i = argv.firstIndex(of: "--\(name)"), i + 1 < argv.count { return argv[i + 1] }
    return def
}
let mediaDir = URL(fileURLWithPath: opt("media", FileManager.default.currentDirectoryPath + "/bench/media"))
let emit = Metrics.emit
let log = Metrics.log

/// Hard watchdog so a bench step can never hang the orchestrator.
func watchdog(_ seconds: Double) {
    Thread.detachNewThread {
        Thread.sleep(forTimeInterval: seconds)
        log("watchdog timeout in mode \(mode) after \(seconds)s")
        exit(3)
    }
}

func processStartWallTime() -> Double {
    var kp = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    sysctl(&mib, 4, &kp, &size, nil, 0)
    let tv = kp.kp_proc.p_un.__p_starttime
    return Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
}
func wallNow() -> Double { var tv = timeval(); gettimeofday(&tv, nil); return Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6 }

// MARK: - headless modes
func runHeadless(_ body: @escaping () async throws -> Void) -> Never {
    Task {
        do { try await body() } catch { log("error: \(error)"); exit(1) }
        exit(0)
    }
    dispatchMain()
}

switch mode {
case "export":
    watchdog(Double(opt("timeout", "240"))!)
    runHeadless {
        let secs = Double(opt("seconds", "10"))!
        let out = URL(fileURLWithPath: opt("out", NSTemporaryDirectory() + "montage-export.mp4"))
        let project = try await ProjectBuilder.fourLayer(mediaDir: mediaDir)
        let t0 = CACurrentMediaTime()
        try await Exporter.export(project: project, range: CMTimeRange(start: .zero, duration: CMTime(seconds: secs, preferredTimescale: 600)), to: out)
        let dt = CACurrentMediaTime() - t0
        log("exported \(secs)s to \(out.path) in \(dt)s")
        emit("export_seconds", dt, "s")
        emit("export_realtime_factor", secs / dt, "x")
    }
case "seg":
    watchdog(Double(opt("timeout", "240"))!)
    runHeadless {
        let frames = Int(opt("frames", "300"))!
        let url = mediaDir.appendingPathComponent("h264_1080.mp4")
        let bal = try await Segmenter.run(url: url, frames: frames, quality: .balanced)
        log("balanced: \(bal.frames) frames in \(bal.seconds)s, first frame \(bal.firstFrameMs)ms")
        emit("seg_fps", bal.fps, "fps")
        emit("seg_first_frame_ms", bal.firstFrameMs, "ms")
        let fast = try await Segmenter.run(url: url, frames: frames, quality: .fast)
        emit("seg_fps_fast", fast.fps, "fps")
        let acc = try await Segmenter.run(url: url, frames: max(10, frames / 10), quality: .accurate)
        emit("seg_fps_accurate", acc.fps, "fps")
    }
case "stt":
    watchdog(Double(opt("timeout", "300"))!)
    runHeadless {
        let url = mediaDir.appendingPathComponent("speech_fr.wav")
        let refURL = mediaDir.deletingLastPathComponent().appendingPathComponent("speech_fr.txt")
        let reference = (try? String(contentsOf: refURL, encoding: .utf8)) ?? ""
        let dur = try Transcriber.audioDuration(url)
        let cli = opt("whisper-cli", "/opt/homebrew/bin/whisper-cli")
        let model = opt("whisper-model", "")
        if let t = await Transcriber.best(url: url, whisperCLI: cli, whisperModel: model.isEmpty ? nil : model, log: log) {
            log("engine=\(t.engine) words=\(t.words.count) elapsed=\(t.elapsed)s")
            log("text: \(t.text)")
            if let w = t.words.first(where: { $0.start > 10 }) { log("sample word timestamp: '\(w.text)' \(w.start)-\(w.end)s") }
            emit("stt_rtf", t.elapsed / dur, "x")
            if !reference.isEmpty { emit("stt_wer_estimate", WER.compute(reference: reference, hypothesis: t.text), "ratio") }
            emit("stt_word_timestamps", t.words.isEmpty ? 0 : 1, "bool")
        } else {
            emit("stt_rtf", -1, "x")
        }
        // Secondary engine for comparison: whisper.cpp large-v3-turbo (if model present).
        if !model.isEmpty, FileManager.default.fileExists(atPath: model), FileManager.default.fileExists(atPath: cli) {
            do {
                let w = try Transcriber.whisper(url: url, cli: cli, model: model, language: "fr")
                log("whisper text: \(w.text)")
                emit("stt_rtf_whisper", w.elapsed / dur, "x")
                if !reference.isEmpty { emit("stt_wer_whisper", WER.compute(reference: reference, hypothesis: w.text), "ratio") }
            } catch { log("whisper failed: \(error)") }
        }
    }
case "preview", "scrub", "audio", "timeline", "coldstart":
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = GUIBench(mode: mode)
    app.delegate = delegate
    watchdog(Double(opt("timeout", "120"))!)
    app.run()
default:
    print("usage: Montage <preview|scrub|audio|timeline|coldstart|export|seg|stt> [--media DIR] [--seconds N] [--frames N]")
    exit(2)
}

// MARK: - GUI modes

final class GUIBench: NSObject, NSApplicationDelegate {
    let mode: String
    var window: NSWindow!
    init(mode: String) { self.mode = mode }

    func makeWindow(_ size: NSSize, title: String, content: NSView) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = title
        w.contentView = content
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return w
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        switch mode {
        case "timeline": runTimeline()
        case "coldstart": runColdStart()
        default: Task { @MainActor in await self.runPlayback() }
        }
    }

    // P4 timeline + cold start share the SwiftUI shell
    func runColdStart() {
        let start = processStartWallTime()
        let tl = TimelineView(frame: NSRect(x: 0, y: 0, width: 1400, height: 400), clipCount: 500, trackCount: 6)
        let pv = PlayerView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let shell = NSHostingView(rootView: EditorShell(player: pv, timeline: tl))
        window = makeWindow(NSSize(width: 1400, height: 780), title: NSLocalizedString("app.name", comment: ""), content: shell)
        var done = false
        tl.onPresented = { _ in
            if done { return }; done = true
            emit("cold_start_ms", (wallNow() - start) * 1000, "ms")
            emit("shader_compile_ms", MetalContext.shared.shaderCompileMs, "ms")
            exit(0)
        }
        tl.startDisplayLink()
    }

    func runTimeline() {
        let duration = Double(opt("seconds", "5"))!
        let tl = TimelineView(frame: NSRect(x: 0, y: 0, width: 1400, height: 400), clipCount: 500, trackCount: 6)
        let pv = PlayerView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        window = makeWindow(NSSize(width: 1400, height: 780), title: NSLocalizedString("app.name", comment: ""),
                            content: NSHostingView(rootView: EditorShell(player: pv, timeline: tl)))
        let total = tl.totalSeconds
        var t0: CFTimeInterval = 0
        var presented: [CFTimeInterval] = []
        var measuring = false
        tl.animate = { t in
            if t0 == 0 { t0 = t + 0.5 }  // 0.5 s warm-up
            let u = max(0, t - t0) / duration
            // zoom 8 ↔ 200 px/s (exponential, two full cycles) while scrolling across the whole timeline
            tl.pixelsPerSecond = 8 * pow(25, 0.5 - 0.5 * cos(2 * .pi * 2 * u))
            tl.scrollSeconds = max(0, total - 60) * min(1, u)
            tl.playhead = tl.scrollSeconds + 10
        }
        tl.onPresented = { pt in
            if t0 == 0 || pt < t0 { return }
            if pt > t0 + duration {
                if !measuring { return }
                measuring = false
                let fps = Double(presented.count) / duration
                let cpu = Array(tl.cpuFrameMs.suffix(presented.count))
                var gaps: [Double] = []
                for i in 1..<max(1, presented.count) { gaps.append((presented[i] - presented[i - 1]) * 1000) }
                emit("timeline_window_visible", self.window.occlusionState.contains(.visible) ? 1 : 0, "bool")
                emit("timeline_fps", fps, "fps")
                emit("timeline_display_hz", Double(NSScreen.main?.maximumFramesPerSecond ?? 60), "Hz")
                emit("timeline_frame_interval_ms_p95", Metrics.percentile(gaps, 95), "ms")
                emit("timeline_frame_cpu_ms_p95", Metrics.percentile(cpu, 95), "ms")
                let snap = opt("snapshot", "")
                if !snap.isEmpty {
                    tl.snapshot(to: URL(fileURLWithPath: snap))
                    // SwiftUI chrome (Metal areas render blank in a cached display; the canvas is snapshotted above)
                    if let v = self.window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: snap.replacingOccurrences(of: ".png", with: "-shell.png")))
                    }
                }
                exit(0)
            }
            measuring = true
            presented.append(pt)
        }
        tl.startDisplayLink()
    }

    // P1 preview, P2 scrub, P6 audio
    let sampler = ProcSampler()  // created before any decoder spins up (to tell our VT helpers apart)

    @MainActor func runPlayback() async {
        let pv = PlayerView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        window = makeWindow(NSSize(width: 960, height: 540), title: NSLocalizedString("panel.player", comment: ""), content: pv)
        let project: BuiltProject
        do { project = try await ProjectBuilder.fourLayer(mediaDir: mediaDir) } catch { log("build failed: \(error)"); exit(1) }
        let item = AVPlayerItem(asset: project.composition)
        item.videoComposition = project.videoComposition
        item.audioTimePitchAlgorithm = .spectral
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.volume = Float(opt("volume", "0"))!
        pv.output = output
        pv.startDisplayLink()
        while item.status == .unknown { try? await Task.sleep(nanoseconds: 20_000_000) }
        guard item.status == .readyToPlay else { log("item failed: \(String(describing: item.error))"); exit(1) }

        switch mode {
        case "preview": await previewBench(pv, player, item)
        case "scrub": await scrubBench(pv, player, item)
        default: await audioBench(pv, player, item)
        }
        exit(0)
    }

    @MainActor func previewBench(_ pv: PlayerView, _ player: AVPlayer, _ item: AVPlayerItem) async {
        let D = Double(opt("seconds", "20"))!
        var presented: [(CFTimeInterval, CMTime)] = []
        pv.wantedTime = { link, out in out.itemTime(forHostTime: link.targetTimestamp) }
        pv.onPresented = { host, t in presented.append((host, t)) }
        player.play()
        while player.currentTime().seconds < 1.0 { try? await Task.sleep(nanoseconds: 10_000_000) }  // warm-up
        MetalCompositor.stats.reset()
        sampler.start()
        let w0 = CACurrentMediaTime(), i0 = player.currentTime().seconds
        try? await Task.sleep(nanoseconds: UInt64(D * 1e9))
        let wall = CACurrentMediaTime() - w0, itemAdv = player.currentTime().seconds - i0
        let (cpu, rssMean, rssPeak) = sampler.stop()
        try? await Task.sleep(nanoseconds: 300_000_000)  // let late presented-callbacks arrive
        player.pause()
        // count by actual on-screen presentation time, not by callback arrival
        let shown = presented.filter { $0.0 >= w0 && $0.0 < w0 + wall }.map(\.1)
        log("helper processes counted: \(sampler.helperPidsSeen.count)")
        let secs = shown.map(\.seconds)
        var gapDrops = 0
        for i in 1..<max(1, secs.count) { gapDrops += max(0, Int(((secs[i] - secs[i - 1]) * 30).rounded()) - 1) }
        let expected = Int((wall * 30).rounded())
        let visible = window.occlusionState.contains(.visible)
        if !visible { log("WARNING: preview window occluded — macOS throttles presentation; numbers invalid") }
        emit("preview_window_visible", visible ? 1 : 0, "bool")
        emit("preview_fps", Double(shown.count) / wall, "fps")
        emit("preview_dropped_frames", Double(max(0, expected - shown.count)), "frames")
        emit("preview_cpu_pct", cpu, "%")
        // [bench harness fix] preview_rss_mb is the mean (as in the other prototypes); peak reported separately
        emit("preview_rss_mb", rssMean, "MB")
        emit("preview_rss_peak_mb", rssPeak, "MB")
        emit("preview_gap_dropped_frames", Double(gapDrops), "frames")
        emit("preview_playback_rate", itemAdv / wall, "x")
        emit("compositor_frame_ms_p50", Metrics.percentile(MetalCompositor.stats.snapshot(), 50), "ms")
    }

    @MainActor func scrubBench(_ pv: PlayerView, _ player: AVPlayer, _ item: AVPlayerItem) async {
        let n = Int(opt("seeks", "50"))!
        var rng = SplitMix(seed: 7)
        let maxFrame = Int((item.duration.seconds - 1) * 30)
        let targets = (0..<n).map { _ in CMTime(value: CMTimeValue(30 + Int(rng.next() * Double(maxFrame - 30))), timescale: 30) }

        func measure(exact: Bool) async -> [Double] {
            var lat: [Double] = []
            for target in targets {
                let start = CACurrentMediaTime()
                let ms: Double = await withCheckedContinuation { cont in
                    var finished = false
                    let finish = { (v: Double) in if !finished { finished = true; cont.resume(returning: v) } }
                    pv.wantedTime = { _, _ in target }
                    pv.accept = { t in exact ? abs(t.seconds - target.seconds) < 0.5 / 30 : true }
                    pv.onPresented = { host, _ in finish((host - start) * 1000) }
                    if exact { player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) }
                    else { player.seek(to: target, toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { finish(5000) }
                }
                pv.wantedTime = nil
                lat.append(ms)
            }
            return lat
        }
        // first frame
        _ = await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            var done = false
            pv.wantedTime = { _, _ in .zero }; pv.accept = nil
            pv.onPresented = { _, _ in if !done { done = true; c.resume() } }
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        let exact = await measure(exact: true)
        emit("scrub_ms_p50", Metrics.percentile(exact, 50), "ms")
        emit("scrub_ms_p95", Metrics.percentile(exact, 95), "ms")
        emit("scrub_timeouts", Double(exact.filter { $0 >= 5000 }.count), "count")
        let fast = await measure(exact: false)
        emit("scrub_keyframe_ms_p50", Metrics.percentile(fast, 50), "ms")
        emit("scrub_keyframe_ms_p95", Metrics.percentile(fast, 95), "ms")
    }

    @MainActor func audioBench(_ pv: PlayerView, _ player: AVPlayer, _ item: AVPlayerItem) async {
        var frames = 0
        pv.wantedTime = { link, out in out.itemTime(forHostTime: link.targetTimestamp) }
        pv.onPresented = { _, _ in frames += 1 }
        player.playImmediately(atRate: 1.5)
        try? await Task.sleep(nanoseconds: 500_000_000)
        frames = 0
        let i0 = player.currentTime().seconds, w0 = CACurrentMediaTime()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let rate = (player.currentTime().seconds - i0) / (CACurrentMediaTime() - w0)
        let videoFps = Double(frames) / (CACurrentMediaTime() - w0)
        player.pause()
        let livePitchAlgo = item.audioTimePitchAlgorithm == .spectral
        var check: StretchCheck?
        do {
            let pcm = try await AudioStretch.loadPCM(url: mediaDir.appendingPathComponent("a.mp4"), seconds: 4)
            check = try AudioStretch.check(input: pcm, rate: 1.5)
        } catch { log("offline stretch failed: \(error)") }
        log("live: rate=\(rate) videoFps=\(videoFps) algo=spectral:\(livePitchAlgo); offline: in=\(check?.inputHz ?? 0)Hz out=\(check?.outputHz ?? 0)Hz consumed=\(check?.consumedRatio ?? 0)")
        let ok = abs(rate - 1.5) < 0.1 && videoFps > 30 && livePitchAlgo
            && check != nil && abs(check!.pitchRatio - 1) < 0.03 && abs(check!.consumedRatio - 1.5) < 0.1
        emit("audio_stretch_ok", ok ? 1 : 0, "bool")
        emit("audio_stretch_live_rate", rate, "x")
        emit("audio_stretch_video_fps", videoFps, "fps")
        emit("audio_stretch_pitch_ratio", check?.pitchRatio ?? -1, "ratio")
    }
}
