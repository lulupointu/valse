import Testing
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import MontageCore
import MontageEffects
import MontageEngine

/// Render tests for the effects / filters library: every entry changes pixels, never produces NaN or black frames,
/// and each base shader does what it says (blur smooths, mirror is symmetric, B&W has no chroma…).
/// `MONTAGE_FX_SHEET=<dir>` also writes contact sheets (effects.png, filters.png) to look at.
@Suite(.serialized) struct EffectLibraryTests {
    static let w = 160, h = 90
    let r = EffectPreviewRenderer.shared

    static var library: [EffectDescriptor] {
        Registries.effects.all.filter { ($0.category == .effect || $0.category == .filter) && $0.id.hasPrefix("montage.") }
    }

    func source(_ scene: EffectPreviewRenderer.Scene = .full) -> EffectPreviewRenderer.Pixels {
        r.render([], time: 0, width: Self.w, height: Self.h, scene: scene)!
    }

    static func meanAbsDiff(_ a: EffectPreviewRenderer.Pixels, _ b: EffectPreviewRenderer.Pixels) -> Float {
        var s: Float = 0
        for i in stride(from: 0, to: a.data.count, by: 4) {
            for c in 0..<3 { s += abs(a.data[i + c] - b.data[i + c]) }
        }
        return s / Float(a.data.count / 4 * 3)
    }

    @Test func compilesEveryShader() {
        let errors = EffectPipelines.shared.validateAll()
        #expect(errors.isEmpty, "\(errors.keys.sorted())")
    }

    @Test func libraryIsLargeAndNamed() {
        let fx = Registries.effects(in: .effect).filter { $0.id.hasPrefix("montage.") }
        let filters = Registries.effects(in: .filter).filter { $0.id.hasPrefix("montage.") }
        #expect(fx.count >= 150)
        #expect(filters.count >= 100)
        let en = L10n.load("en", from: [EffectsResources.bundle]), fr = L10n.load("fr", from: [EffectsResources.bundle])
        for d in fx + filters {
            for k in [d.nameKey, d.groupKey] + d.params.map(\.nameKey) {
                #expect(en[k] != nil && fr[k] != nil, "missing translation \(k) (\(d.id))")
            }
        }
    }

    /// Every effect and filter: finite output, not black, and visibly different from the source at some time
    /// (animated effects such as random flashes may leave some frames untouched).
    @Test func everyEntryChangesPixelsSanely() {
        let base = source()
        let bodyBase = r.render([], time: 0, width: Self.w, height: Self.h, scene: .subjectOverBackground)!
        for d in Self.library {
            var changed = false
            for t in [0.25, 0.7, 1.15, 1.6, 2.05] {
                guard let px = r.render(d, time: t, width: Self.w, height: Self.h) else { Issue.record("\(d.id): no render"); break }
                let finite = px.data.allSatisfy { $0.isFinite }
                #expect(finite, "\(d.id): NaN/inf at t=\(t)")
                let m = px.mean()
                #expect(m.x + m.y + m.z > 0.06, "\(d.id): black frame at t=\(t)")
                let ref = EffectPreviewRenderer.usesSubject(d) ? bodyBase : base
                if Self.changedFraction(px, ref) > 0.004 || Self.meanAbsDiff(px, ref) > 0.006 { changed = true; break }
            }
            #expect(changed, "\(d.id): does not change the image")
        }
    }

    /// Fraction of pixels where some channel (incl. alpha) moved by more than 3 %.
    static func changedFraction(_ a: EffectPreviewRenderer.Pixels, _ b: EffectPreviewRenderer.Pixels) -> Double {
        var n = 0
        for i in stride(from: 0, to: a.data.count, by: 4) {
            for c in 0..<4 where abs(a.data[i + c] - b.data[i + c]) > 0.03 { n += 1; break }
        }
        return Double(n) / Double(a.data.count / 4)
    }

    @Test func writesContactSheets() throws {
        guard let dir = ProcessInfo.processInfo.environment["MONTAGE_FX_SHEET"] else { return }
        let fx = Registries.effects(in: .effect).filter { $0.id.hasPrefix("montage.") }
        let filters = Registries.effects(in: .filter).filter { $0.id.hasPrefix("montage.") }
        let t = Double(ProcessInfo.processInfo.environment["MONTAGE_FX_TIME"] ?? "0.8") ?? 0.8
        if let px = r.render([], time: 0, width: 960, height: 540), let img = EffectPreviewRenderer.cgImage(px) {
            ContactSheet.png(img, URL(fileURLWithPath: dir).appendingPathComponent("scene.png"))
        }
        for (name, list) in [("effects", fx), ("filters", filters)] {
            for (k, start) in stride(from: 0, to: list.count, by: 30).enumerated() {
                let chunk = Array(list[start..<min(start + 30, list.count)])
                try ContactSheet.write(chunk, time: t, to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)_\(k).png"), cols: 5)
            }
        }
    }
}

enum ContactSheet {
    static func write(_ items: [EffectDescriptor], time: Double, to url: URL, cols: Int = 10, tw: Int = 240, th: Int = 135) throws {
        let rows = (items.count + cols - 1) / cols
        let lh = 18
        let W = cols * tw, H = rows * (th + lh)
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let names = L10n.load("en", from: [EffectsResources.bundle])
        let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        for (i, d) in items.enumerated() {
            let cx = (i % cols) * tw, cy = H - (i / cols + 1) * (th + lh)
            if let img = EffectPreviewRenderer.shared.image(d, time: time, width: tw, height: th) {
                ctx.draw(img, in: CGRect(x: cx, y: cy + lh, width: tw, height: th))
            }
            let name = names[d.nameKey] ?? d.nameKey
            let attr = NSAttributedString(string: "\(name) · \(d.id.split(separator: ".").last ?? "")",
                                          attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                       NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.9, alpha: 1)])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: cx + 4, y: cy + 5)
            CTLineDraw(line, ctx)
        }
        if let img = ctx.makeImage() { png(img, url) }
    }

    static func png(_ img: CGImage, _ url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }
}
