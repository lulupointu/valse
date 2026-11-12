import Foundation
import ValseCore

/// FFmpeg fallback for files AVFoundation cannot read (MKV, WebM, AVI, FLV, MPEG-2, VP9, AV1, Vorbis/Opus…).
///
/// Licensing decision (see docs/ARCHITECTURE.md §6): FFmpeg is used as a **separate executable** ("sidecar"), never
/// linked into Valse. The bundled binary must be an **LGPL build** (no `--enable-gpl`, no `--enable-nonfree`, so no
/// libx264/libx265/fdk-aac); we only need its demuxers/decoders plus the LGPL `prores_ks` encoder and PCM, so the
/// mezzanine is ProRes + PCM in a .mov. The app ships the FFmpeg LICENSE/notice and a written offer of the exact
/// source. Lookup order: `$VALSE_FFMPEG`, `<app>/Contents/Resources/ffmpeg`, `/opt/homebrew/bin`, `/usr/local/bin`.
public enum FFmpegSidecar {
    public static var executableURL: URL? { locate("ffmpeg") }
    public static var probeURL: URL? { locate("ffprobe") }
    public static var isAvailable: Bool { executableURL != nil }

    static func locate(_ tool: String) -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["VALSE_FFMPEG"] {
            candidates.append(tool == "ffmpeg" ? env : URL(fileURLWithPath: env).deletingLastPathComponent().appendingPathComponent(tool).path)
        }
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent(tool).path) }
        candidates += ["/opt/homebrew/bin/\(tool)", "/usr/local/bin/\(tool)"]
        return candidates.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    public enum SidecarError: Error, Sendable { case notInstalled, failed(String) }

    /// Probes with ffprobe (JSON) → MediaAsset with `conversion = .ffmpeg`.
    static func probe(_ url: URL, name: String, hash: String, size: Int64) async throws -> MediaAsset {
        guard let ffprobe = probeURL else { throw SidecarError.notInstalled }
        let (out, status) = try await run(ffprobe, ["-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", url.path])
        guard status == 0, let json = try JSONSerialization.jsonObject(with: out) as? [String: Any] else { throw SidecarError.failed("ffprobe") }
        let streams = json["streams"] as? [[String: Any]] ?? []
        let format = json["format"] as? [String: Any] ?? [:]
        let video = streams.first { ($0["codec_type"] as? String) == "video" && (($0["disposition"] as? [String: Any])?["attached_pic"] as? Int ?? 0) == 0 }
        let audios = streams.filter { ($0["codec_type"] as? String) == "audio" }
        guard video != nil || !audios.isEmpty else { throw MediaProbeError.unsupported(url) }
        let duration = Double(format["duration"] as? String ?? "") ?? Double(video?["duration"] as? String ?? "") ?? 0
        var pixel = Size2.zero, fps: FrameRate?, rotation = 0
        var info = MediaTechInfo()
        info.container = (format["format_name"] as? String)?.components(separatedBy: ",").first
        info.bitrate = Int64(format["bit_rate"] as? String ?? "")
        info.audioTrackCount = audios.count
        if let v = video {
            let w = Double(v["width"] as? Int ?? 0), h = Double(v["height"] as? Int ?? 0)
            rotation = rotationOf(v)
            pixel = rotation % 180 == 0 ? Size2(w, h) : Size2(h, w)
            if let r = rational(v["avg_frame_rate"] as? String) ?? rational(v["r_frame_rate"] as? String), r > 0 { fps = FrameRate.nearest(to: r) }
            let pf = v["pix_fmt"] as? String ?? ""
            info.hasAlpha = pf.contains("a") && (pf.hasPrefix("yuva") || pf.hasPrefix("rgba") || pf.hasPrefix("argb") || pf.hasPrefix("bgra") || pf.hasPrefix("gbrap"))
            info.colorPrimaries = v["color_primaries"] as? String
            info.transferFunction = v["color_transfer"] as? String
            if let a = rational(v["avg_frame_rate"] as? String), let r = rational(v["r_frame_rate"] as? String), a > 0, r > 0 {
                info.isVariableFrameRate = abs(a - r) / r > 0.05
            }
        }
        if let a = audios.first {
            info.audioCodec = a["codec_name"] as? String
            info.audioSampleRate = Double(a["sample_rate"] as? String ?? "")
            info.audioChannels = a["channels"] as? Int
        }
        var asset = MediaAsset(name: name, kind: video == nil ? .audio : .video, url: url, duration: Time(duration), pixelSize: pixel,
                               frameRate: fps, hasVideo: video != nil, hasAudio: !audios.isEmpty, contentHash: hash, fileSize: size,
                               codec: video?["codec_name"] as? String ?? audios.first?["codec_name"] as? String, sourceRotation: 0)
        asset.conversion = .ffmpeg
        asset.techInfo = info
        // The mezzanine has rotation applied by ffmpeg (autorotate), so the model sees an upright source.
        _ = rotation
        return asset
    }

    static func rotationOf(_ v: [String: Any]) -> Int {
        if let tags = v["tags"] as? [String: Any], let r = Int(tags["rotate"] as? String ?? "") { return ((r % 360) + 360) % 360 }
        for sd in v["side_data_list"] as? [[String: Any]] ?? [] {
            if let r = sd["rotation"] as? Int { return ((-r % 360) + 360) % 360 }
        }
        return 0
    }

    static func rational(_ s: String?) -> Double? {
        guard let s else { return nil }
        let p = s.split(separator: "/")
        if p.count == 2, let a = Double(p[0]), let b = Double(p[1]), b != 0 { return a / b }
        return Double(s)
    }

    /// ffmpeg arguments for the mezzanine: ProRes (LT, or 4444 with alpha) + PCM in .mov, every audio stream kept.
    public static func transcodeArguments(input: URL, output: URL, alpha: Bool) -> [String] {
        var a = ["-nostdin", "-y", "-loglevel", "error", "-i", input.path,
                 "-map", "0:v:0?", "-map", "0:a?", "-dn", "-sn"]
        if alpha {
            a += ["-c:v", "prores_ks", "-profile:v", "4", "-pix_fmt", "yuva444p10le"]
        } else {
            a += ["-c:v", "prores_ks", "-profile:v", "1", "-pix_fmt", "yuv422p10le"]
        }
        a += ["-c:a", "pcm_s16le", "-progress", "pipe:1", "-nostats", "-f", "mov", output.path]
        return a
    }

    /// Transcodes `input` to `output` (.mov). Progress 0…1 parsed from `-progress`. Cancelling the Task kills ffmpeg.
    public static func transcode(_ input: URL, to output: URL, duration: Time, alpha: Bool, progress: JobProgress? = nil) async throws {
        guard let ffmpeg = executableURL else { throw SidecarError.notInstalled }
        try await transcode(ffmpeg: ffmpeg, transcodeArguments(input: input, output: output, alpha: alpha),
                            output: output, duration: duration, progress: progress)
    }

    /// `transcode` with an explicit executable (tests: a fake ffmpeg script). stdout (progress) and stderr (the error
    /// text) are read to EOF by `ProcessPipes` (FLAKY-PIPE: readabilityHandler chunks could land after the error was built).
    static func transcode(ffmpeg: URL, _ arguments: [String], output: URL, duration: Time, progress: JobProgress?) async throws {
        let total = max(duration.seconds, 0.001)
        let r = try await ProcessPipes.run(ffmpeg, arguments, stdout: .init(keep: false) { d in
            guard let s = String(data: d, encoding: .utf8) else { return }
            for line in s.split(separator: "\n") where line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") {
                if let us = Double(line.split(separator: "=").last ?? "") { progress?.report(min(1, us / 1_000_000 / total)) }
            }
        }, stderr: .all)
        let status = r.status
        if Task.isCancelled { try? FileManager.default.removeItem(at: output); throw CancellationError() }
        guard status == 0 else {
            try? FileManager.default.removeItem(at: output)
            throw SidecarError.failed(String(data: r.stderr, encoding: .utf8) ?? "ffmpeg exit \(status)")
        }
    }

    /// Runs a tool to completion, returning its whole stdout and exit status.
    ///
    /// stdout is read by ONE reader, to end of file, then the exit status is awaited. (It used to be collected by a
    /// `readabilityHandler` whose last call could still be in flight when the process exited: `run` then removed the
    /// handler, read the rest and returned before that call appended its chunk, so stdout came back empty or cut —
    /// for ffprobe, invalid JSON, and an MKV failed to import with AVFoundation's "Cannot Open"; FLAKY-ENG,
    /// ImportTests.ffmpegFallbackForMKV, FFmpegSidecarRunTests.) The blocking read runs on an OffPool thread, never on
    /// the cooperative pool.
    static func run(_ exe: URL, _ args: [String]) async throws -> (Data, Int32) {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let exit = ExitStatus()
        p.terminationHandler = { exit.set($0.terminationStatus) }
        try p.run()
        let reader = UncheckedSendable(out.fileHandleForReading)
        // EOF comes when the tool (and anything it spawned) closed stdout, i.e. at its exit at the latest
        let data = try await OffPool.run { _ in reader.value.readDataToEndOfFile() }
        try? reader.value.close()
        return (data, await exit.wait())
    }

    /// A process's exit status, set once by its termination handler, awaited by `run`.
    private final class ExitStatus: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int32?
        private var waiter: CheckedContinuation<Int32, Never>?
        func set(_ s: Int32) {
            let w: CheckedContinuation<Int32, Never>? = lock.withLock {
                status = s
                defer { waiter = nil }
                return waiter
            }
            w?.resume(returning: s)
        }
        func wait() async -> Int32 {
            await withCheckedContinuation { (c: CheckedContinuation<Int32, Never>) in
                let s: Int32? = lock.withLock { if status == nil { waiter = c }; return status }
                if let s { c.resume(returning: s) }
            }
        }
    }
}

final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()
    func append(_ d: Data) { lock.withLock { _data.append(d) } }
    var data: Data { lock.withLock { _data } }
}
