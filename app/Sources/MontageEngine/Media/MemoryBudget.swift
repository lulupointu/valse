import Foundation
import MontageCore

/// Memory policy for 8 GB machines (STACK.md §5.2: the VideoToolbox decoder dominates memory, ≈300 MB per 4K HEVC
/// stream). Used to pick preview resolution, force proxies and bound caches.
public enum MemoryBudget {
    /// `MONTAGE_SIMULATE_RAM_GB=8` pretends to be an 8 GB machine (scripts/perf.sh --air, docs/TESTING.md §3).
    public static let physicalMemory: UInt64 = {
        if let gb = ProcessInfo.processInfo.environment["MONTAGE_SIMULATE_RAM_GB"].flatMap(Double.init), gb > 0 {
            return UInt64(gb * 1024 * 1024 * 1024)
        }
        return ProcessInfo.processInfo.physicalMemory
    }()
    /// Base MacBook Air class.
    public static let isLowMemoryMachine = physicalMemory <= 8 * 1024 * 1024 * 1024

    /// Bytes we allow decoders to hold during preview (≈15 % of RAM, max 2 GB).
    public static var decoderBudget: UInt64 { min(physicalMemory * 15 / 100, 2 * 1024 * 1024 * 1024) }

    /// Estimated decoder cost of one stream (surfaces in flight × frame size, plus fixed overhead).
    public static func decoderCost(_ size: Size2) -> UInt64 {
        let frame = size.width * size.height * 1.5      // 4:2:0
        return UInt64(frame * 16 + 20 * 1024 * 1024)    // ~16 surfaces + session overhead (≈300 MB at 4K)
    }

    /// Whether the given simultaneously-decoded originals exceed the budget (→ use proxies / lower preview).
    public static func exceedsBudget(activeStreams: [Size2]) -> Bool {
        activeStreams.reduce(UInt64(0)) { $0 + decoderCost($1) } > decoderBudget
    }

    /// Idle intermediate textures the compositor's `TexturePool` keeps for reuse (≈ 8 / 12 1080p half-float textures: about one frame's working set, see FrameScratch).
    public static var texturePoolIdleBytes: Int { isLowMemoryMachine ? 128 << 20 : 192 << 20 }

    /// Per text texture cache (static images, glyph atlases) of `TextRasterizer`.
    public static var textCacheBytes: Int { isLowMemoryMachine ? 96 << 20 : 192 << 20 }

    /// Still-image textures (`ImageTextureCache`).
    public static var imageCacheBytes: Int { isLowMemoryMachine ? 128 << 20 : 256 << 20 }

    /// Decoded source frames a preview keeps for instant paused re-renders (`RenderState`, newest first).
    public static var recentSourceBytes: Int { isLowMemoryMachine ? 48 << 20 : 96 << 20 }

    /// Thumbnail memory cache size.
    public static var thumbnailCacheBytes: Int { isLowMemoryMachine ? 64 << 20 : 160 << 20 }

    /// Proxy needed for smooth editing (auto policy).
    public static func wantsProxy(_ a: MediaAsset) -> Bool {
        guard a.kind == .video, a.hasVideo else { return false }
        let long = max(a.pixelSize.width, a.pixelSize.height)
        if long > 1920 { return true }
        if (a.frameRate?.fps ?? 30) > 31 && long > 1280 { return true }
        return isLowMemoryMachine && long > 1280
    }
}
