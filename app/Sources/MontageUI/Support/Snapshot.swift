import AppKit
import ImageIO

/// Window snapshots without Screen Recording permission: renders the SwiftUI/AppKit chrome with `cacheDisplay` and
/// composites the Metal views (player, timeline) from their own offscreen renders. Used by `--snapshot` and
/// scripts/screenshot.sh as a fallback to `screencapture -l`.
@MainActor
public final class SnapshotRegistry {
    public static let shared = SnapshotRegistry()
    weak var player: PlayerView?
    weak var timeline: TimelineView?

    public func snapshot(window: NSWindow) -> CGImage? {
        guard let content = window.contentView else { return nil }
        let bounds = content.bounds
        guard let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        content.cacheDisplay(in: bounds, to: rep)
        guard let base = rep.cgImage else { return nil }
        let scale = CGFloat(base.width) / bounds.width
        guard let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return base }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        for view in [player as NSView?, timeline as NSView?].compactMap({ $0 }) where view.window === window {
            let img = (view as? PlayerView)?.snapshot() ?? (view as? TimelineView)?.snapshot()
            guard let img else { continue }
            let r = view.convert(view.bounds, to: content)
            // content view is flipped? convert to bottom-left origin for CG
            let y = content.isFlipped ? bounds.height - r.maxY : r.minY
            ctx.draw(img, in: CGRect(x: r.minX * scale, y: y * scale, width: r.width * scale, height: r.height * scale))
        }
        return ctx.makeImage()
    }

    public func writePNG(window: NSWindow, to url: URL) -> Bool {
        guard let img = snapshot(window: window),
              let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(d, img, nil)
        return CGImageDestinationFinalize(d)
    }
}
