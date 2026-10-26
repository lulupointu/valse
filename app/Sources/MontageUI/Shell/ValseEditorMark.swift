import SwiftUI
import MontageCore

/// The Valse mark in the editor (owner, rounds 10–12): the full-colour logo and the cream "Valse" wordmark, centred in
/// the title bar (round 11 variant B, picked in round 12). Always in its 80s colours (never a single tint).
///
/// When a project opens the mark draws itself in along the logo's own path (the Home hero ribbon geometry,
/// `ValseRibbon.Logo`): 0.8 s, never blocks input (no hit testing), once per project open, nothing per frame after it
/// ends (the TimelineView exists only while it runs). Reduce Motion / UI tests / screenshots: it simply appears.
@MainActor
final class ValseEditorIntro: ObservableObject {
    static let shared = ValseEditorIntro()
    /// Intro start (nil = at rest).
    @Published private(set) var start: Date?
    private var lastProject: ProjectID?
    static let drawIn = 0.8

    /// Plays the intro once for a newly opened project (a rebuilt editor view of the same project does not replay it).
    func projectOpened(_ id: ProjectID, reduceMotion: Bool) {
        guard id != lastProject else { return }
        lastProject = id
        guard ValseMotion.live(reduceMotion) else { start = nil; return }
        let now = Date()
        start = now
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.drawIn + 0.1))
            if self?.start == now { self?.start = nil }
        }
    }

    /// Draw-in trim (0…1) at `elapsed` seconds.
    static func trim(_ elapsed: Double) -> Double { ValseMotion.easeInOut(elapsed / drawIn) }
}

/// The logo drawn from its centreline at any size, in full colour: `height` tall, the band and loop scaled from the
/// master (film-turn-open.svg: 416 × 384.5 units, band 90). `trim` draws it in. `background` = the colour the
/// perforations are punched in (the surface it sits on).
struct ValseLogoDrawing: View {
    var height: CGFloat
    var trim: Double = 1
    var background: Color = Theme.window
    static let aspect: CGFloat = 416 / 384.5
    var body: some View {
        let s = height / 384.5
        ValseRibbon(width: 90 * s, background: background, loop: .init(turnFromTrailing: (411 - 222.4) * s, bottom: 45 * s), trim: trim)
            .frame(width: height * Self.aspect, height: height)
            .clipped()
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

/// The title-bar lockup: the mark (drawing itself in on project open) and the cream "Valse" wordmark.
struct ValseEditorMark: View {
    var height: CGFloat = 24
    @ObservedObject private var intro = ValseEditorIntro.shared
    @ObservedObject private var clock = ValseDebugClock.shared
    var body: some View {
        HStack(spacing: 7) {
            Group {
                if let t = clock.t {
                    ValseLogoDrawing(height: height, trim: ValseEditorIntro.trim(t))   // review clock: intro from t = 0
                } else if let start = intro.start {
                    SwiftUI.TimelineView(.animation) { tl in
                        ValseLogoDrawing(height: height, trim: ValseEditorIntro.trim(tl.date.timeIntervalSince(start)))
                    }
                } else {
                    ValseLogoDrawing(height: height)
                }
            }
            Text(verbatim: "Valse").font(.system(size: height * 0.68, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.Valse.cream)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
