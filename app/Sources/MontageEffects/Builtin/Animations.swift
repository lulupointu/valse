import Foundation
import MontageCore

/// "Animation" inspector tab: In / Out / Combo for video, images, text and stickers.
public enum BuiltinAnimations {
    static func ease(_ x: Double) -> Double { let t = min(max(x, 0), 1); return 1 - pow(1 - t, 3) }  // easeOutCubic

    public static let all: [AnimationDescriptor] = [
        // In: progress 0 → 1 = hidden → shown
        .init(id: "montage.anim.in.fade", phase: .in, nameKey: "anim.fadeIn", symbol: "circle.lefthalf.filled") { p, s in
            s.opacity *= ease(p)
        },
        .init(id: "montage.anim.in.slideUp", phase: .in, nameKey: "anim.slideUp", symbol: "arrow.up") { p, s in
            s.transform.position.y += (1 - ease(p)) * 0.25; s.opacity *= ease(p)
        },
        .init(id: "montage.anim.in.slideRight", phase: .in, nameKey: "anim.slideRight", symbol: "arrow.right") { p, s in
            s.transform.position.x -= (1 - ease(p)) * 0.3; s.opacity *= ease(p)
        },
        .init(id: "montage.anim.in.zoom", phase: .in, nameKey: "anim.zoomIn", symbol: "plus.magnifyingglass") { p, s in
            let k = 0.6 + 0.4 * ease(p); s.transform.scale = s.transform.scale * k; s.opacity *= ease(p)
        },
        .init(id: "montage.anim.in.spin", phase: .in, nameKey: "anim.spinIn", symbol: "arrow.clockwise") { p, s in
            s.transform.rotation -= (1 - ease(p)) * 180; s.transform.scale = s.transform.scale * ease(p)
        },
        // Out: progress 0 → 1 = shown → hidden
        .init(id: "montage.anim.out.fade", phase: .out, nameKey: "anim.fadeOut", symbol: "circle.righthalf.filled") { p, s in
            s.opacity *= 1 - ease(p)
        },
        .init(id: "montage.anim.out.slideDown", phase: .out, nameKey: "anim.slideDown", symbol: "arrow.down") { p, s in
            s.transform.position.y += ease(p) * 0.25; s.opacity *= 1 - ease(p)
        },
        .init(id: "montage.anim.out.zoom", phase: .out, nameKey: "anim.zoomOut", symbol: "minus.magnifyingglass") { p, s in
            s.transform.scale = s.transform.scale * (1 - 0.4 * ease(p)); s.opacity *= 1 - ease(p)
        },
        // Combo: progress loops 0 → 1 over the animation duration
        .init(id: "montage.anim.combo.pulse", phase: .combo, nameKey: "anim.pulse", symbol: "heart",
              defaultDuration: Time(1)) { p, s in
            let k = 1 + 0.06 * sin(p * 2 * .pi); s.transform.scale = s.transform.scale * k
        },
        .init(id: "montage.anim.combo.swing", phase: .combo, nameKey: "anim.swing", symbol: "metronome",
              defaultDuration: Time(1.2)) { p, s in
            s.transform.rotation += 8 * sin(p * 2 * .pi)
        },
    ]
}
