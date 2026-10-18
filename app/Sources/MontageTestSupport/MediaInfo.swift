@preconcurrency import AVFoundation
import Foundation
import MontageCore

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

    public var description: String {
        "\(videoCodec ?? "-") \(width)x\(height) @\(fps) frames=\(frameCount.map(String.init) ?? "?") dur=\(duration) audio=\(audioCodec ?? "none")"
    }

    public static let ffprobePath: String? = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"].first {
        FileManager.default.isExecutableFile(atPath: $0)
    }

    public static func probe(_ url: URL) async throws -> MediaInfo {
        if let ff = ffprobePath, let info = ffprobe(ff, url) { return info }
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

    static func ffprobe(_ path: String, _ url: URL) -> MediaInfo? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-v", "error", "-count_packets", "-show_entries",
                       "stream=codec_type,codec_name,width,height,avg_frame_rate,nb_read_packets:format=duration", "-of", "json", url.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let streams = obj["streams"] as? [[String: Any]] ?? []
        let v = streams.first { $0["codec_type"] as? String == "video" }
        let a = streams.first { $0["codec_type"] as? String == "audio" }
        func rate(_ s: String?) -> Double {
            guard let s else { return 0 }
            let parts = s.split(separator: "/").compactMap { Double($0) }
            return parts.count == 2 && parts[1] != 0 ? parts[0] / parts[1] : (parts.first ?? 0)
        }
        let dur = Double((obj["format"] as? [String: Any])?["duration"] as? String ?? "") ?? 0
        return MediaInfo(videoCodec: v?["codec_name"] as? String, width: v?["width"] as? Int ?? 0, height: v?["height"] as? Int ?? 0,
                         fps: rate(v?["avg_frame_rate"] as? String), frameCount: Int(v?["nb_read_packets"] as? String ?? ""),
                         duration: dur, hasAudio: a != nil, audioCodec: a?["codec_name"] as? String)
    }
}
