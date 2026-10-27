@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ValseCore

public enum MediaProbeError: Error, Sendable {
    case unsupported(URL)
    case unreadable(URL, String)
    public var messageKey: String { "error.unsupportedMedia" }
}

/// Reads metadata of a file at import time (async, off the main thread). Never decodes frames.
///
/// Breadth (MI-001/MI-013): AVFoundation movies/audio (MP4/MOV/M4V/3GP, H.264/HEVC/ProRes incl. alpha, MP3/AAC/ALAC/
/// WAV/AIFF/FLAC/CAF), ImageIO stills (JPEG/PNG/HEIC/HEIF/TIFF/WebP/BMP/GIF), animated GIF/APNG/WebP/HEICS and numbered
/// image sequences (→ `MediaConversion`, made playable by `PlayableMediaCache`), and everything else FFmpeg can read
/// (MKV/WebM/AVI/FLV/MPEG-2/VP9/AV1…) through `FFmpegSidecar` when it is available.
public enum MediaProbe {
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "apng", "heic", "heif", "heics", "tif", "tiff", "gif", "webp", "bmp", "tga", "exr", "avif"]
    public static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aif", "aiff", "aifc", "aac", "caf", "flac", "m4b", "ac3", "ec3", "amr", "ogg", "opus", "wma"]
    /// Containers FFmpeg handles that AVFoundation usually doesn't.
    public static let ffmpegVideoExtensions: Set<String> = ["mkv", "webm", "avi", "flv", "wmv", "mpg", "mpeg", "m2v", "vob", "ts", "mts", "m2ts", "mxf", "ogv", "3g2", "divx", "f4v", "rm", "rmvb", "asf"]
    /// Frame-sequence-friendly still formats (always eligible for sequence detection).
    static let sequenceExtensions: Set<String> = ["png", "tif", "tiff", "exr", "tga", "dpx", "jpg", "jpeg"]

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
            var info = MediaTechInfo()
            info.hasAlpha = (props[kCGImagePropertyHasAlpha] as? Bool) ?? false
            info.container = ext
            info.bitrate = nil
            let frames = CGImageSourceGetCount(src)
            if frames > 1, let anim = AnimatedImage.timing(src) {
                // Animated GIF / APNG / WebP / HEICS → a video clip once converted.
                var a = MediaAsset(name: name, kind: .video, url: url, duration: anim.duration, pixelSize: Size2(w, h),
                                   frameRate: FrameRate.nearest(to: anim.fps), hasVideo: true, hasAudio: false,
                                   contentHash: hash, fileSize: size, codec: ext)
                a.conversion = .animatedImage
                a.techInfo = info
                return a
            }
            var a = MediaAsset(name: name, kind: .image, url: url, duration: .indefinite, pixelSize: Size2(w, h), frameRate: nil,
                               hasVideo: false, hasAudio: false, contentHash: hash, fileSize: size, codec: ext)
            a.techInfo = info
            return a
        }
        do {
            return try await probeAVFoundation(url, name: name, hash: hash, size: size)
        } catch {
            // Not readable by AVFoundation: FFmpeg fallback (sidecar) when installed/bundled.
            if FFmpegSidecar.isAvailable, let a = try? await FFmpegSidecar.probe(url, name: name, hash: hash, size: size) { return a }
            throw error
        }
    }

    static func probeAVFoundation(_ url: URL, name: String, hash: String, size: Int64) async throws -> MediaAsset {
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
        var info = MediaTechInfo()
        info.container = url.pathExtension.lowercased()
        info.audioTrackCount = aTracks.count
        if let v = vTracks.first {
            let (natural, transform, rate, formats, minFrame, bitrate) = try await v.load(.naturalSize, .preferredTransform, .nominalFrameRate,
                                                                                  .formatDescriptions, .minFrameDuration, .estimatedDataRate)
            rotation = rotationDegrees(transform)
            pixel = rotation % 180 == 0 ? Size2(natural.width, natural.height) : Size2(natural.height, natural.width)
            fps = rate > 0 ? FrameRate.nearest(to: Double(rate)) : nil
            info.bitrate = Int64(bitrate)
            if let f = formats.first {
                codec = fourCC(CMFormatDescriptionGetMediaSubType(f))
                info.hasAlpha = hasAlpha(f)
                (primaries, transfer, matrix, depth) = colorTags(f)
                let ext = CMFormatDescriptionGetExtensions(f) as? [CFString: Any]
                info.colorPrimaries = ext?[kCMFormatDescriptionExtension_ColorPrimaries] as? String
                info.transferFunction = ext?[kCMFormatDescriptionExtension_TransferFunction] as? String
            }
            // VFR: the shortest frame is noticeably shorter than the nominal frame duration.
            if rate > 0, minFrame.isValid, minFrame.seconds > 0 {
                let nominal = 1 / Double(rate)
                info.isVariableFrameRate = abs(minFrame.seconds - nominal) / nominal > 0.05
            }
        }
        if let a = aTracks.first, let f = try await a.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee {
            info.audioSampleRate = asbd.mSampleRate
            info.audioChannels = Int(asbd.mChannelsPerFrame)
            info.audioCodec = fourCC(asbd.mFormatID)
        }
        var a = MediaAsset(name: name, kind: vTracks.isEmpty ? .audio : .video, url: url, duration: Time(cmTime: duration),
                           pixelSize: pixel, frameRate: fps, hasVideo: !vTracks.isEmpty, hasAudio: !aTracks.isEmpty,
                           contentHash: hash, fileSize: size, codec: codec, sourceRotation: rotation)
        a.techInfo = info
        a.colorPrimaries = primaries; a.transferFunction = transfer; a.yCbCrMatrix = matrix; a.bitDepth = depth
        return a
    }

    static func hasAlpha(_ f: CMFormatDescription) -> Bool {
        let ext = CMFormatDescriptionGetExtensions(f) as? [CFString: Any]
        if let d = ext?[kCMFormatDescriptionExtension_Depth] as? NSNumber, d.intValue == 32 { return true }
        if let c = ext?["ContainsAlphaChannel" as CFString] as? Bool, c { return true }
        return false
    }

    /// Probes an image sequence detected by `detectSequences`.
    public static func probeSequence(first url: URL, info seq: ImageSequenceInfo, fps: FrameRate = .fps30) throws -> MediaAsset {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { throw MediaProbeError.unsupported(url) }
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let dir = url.deletingLastPathComponent()
        let last = dir.appendingPathComponent(seq.fileName(seq.count - 1))
        var total: Int64 = 0
        for i in 0..<seq.count {
            total += ((try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(seq.fileName(i)).path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        let size0 = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let sizeL = ((try? FileManager.default.attributesOfItem(atPath: last.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let hash = String((contentHash(url, size: size0, mtime: nil) + contentHash(last, size: sizeL, mtime: nil)).prefix(24)) + "s\(seq.count)"
        let name = seq.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "_-. ")).isEmpty
            ? dir.lastPathComponent : seq.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "_-. "))
        var a = MediaAsset(name: name, kind: .video, url: url, duration: Time(ticks: fps.frameDuration.ticks * Int64(seq.count)), pixelSize: Size2(w, h),
                           frameRate: fps, hasVideo: true, hasAudio: false, contentHash: hash, fileSize: total, codec: seq.ext)
        a.conversion = .imageSequence
        a.sequence = seq
        var info = MediaTechInfo(); info.hasAlpha = (props[kCGImagePropertyHasAlpha] as? Bool) ?? false; info.container = seq.ext
        a.techInfo = info
        return a
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

    /// A file to import plus the folder chain it came from (relative to the dropped directory, incl. its own name).
    public struct ImportItem: Sendable, Equatable {
        public var url: URL
        public var folderPath: [String]
        public init(url: URL, folderPath: [String] = []) { self.url = url; self.folderPath = folderPath }
    }

    /// Expands folders (recursively) into importable files.
    public static func expand(_ urls: [URL]) -> [URL] { expandWithFolders(urls).map(\.url) }

    /// Like `expand`, keeping each file's folder structure (MI-002: "keeps its folder structure in the Media panel").
    public static func expandWithFolders(_ urls: [URL]) -> [ImportItem] {
        var out: [ImportItem] = []
        let fm = FileManager.default
        for u in urls {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue, !ProjectPackage.isPackage(u) {
                let root = u.standardizedFileURL.pathComponents
                let e = fm.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
                var files: [URL] = []
                while let f = e?.nextObject() as? URL { if isImportable(f) { files.append(f) } }
                files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                for f in files {
                    let comps = f.deletingLastPathComponent().standardizedFileURL.pathComponents
                    let rel = Array(comps.dropFirst(root.count))
                    out.append(ImportItem(url: f, folderPath: [u.lastPathComponent] + rel))
                }
            } else if isImportable(u) { out.append(ImportItem(url: u)) }
        }
        return out
    }

    public static func isImportable(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) || audioExtensions.contains(ext) || ffmpegVideoExtensions.contains(ext) { return true }
        if let t = UTType(filenameExtension: ext) { return t.conforms(to: .movie) || t.conforms(to: .audio) || t.conforms(to: .image) }
        return false
    }

    /// Camera naming (IMG_0001.JPG…) is a photo set, not an animation.
    static let cameraPrefixes = ["img_", "img", "dsc", "dscn", "dscf", "dsc_", "_dsc", "p", "pict", "gopr", "dji_", "mvi_", "photo"]

    /// Finds numbered image sequences (`shot_0001.png` … ≥ 10 contiguous frames, same folder/prefix/extension/padding).
    /// JPEG sequences additionally need ≥ 24 frames and a non-camera prefix. Returns sequences and the remaining files.
    public static func detectSequences(_ urls: [URL]) -> (sequences: [(first: URL, info: ImageSequenceInfo)], rest: [URL]) {
        struct Key: Hashable { let dir: String; let prefix: String; let ext: String; let digits: Int }
        var groups: [Key: [(Int, URL)]] = [:]
        var rest: [URL] = []
        let re = try! NSRegularExpression(pattern: #"^(.*?)(\d+)$"#)
        for u in urls {
            let ext = u.pathExtension.lowercased()
            let base = u.deletingPathExtension().lastPathComponent
            let ns = base as NSString
            guard sequenceExtensions.contains(ext), let m = re.firstMatch(in: base, range: NSRange(location: 0, length: ns.length)) else {
                rest.append(u); continue
            }
            let prefix = ns.substring(with: m.range(at: 1)), digits = ns.substring(with: m.range(at: 2))
            guard let n = Int(digits) else { rest.append(u); continue }
            let key = Key(dir: u.deletingLastPathComponent().path, prefix: prefix, ext: u.pathExtension, digits: digits.hasPrefix("0") ? digits.count : 0)
            groups[key, default: []].append((n, u))
        }
        var seqs: [(URL, ImageSequenceInfo)] = []
        for (k, items) in groups {
            let sorted = items.sorted { $0.0 < $1.0 }
            let isJPEG = ["jpg", "jpeg"].contains(k.ext.lowercased())
            let camera = cameraPrefixes.contains(k.prefix.lowercased())
            let minCount = isJPEG ? 24 : 10
            // longest contiguous runs
            var runStart = 0
            var i = 1
            func flush(_ a: Int, _ b: Int) {
                let run = Array(sorted[a..<b])
                if run.count >= minCount && !(isJPEG && camera) {
                    seqs.append((run[0].1, ImageSequenceInfo(prefix: k.prefix, digits: k.digits, firstIndex: run[0].0, count: run.count, ext: k.ext)))
                } else { rest += run.map(\.1) }
            }
            while i <= sorted.count {
                if i == sorted.count || sorted[i].0 != sorted[i - 1].0 + 1 { flush(runStart, i); runStart = i }
                i += 1
            }
        }
        seqs.sort { $0.0.path < $1.0.path }
        let order = Dictionary(urls.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        rest.sort { (order[$0] ?? 0) < (order[$1] ?? 0) }
        return (seqs, rest)
    }

    /// size + SHA-256 of the first and last 256 KiB: fast, stable across renames and moves (relinking matches on it).
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

/// Frame timing of animated images (GIF / APNG / WebP / HEICS) through ImageIO.
enum AnimatedImage {
    struct Timing { let delays: [Double]; var duration: Time { Time(delays.reduce(0, +)) }
        var fps: Double { let avg = delays.reduce(0, +) / Double(max(delays.count, 1)); return avg > 0 ? 1 / avg : 10 } }

    static func timing(_ src: CGImageSource) -> Timing? {
        let n = CGImageSourceGetCount(src)
        guard n > 1 else { return nil }
        var delays: [Double] = []
        for i in 0..<n { delays.append(delay(src, i)) }
        return Timing(delays: delays)
    }

    /// Per-frame delay; tiny delays (< 11 ms) are treated as 100 ms like browsers do.
    static func delay(_ src: CGImageSource, _ i: Int) -> Double {
        guard let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] else { return 0.1 }
        let dicts: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
        ]
        for (d, u, c) in dicts {
            guard let dict = p[d] as? [CFString: Any] else { continue }
            let v = (dict[u] as? NSNumber)?.doubleValue ?? (dict[c] as? NSNumber)?.doubleValue ?? 0.1
            return v < 0.011 ? 0.1 : v
        }
        return 0.1
    }
}
