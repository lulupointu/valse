@preconcurrency import AVFoundation
import Foundation
import MontageCore
import MontageEngine

/// File facts for export checks. Uses ffprobe when installed (frame counts, codec names), else AVFoundation.
public struct MediaInfo: Sendable, CustomStringConvertible {
    public var videoCodec: String?
    public var width: Int
    public var height: Int
    public var fps: Double
    public var frameCount: Int?
    public var duration: Double
    public var hasAudio: Bool
    public var audioCodec: String?
    /// ffprobe only: e.g. "yuv420p10le", "arib-std-b67", "bt2020".
    public var pixelFormat: String? = nil
    public var colorTransfer: String? = nil
    public var colorPrimaries: String? = nil
    /// ffprobe only (export format tests): codec profile ("High", "Main 10", "4444 XQ"…), YCbCr matrix, first PTS,
    /// audio stream facts, container brand / bit rate.
    public var profile: String? = nil
    public var colorMatrix: String? = nil
    public var videoStartTime: Double? = nil
    public var audioStreamCount: Int = 0
    public var audioSampleRate: Int? = nil
    public var audioChannels: Int? = nil
    public var formatBitRate: Int? = nil
    public var videoBitRate: Int? = nil
    public var majorBrand: String? = nil
    public var formatName: String? = nil
    /// ffprobe `r_frame_rate` (exact nominal rate, e.g. 24000/1001).
    public var nominalFPS: Double? = nil

    public var description: String {
        "\(videoCodec ?? "-") \(width)x\(height) @\(fps) frames=\(frameCount.map(String.init) ?? "?") dur=\(duration) audio=\(audioCodec ?? "none")"
    }

    public static let ffprobePath: String? = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"].first {
        FileManager.default.isExecutableFile(atPath: $0)
    }

    public static func probe(_ url: URL) async throws -> MediaInfo {
        if let ff = ffprobePath {
            // ffprobe blocks (process + pipe) for up to seconds under load: off the cooperative pool. A failed run (spawn
            // refused / killed on a loaded machine) is retried; if ffprobe still fails the probe THROWS instead of falling
            // back to AVFoundation, whose MediaInfo lacks the ffprobe-only fields (pixel format, colour tags…): the
            // fallback made export tests fail on a nil colorTransfer instead of saying ffprobe failed.
            var last = "?"
            for attempt in 1...3 {
                let r = try await OffPool.run { _ in ffprobe(ff, url) }
                switch r {
                case .success(let info): return info
                case .failure(let why): last = why
                }
                if attempt < 3 { try await Task.sleep(nanoseconds: 200_000_000) }
            }
            throw NSError(domain: "MediaInfo", code: 1, userInfo: [NSLocalizedDescriptionKey: "ffprobe failed on \(url.lastPathComponent): \(last)"])
        }
        let asset = AVURLAsset(url: url)
        let dur = try await asset.load(.duration).seconds
        let v = try await asset.loadTracks(withMediaType: .video).first
        let a = try await asset.loadTracks(withMediaType: .audio).first
        var info = MediaInfo(videoCodec: nil, width: 0, height: 0, fps: 0, frameCount: nil, duration: dur, hasAudio: a != nil, audioCodec: a == nil ? nil : "aac")
        if let v {
            let (size, rate, fmts) = try await v.load(.naturalSize, .nominalFrameRate, .formatDescriptions)
            info.width = Int(size.width); info.height = Int(size.height); info.fps = Double(rate)
            if let f = fmts.first {
                switch CMFormatDescriptionGetMediaSubType(f) {
                case kCMVideoCodecType_H264: info.videoCodec = "h264"
                case kCMVideoCodecType_HEVC: info.videoCodec = "hevc"
                case kCMVideoCodecType_AppleProRes422: info.videoCodec = "prores"
                case kCMVideoCodecType_AppleProRes4444: info.videoCodec = "prores"
                default: info.videoCodec = "other"
                }
            }
        }
        return info
    }

    enum ProbeResult: Sendable { case success(MediaInfo), failure(String) }

    static func ffprobe(_ path: String, _ url: URL) -> ProbeResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-v", "error", "-count_packets", "-show_entries",
                       "stream=codec_type,codec_name,profile,width,height,avg_frame_rate,r_frame_rate,nb_read_packets,pix_fmt,color_transfer,color_primaries,color_space,start_time,sample_rate,channels,bit_rate:format=duration,bit_rate,format_name:format_tags=major_brand", "-of", "json", url.path]
        // stderr to a file, not a pipe: a full stderr pipe would block ffprobe while we read stdout
        let errURL = FileManager.default.temporaryDirectory.appendingPathComponent("ffprobe-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errURL) }
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = (try? FileHandle(forWritingTo: errURL)) ?? FileHandle.nullDevice
        do { try p.run() } catch { return .failure("launch: \(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], p.terminationStatus == 0 else {
            let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            return .failure("exit \(p.terminationStatus) (\(p.terminationReason == .uncaughtSignal ? "signal" : "exit")), \(data.count) bytes out, stderr: \(err.prefix(300))")
        }
        let streams = obj["streams"] as? [[String: Any]] ?? []
        let v = streams.first { $0["codec_type"] as? String == "video" }
        let a = streams.first { $0["codec_type"] as? String == "audio" }
        func rate(_ s: String?) -> Double {
            guard let s else { return 0 }
            let parts = s.split(separator: "/").compactMap { Double($0) }
            return parts.count == 2 && parts[1] != 0 ? parts[0] / parts[1] : (parts.first ?? 0)
        }
        let dur = Double((obj["format"] as? [String: Any])?["duration"] as? String ?? "") ?? 0
        return .success(MediaInfo(videoCodec: v?["codec_name"] as? String, width: v?["width"] as? Int ?? 0, height: v?["height"] as? Int ?? 0,
                         fps: rate(v?["avg_frame_rate"] as? String), frameCount: Int(v?["nb_read_packets"] as? String ?? ""),
                         duration: dur, hasAudio: a != nil, audioCodec: a?["codec_name"] as? String,
                         pixelFormat: v?["pix_fmt"] as? String, colorTransfer: v?["color_transfer"] as? String,
                         colorPrimaries: v?["color_primaries"] as? String,
                         profile: v?["profile"] as? String, colorMatrix: v?["color_space"] as? String,
                         videoStartTime: Double(v?["start_time"] as? String ?? ""),
                         audioStreamCount: streams.filter { $0["codec_type"] as? String == "audio" }.count,
                         audioSampleRate: Int(a?["sample_rate"] as? String ?? ""), audioChannels: a?["channels"] as? Int,
                         formatBitRate: Int((obj["format"] as? [String: Any])?["bit_rate"] as? String ?? ""),
                         videoBitRate: Int(v?["bit_rate"] as? String ?? ""),
                         majorBrand: ((obj["format"] as? [String: Any])?["tags"] as? [String: Any])?["major_brand"] as? String,
                         formatName: (obj["format"] as? [String: Any])?["format_name"] as? String,
                         nominalFPS: v.map { rate($0["r_frame_rate"] as? String) }))
    }
}
