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
    /// Transparent AppKit overlay drawn over the player (canvas handles, guides); composited after the Metal views.
    weak var playerOverlay: NSView?
    /// Frame (content coordinates, top-left origin) of an in-window modal (export dialog) drawn by SwiftUI above the
    /// Metal views: when set, the Metal views are dimmed like the modal backdrop and the modal is redrawn on top.
    public var modalFrame: CGRect?

    public func snapshot(window: NSWindow) -> CGImage? {
        guard let content = window.contentView else { return nil }
        let bounds = content.bounds
        guard let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        let hidden = Self.hideBackdrops(content)
        content.cacheDisplay(in: bounds, to: rep)
        hidden.forEach { $0.isHidden = false }
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
        if let o = playerOverlay, o.window === window, let rep = o.bitmapImageRepForCachingDisplay(in: o.bounds) {
            o.cacheDisplay(in: o.bounds, to: rep)
            if let img = rep.cgImage {
                let r = o.convert(o.bounds, to: content)
                let y = content.isFlipped ? bounds.height - r.maxY : r.minY
                ctx.draw(img, in: CGRect(x: r.minX * scale, y: y * scale, width: r.width * scale, height: r.height * scale))
            }
        }
        if let m = modalFrame {
            for view in [player as NSView?, timeline as NSView?].compactMap({ $0 }) where view.window === window {
                let r = view.convert(view.bounds, to: content)
                let y = content.isFlipped ? bounds.height - r.maxY : r.minY
                ctx.setFillColor(CGColor(gray: 0, alpha: 0.5))
                ctx.fill(CGRect(x: r.minX * scale, y: y * scale, width: r.width * scale, height: r.height * scale))
            }
            let rect = CGRect(x: m.minX * scale, y: (bounds.height - m.maxY) * scale, width: m.width * scale, height: m.height * scale)
            ctx.saveGState(); ctx.clip(to: rect)
            ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    /// macOS 26 scroll views carry a "scroll pocket" (edge blur: BackdropView / PortalView) that `cacheDisplay` can't
    /// render and paints opaque white over the whole scroll view: hide those views while snapshotting.
    static func hideBackdrops(_ v: NSView) -> [NSView] {
        var out: [NSView] = []
        for sub in v.subviews {
            let name = String(describing: type(of: sub))
            if !sub.isHidden, name == "NSScrollPocket" || name == "BackdropView" || name == "PortalView" {
                sub.isHidden = true; out.append(sub)
            } else {
                out += hideBackdrops(sub)
            }
        }
        return out
    }

    public func writePNG(window: NSWindow, to url: URL) -> Bool {
        guard let img = snapshot(window: window),
              let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(d, img, nil)
        return CGImageDestinationFinalize(d)
    }
}
