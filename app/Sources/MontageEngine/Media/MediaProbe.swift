@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import MontageCore

public enum MediaProbeError: Error, Sendable {
    case unsupported(URL)
    case unreadable(URL, String)
    public var messageKey: String { "error.unsupportedMedia" }
}

/// Reads metadata of a file at import time (async, off the main thread). Never decodes frames.
public enum MediaProbe {
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "webp", "bmp"]
    public static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aif", "aiff", "aac", "caf", "flac"]

    public static func probe(_ url: URL) async throws -> MediaAsset {
        let ext = url.pathExtension.lowercased()
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let hash = contentHash(url, size: size, mtime: attrs?[.modificationDate] as? Date)
        let name = url.deletingPathExtension().lastPathComponent
        if imageExtensions.contains(ext) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { throw MediaProbeError.unsupported(url) }
            var w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
            var h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
            if let o = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue, o >= 5 { swap(&w, &h) }
            return MediaAsset(name: name, kind: .image, url: url, duration: .indefinite, pixelSize: Size2(w, h), frameRate: nil,
                              hasVideo: false, hasAudio: false, contentHash: hash, fileSize: size, codec: ext)
        }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration: CMTime
        let vTracks: [AVAssetTrack], aTracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration)
            vTracks = try await asset.loadTracks(withMediaType: .video)
            aTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch { throw MediaProbeError.unreadable(url, error.localizedDescription) }
        guard !vTracks.isEmpty || !aTracks.isEmpty else { throw MediaProbeError.unsupported(url) }
        var pixel = Size2.zero, fps: FrameRate?, rotation = 0, codec: String?
        var primaries: String?, transfer: String?, matrix: String?, depth: Int?
        if let v = vTracks.first {
            let (natural, transform, rate, formats) = try await v.load(.naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions)
            rotation = rotationDegrees(transform)
            pixel = rotation % 180 == 0 ? Size2(natural.width, natural.height) : Size2(natural.height, natural.width)
            fps = rate > 0 ? FrameRate.nearest(to: Double(rate)) : nil
            if let f = formats.first {
                codec = fourCC(CMFormatDescriptionGetMediaSubType(f))
                (primaries, transfer, matrix, depth) = colorTags(f)
            }
        }
        var probed = MediaAsset(name: name, kind: vTracks.isEmpty ? .audio : .video, url: url, duration: Time(cmTime: duration),
                               pixelSize: pixel, frameRate: fps, hasVideo: !vTracks.isEmpty, hasAudio: !aTracks.isEmpty,
                               contentHash: hash, fileSize: size, codec: codec, sourceRotation: rotation)
        probed.colorPrimaries = primaries; probed.transferFunction = transfer; probed.yCbCrMatrix = matrix; probed.bitDepth = depth
        return probed
    }

    /// Probes many files concurrently, preserving order; failures are returned separately.
    public static func probeAll(_ urls: [URL]) async -> (assets: [MediaAsset], failed: [URL]) {
        await withTaskGroup(of: (Int, MediaAsset?).self) { g in
            for (i, u) in urls.enumerated() { g.addTask { (i, try? await probe(u)) } }
            var out = [MediaAsset?](repeating: nil, count: urls.count)
            for await (i, a) in g { out[i] = a }
            return (out.compactMap { $0 }, zip(urls, out).filter { $0.1 == nil }.map(\.0))
        }
    }

    /// Expands folders (recursively) into importable files.
    public static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for u in urls {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                let e = fm.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                while let f = e?.nextObject() as? URL { if isImportable(f) { out.append(f) } }
            } else if isImportable(u) { out.append(u) }
        }
        return out
    }

    public static func isImportable(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) || audioExtensions.contains(ext) { return true }
        if let t = UTType(filenameExtension: ext) { return t.conforms(to: .movie) || t.conforms(to: .audio) || t.conforms(to: .image) }
        return false
    }

    /// size + mtime + SHA-256 of the first and last 256 KiB: fast, stable across renames.
    public static func contentHash(_ url: URL, size: Int64, mtime: Date?) -> String {
        var h = SHA256()
        withUnsafeBytes(of: size) { h.update(bufferPointer: $0) }
        if let fh = try? FileHandle(forReadingFrom: url) {
            let chunk = 256 * 1024
            if let d = try? fh.read(upToCount: chunk) { h.update(data: d) }
            if size > Int64(chunk * 2) {
                try? fh.seek(toOffset: UInt64(size - Int64(chunk)))
                if let d = try? fh.read(upToCount: chunk) { h.update(data: d) }
            }
            try? fh.close()
        } else {
            h.update(data: Data(url.path.utf8))
        }
        return h.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Colour primaries / transfer / matrix tags (AVFoundation string constants) and bit depth of a video format.
    static func colorTags(_ f: CMFormatDescription) -> (String?, String?, String?, Int?) {
        func ext(_ k: CFString) -> String? { CMFormatDescriptionGetExtension(f, extensionKey: k) as? String }
        var depth = (CMFormatDescriptionGetExtension(f, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? NSNumber)?.intValue
        if depth == nil, ext(kCMFormatDescriptionExtension_TransferFunction).map({ $0.contains("2100") || $0.contains("2084") }) == true {
            depth = 10
        }
        return (ext(kCMFormatDescriptionExtension_ColorPrimaries), ext(kCMFormatDescriptionExtension_TransferFunction),
                ext(kCMFormatDescriptionExtension_YCbCrMatrix), depth)
    }

    static func rotationDegrees(_ t: CGAffineTransform) -> Int {
        let deg = Int((atan2(t.b, t.a) * 180 / .pi).rounded())
        return ((deg % 360) + 360) % 360
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "\(code)"
    }
}
