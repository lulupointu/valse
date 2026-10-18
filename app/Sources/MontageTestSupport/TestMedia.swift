import CoreGraphics
import Foundation
import MontageCore
import MontageEngine

/// Synthetic media generated on demand into a per-user temp cache (reused across runs by content key).
public enum TestMedia {
    public static let directory: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("montage-test-media-v1", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Video file with `pattern`. Cached by parameters.
    public static func video(_ pattern: SyntheticMedia.Pattern, seconds: Double = 2, size: CGSize = CGSize(width: 320, height: 180),
                             fps: Int32 = 30, codec: SyntheticMedia.Codec = .h264, audioHz: Double? = nil) async throws -> URL {
        let key = "\(pattern)-\(seconds)-\(Int(size.width))x\(Int(size.height))-\(fps)-\(codec)-\(audioHz ?? 0)"
        let ext = codec == .proRes422 ? "mov" : "mp4"
        let url = directory.appendingPathComponent("v-\(stableHash(key)).\(ext)")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let tmp = directory.appendingPathComponent("tmp-\(UUID().uuidString).\(ext)")
        try await SyntheticMedia.writeVideo(to: tmp, size: size, seconds: seconds, fps: fps, codec: codec, pattern: pattern, audioHz: audioHz)
        try? FileManager.default.moveItem(at: tmp, to: url)
        return url
    }

    public static func image(_ pattern: SyntheticMedia.Pattern, size: CGSize = CGSize(width: 320, height: 320)) throws -> URL {
        let url = directory.appendingPathComponent("i-\(stableHash("\(pattern)-\(size)")).png")
        if !FileManager.default.fileExists(atPath: url.path) { try SyntheticMedia.writePNG(to: url, size: size, pattern: pattern) }
        return url
    }

    public static func audio(seconds: Double = 2, hz: Double = 440) async throws -> URL {
        let url = directory.appendingPathComponent("a-\(stableHash("\(seconds)-\(hz)")).m4a")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let tmp = directory.appendingPathComponent("tmp-\(UUID().uuidString).m4a")
        try await SyntheticMedia.writeAudio(to: tmp, seconds: seconds, hz: hz)
        try? FileManager.default.moveItem(at: tmp, to: url)
        return url
    }

    /// FNV-1a (String.hashValue is randomized per process).
    static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// Repo-relative path helper (bench media etc.).
    public static func repoRoot(file: String = #filePath) -> URL {
        var u = URL(fileURLWithPath: file)
        while u.path != "/" {
            u.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: u.appendingPathComponent("Package.swift").path),
               FileManager.default.fileExists(atPath: u.appendingPathComponent("docs").path) { return u }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}
