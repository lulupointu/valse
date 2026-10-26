import SwiftUI
import MontageCore
import Perception

/// The Valse mark in the editor (owner, round 10: "the logo somewhere visible (though not distracting), maybe with a
/// nice animation when we open a project, a subtle waow effect").
///
/// At rest the mark is small, flat cream (the monochrome cut: one cream band with punched perforations), so it never
/// competes with the footage. When a project opens it draws itself in, in full colour, along the logo's own path (the
/// same geometry as the Home hero ribbon, `ValseRibbon.Logo`), then cools to the cream mark. Under 1.1 s, never
/// blocks input (no hit testing), once per project open, nothing per frame after it ends (the TimelineView only
/// exists while the intro runs), Reduce Motion / UI tests / screenshots: the cream mark simply appears.
///
/// Placement × intro is still the owner's call (TEMPORARY `ValseOptions.logo`, "Valse options" menu):
/// A title bar left (after the window buttons), draws in place; B the same, plus a film strip swiping across the
/// title bar (`ValseTitleSwipe`); C next to EditPilot / Export, draws in place.
@MainActor
final class ValseEditorIntro: ObservableObject {
    static let shared = ValseEditorIntro()
    /// Intro start (nil = at rest).
    @Published private(set) var start: Date?
    private var lastProject: ProjectID?
    static let drawIn = 0.75, cool = 0.3
    static var duration: Double { drawIn + cool }

    /// Plays the intro once for a newly opened project (a rebuilt editor view of the same project does not replay it).
    func projectOpened(_ id: ProjectID, reduceMotion: Bool) {
        guard id != lastProject else { return }
        lastProject = id
        guard ValseMotion.live(reduceMotion) else { start = nil; return }
        let now = Date()
        start = now
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.duration + 0.05))
            if self?.start == now { self?.start = nil }
        }
    }

    /// Intro phases at `elapsed` seconds: draw-in trim (0…1) and colour → cream (0…1).
    static func phase(_ elapsed: Double) -> (trim: Double, cream: Double) {
        (ValseMotion.easeInOut(elapsed / drawIn), ValseMotion.easeInOut((elapsed - drawIn + 0.05) / cool))
    }
}

/// The logo drawn from its centreline at any size: `height` tall, the band and loop scaled from the master
/// (film-turn-open.svg: 416 × 384.5 units, band 90). `trim` draws it in; `cream` blends the colour bands to the flat
/// cream cut.
struct ValseLogoDrawing: View {
    var height: CGFloat
    var trim: Double = 1
    var cream: Double = 1
    var background: Color = Theme.window
    static let aspect: CGFloat = 416 / 384.5
    var body: some View {
        let s = height / 384.5
        let loop = ValseRibbon.Loop(turnFromTrailing: (411 - 222.4) * s, bottom: 45 * s)
        ZStack {
            if cream < 1 {
                ValseRibbon(width: 90 * s, background: background, loop: loop, trim: trim).opacity(1 - cream)
            }
            if cream > 0 {
                ValseRibbon(width: 90 * s, background: background, loop: loop, trim: trim, mono: Theme.Valse.cream).opacity(cream)
            }
        }
        .frame(width: height * Self.aspect, height: height)
        .clipped()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// The small mark (title bar). Animated only while the intro runs.
struct ValseEditorMark: View {
    var height: CGFloat = 18
    @ObservedObject private var intro = ValseEditorIntro.shared
    @ObservedObject private var clock = ValseDebugClock.shared
    var body: some View {
        Group {
            if let t = clock.t {
                frame(t)   // review clock: intro from t = 0
            } else if let start = intro.start {
                SwiftUI.TimelineView(.animation) { tl in frame(tl.date.timeIntervalSince(start)) }
            } else {
                ValseLogoDrawing(height: height, background: Theme.window).opacity(0.92)
            }
        }
    }

    private func frame(_ elapsed: Double) -> some View {
        let p = ValseEditorIntro.phase(elapsed)
        return ValseLogoDrawing(height: height, trim: p.trim, cream: p.cream, background: Theme.window)
            .opacity(0.92 + 0.08 * (1 - p.cream))
    }
}

/// Variant B: a film strip (the ribbon's four bands, perforated edges) swipes across the whole title bar behind its
/// controls: the head runs left → right (0–0.55 s), the tail follows it out (0.3–0.85 s), and the small mark draws
/// itself in at its spot meanwhile. Drawn in the title bar itself: an overlay across the editor would be hidden by
/// the panels (each in its own hosting view, the player and timeline are Metal layers).
struct ValseTitleSwipe: View {
    @ObservedObject private var intro = ValseEditorIntro.shared
    @ObservedObject private var clock = ValseDebugClock.shared
    var band: CGFloat = 10
    var body: some View {
        if let t = clock.t {
            if t < 0.9 { strip(t) }
        } else if let start = intro.start {
            SwiftUI.TimelineView(.animation) { tl in strip(tl.date.timeIntervalSince(start)) }
        }
    }

    private func strip(_ t: Double) -> some View {
        let head = ValseMotion.easeInOut(t / 0.55), tail = ValseMotion.easeInOut((t - 0.3) / 0.55)
        return Canvas { ctx, size in
            let x0 = size.width * CGFloat(tail), x1 = size.width * CGFloat(head)
            guard x1 > x0 + 1 else { return }
            let s = band / 36, y = size.height / 2
            for (col, w) in zip(Theme.Valse.bands, [36, 20, 12, 4].map { $0 * s }) {
                ctx.fill(Path(CGRect(x: x0, y: y - w / 2, width: x1 - x0, height: w)), with: .color(col))
            }
            // perforations punched along both burgundy edges, as on the logo's film
            let d = band / 2 - 4 * s
            for edge in [y - d, y + d] {
                var p = Path(); p.move(to: CGPoint(x: x0, y: edge)); p.addLine(to: CGPoint(x: x1, y: edge))
                ctx.stroke(p, with: .color(Theme.window), style: StrokeStyle(lineWidth: 3.4 * s, dash: [4.6 * s, 3.9 * s]))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
