@preconcurrency import Metal
import Foundation
import VideoToolbox
import CoreMedia
import ValseCore

/// "Environment testing" (SE-014): a local hardware capability probe — GPU, memory, OS, hardware codecs, free disk
/// space for caches, FFmpeg sidecar — with a verdict ("can run Valse smoothly" / warnings). No network.
public enum EnvironmentProbe {
    public enum Status: String, Sendable { case ok, warning, missing }

    public struct Check: Sendable, Identifiable, Equatable {
        public var id: String
        /// Localization key of the row title; `value` is data (device names, sizes).
        public var titleKey: String
        public var value: String
        public var status: Status
        /// Localization key of the advice shown under a warning (nil when fine).
        public var adviceKey: String?
    }

    public struct Report: Sendable, Equatable {
        public var checks: [Check]
        public var smooth: Bool { !checks.contains { $0.status == .missing } && checks.filter { $0.status == .warning }.count <= 1 }
    }

    public static func run(cacheDirectory: URL = ValsePaths.cacheDirectory) -> Report {
        var c: [Check] = []
        let gpu = MTLCreateSystemDefaultDevice()
        let apple7 = gpu?.supportsFamily(.apple7) ?? false
        c.append(Check(id: "gpu", titleKey: "env.gpu", value: gpu?.name ?? "—",
                       status: gpu == nil ? .missing : (apple7 ? .ok : .warning), adviceKey: apple7 ? nil : "env.gpu.advice"))
        let ram = Double(MemoryBudget.physicalMemory) / 1_073_741_824
        c.append(Check(id: "memory", titleKey: "env.memory", value: String(format: "%.0f GB", ram),
                       status: ram < 7.5 ? .warning : .ok, adviceKey: ram < 7.5 ? "env.memory.advice" : nil))
        let os = ProcessInfo.processInfo.operatingSystemVersion
        // macOS 13 runs Valse with fewer AI features (subject cutout, translation, Apple Intelligence…): a warning, not missing.
        c.append(Check(id: "os", titleKey: "env.os", value: "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                       status: os.majorVersion >= 14 ? .ok : (os.majorVersion == 13 ? .warning : .missing),
                       adviceKey: os.majorVersion >= 14 ? nil : (os.majorVersion == 13 ? "env.os.advice13" : "env.os.advice")))
        let hevcDec = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        let h264Dec = VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)
        c.append(Check(id: "decode", titleKey: "env.decode", value: codecList([("H.264", h264Dec), ("HEVC", hevcDec),
                       ("ProRes", VTIsHardwareDecodeSupported(kCMVideoCodecType_AppleProRes422))]),
                       status: hevcDec && h264Dec ? .ok : .warning, adviceKey: hevcDec ? nil : "env.decode.advice"))
        let encoders = hardwareEncoders()
        c.append(Check(id: "encode", titleKey: "env.encode", value: codecList([("H.264", encoders.contains(kCMVideoCodecType_H264)),
                       ("HEVC", encoders.contains(kCMVideoCodecType_HEVC)), ("ProRes", encoders.contains(kCMVideoCodecType_AppleProRes422))]),
                       status: encoders.contains(kCMVideoCodecType_H264) ? .ok : .warning,
                       adviceKey: encoders.contains(kCMVideoCodecType_H264) ? nil : "env.encode.advice"))
        let free = freeSpace(cacheDirectory)
        c.append(Check(id: "disk", titleKey: "env.disk", value: free.map { String(format: "%.1f GB", Double($0) / 1_073_741_824) } ?? "—",
                       status: (free ?? 0) < 10_737_418_240 ? .warning : .ok, adviceKey: (free ?? 0) < 10_737_418_240 ? "env.disk.advice" : nil))
        let ff = FFmpegSidecar.executableURL
        c.append(Check(id: "ffmpeg", titleKey: "env.ffmpeg", value: ff?.path ?? "—", status: ff == nil ? .warning : .ok,
                       adviceKey: ff == nil ? "env.ffmpeg.advice" : nil))
        return Report(checks: c)
    }

    static func codecList(_ items: [(String, Bool)]) -> String {
        items.map { "\($0.0) \($0.1 ? "✓" : "✗")" }.joined(separator: "  ")
    }

    /// Codec types with a hardware-accelerated VideoToolbox encoder.
    static func hardwareEncoders() -> Set<CMVideoCodecType> {
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr, let arr = list as? [[String: Any]] else { return [] }
        var out = Set<CMVideoCodecType>()
        for e in arr where (e[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool) == true {
            if let t = e[kVTVideoEncoderList_CodecType as String] as? UInt32 { out.insert(t) }
        }
        return out
    }

    static func freeSpace(_ url: URL) -> Int64? {
        var u = url
        while !FileManager.default.fileExists(atPath: u.path), u.pathComponents.count > 1 { u.deleteLastPathComponent() }
        let v = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }
}
