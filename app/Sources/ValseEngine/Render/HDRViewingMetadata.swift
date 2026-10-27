@preconcurrency import AVFoundation
import Foundation
import ValseCore

/// Ambient viewing environment of HLG footage (C1).
///
/// iPhone HLG / Dolby Vision clips carry an ambient viewing environment (HEVC SEI D.3.39 / `amve`, 8 bytes; Apple
/// captures: 314 lux, D65). Apple's players hand it to Core Animation (`CAEDRMetadata.hlg(ambientViewingEnvironment:)`),
/// which then renders the HLG signal for a bright surround: about 0.65 × the plain-HLG luminance in the mid-tones
/// (measured on screen with ScreenCaptureKit, any ambient above ~5 lux gives the same rendering). Without it an HLG
/// project previews ≈ 1.5 × brighter than QuickTime / Photos show the same clip, and an exported HLG file plays brighter
/// than its source. The preview layer and the HLG export both carry the footage's value.
public final class HDRViewingMetadata: @unchecked Sendable {
    public static let shared = HDRViewingMetadata()

    private let lock = NSLock()
    private var cache: [String: Data?] = [:]

    /// Apple's default for its captures (CAEDRMetadata.h): 314 lux, D65 (x 0.3127, y 0.3290).
    public static let appleCaptureDefault = Data([0x00, 0x2F, 0xE9, 0xA0, 0x3D, 0x13, 0x40, 0x42])

    /// Ambient illuminance (lux) of an 8-byte ambient viewing environment.
    public static func illuminance(_ ave: Data) -> Double? {
        guard ave.count >= 8 else { return nil }
        let b = [UInt8](ave.prefix(4))
        return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])) / 10000
    }

    /// Cached value for an asset (nil = not loaded yet; .some(nil) = the file has none).
    public func cached(_ asset: MediaAsset) -> Data?? { lock.withLock { cache[asset.contentHash] } }

    /// The asset's ambient viewing environment (format description extension), loaded once per content hash.
    public func ambientViewingEnvironment(_ asset: MediaAsset) async -> Data? {
        if let c = cached(asset) { return c }
        var ave: Data?
        if asset.kind == .video, asset.transfer == .hlg,
           let track = try? await AVURLAsset(url: asset.url).loadTracks(withMediaType: .video).first,
           let fd = try? await track.load(.formatDescriptions).first {
            ave = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_AmbientViewingEnvironment) as? Data
            if let a = ave, a.count != 8 { ave = nil }
        }
        let v = ave
        lock.withLock { cache[asset.contentHash] = .some(v) }
        return v
    }

    /// The HLG footage of `project` in timeline order (visual tracks): the assets whose ambient environment applies.
    static func hlgAssets(_ project: Project) -> [MediaAsset] {
        var seen = Set<MediaID>(), out: [MediaAsset] = []
        for t in project.timeline.tracks where t.kind.isVisual {
            for c in t.clips.sorted(by: { $0.start < $1.start }) {
                guard let id = c.mediaID, !seen.contains(id), let a = project.asset(id), a.kind == .video, a.transfer == .hlg else { continue }
                seen.insert(id); out.append(a)
            }
        }
        return out
    }

    /// Ambient viewing environment for an HLG project's preview / export: the first HLG clip's on the timeline that
    /// carries one (iPhone footage shares Apple's default), nil when no HLG footage has one.
    public func ambientViewingEnvironment(for project: Project) async -> Data? {
        for a in Self.hlgAssets(project) { if let v = await ambientViewingEnvironment(a) { return v } }
        return nil
    }

    /// Synchronous variant from the cache only (nil when not loaded yet).
    public func cachedAmbientViewingEnvironment(for project: Project) -> Data? {
        for a in Self.hlgAssets(project) { if case .some(.some(let v)) = cached(a) { return v } }
        return nil
    }
}
