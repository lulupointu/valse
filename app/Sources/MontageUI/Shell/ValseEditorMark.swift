import SwiftUI
import AppKit
import MontageCore
import Perception

/// The Valse mark in the editor (owner, rounds 10–11: visible but not distracting, the logo drawing itself in when a
/// project opens, quick, subtle; round 11: it keeps its 80s colours at rest, and it must be seen more).
///
/// At rest the mark is the full-colour logo (burgundy film edges, mustard, orange, teal), never a single tint. When a
/// project opens it draws itself in along the logo's own path (the Home hero ribbon geometry, `ValseRibbon.Logo`).
/// About a second, never blocks input (no hit testing, the flight's window ignores the mouse), once per project open,
/// nothing per frame after it ends (the TimelineViews exist only while it runs). Reduce Motion / UI tests /
/// screenshots: the mark simply appears.
///
/// Placement × entrance is still the owner's call (TEMPORARY `ValseOptions.logo`, "Valse options" menu):
/// A big mark at the left of the title bar; B mark + "Valse" wordmark centred in the title bar, the project chip moves
/// left; C as B, the logo first draws itself large over the editor and flies into its place; D mark + wordmark at the
/// left (the Home sidebar lockup), the project name stays centred.
@MainActor
final class ValseEditorIntro: ObservableObject {
    static let shared = ValseEditorIntro()
    /// Intro start (nil = at rest).
    @Published private(set) var start: Date?
    private var lastProject: ProjectID?
    /// The title-bar mark's frame (window content coordinates, top-left origin): where the C flight lands.
    var markFrame: CGRect = .zero
    static let drawIn = 0.8
    /// Variant C: drawn large (0–0.6 s), then flies into the title bar (0.6–1.1 s).
    static let flightDraw = 0.6, flightEnd = 1.1

    /// Plays the intro once for a newly opened project (a rebuilt editor view of the same project does not replay it).
    func projectOpened(_ id: ProjectID, reduceMotion: Bool, window: NSWindow?, flight: Bool) {
        guard id != lastProject else { return }
        lastProject = id
        guard ValseMotion.live(reduceMotion) else { start = nil; return }
        let now = Date()
        start = now
        if flight, let window { ValseIntroFlight.play(over: window) }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds((flight ? Self.flightEnd : Self.drawIn) + 0.1))
            if self?.start == now { self?.start = nil }
        }
    }

    /// Draw-in trim (0…1) of the in-place intro at `elapsed` seconds.
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

/// The title-bar mark (optionally with the cream "Valse" wordmark). Animated only while the intro runs.
struct ValseEditorMark: View {
    var height: CGFloat = 22
    var wordmark = false
    /// Variant C: the flight draws the logo; this mark appears when the flight lands.
    var landsFromFlight = false
    @ObservedObject private var intro = ValseEditorIntro.shared
    @ObservedObject private var clock = ValseDebugClock.shared
    var body: some View {
        HStack(spacing: 7) {
            Group {
                if let t = clock.t {
                    mark(t)   // review clock: intro from t = 0
                } else if let start = intro.start {
                    SwiftUI.TimelineView(.animation) { tl in mark(tl.date.timeIntervalSince(start)) }
                } else {
                    ValseLogoDrawing(height: height)
                }
            }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { ValseEditorIntro.shared.markFrame = $0 }
            if wordmark {
                Text(verbatim: "Valse").font(.system(size: height * 0.68, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.Valse.cream)
                    .opacity(wordmarkOpacity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(true)
    }

    private var wordmarkOpacity: Double {
        let elapsed = clock.t ?? intro.start.map { Date().timeIntervalSince($0) } ?? 99
        return landsFromFlight ? (elapsed >= ValseEditorIntro.flightEnd ? 1 : 0) : 1
    }

    @ViewBuilder private func mark(_ elapsed: Double) -> some View {
        if landsFromFlight {
            ValseLogoDrawing(height: height).opacity(elapsed >= ValseEditorIntro.flightEnd ? 1 : 0)
        } else {
            ValseLogoDrawing(height: height, trim: ValseEditorIntro.trim(elapsed))
        }
    }
}

/// Variant C: a borderless, transparent child window over the editor window (the only layer that really sits above
/// the panels: each panel is its own hosting view and the player / timeline are Metal layers). It ignores the mouse,
/// never becomes key, and is removed after the flight (1.1 s) or when the editor window closes.
@MainActor
enum ValseIntroFlight {
    static let identifier = NSUserInterfaceItemIdentifier("valse.introFlight")
    private static weak var current: NSWindow?
    /// Review recordings play the clock-driven flight once.
    static var playedForReview = false

    static func play(over parent: NSWindow) {
        current.map { parent.removeChildWindow($0); $0.orderOut(nil) }
        let w = NSWindow(contentRect: parent.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.identifier = identifier
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: ValseFlightView(windowSize: parent.frame.size))
        host.frame = CGRect(origin: .zero, size: parent.frame.size)
        w.contentView = host
        parent.addChildWindow(w, ordered: .above)
        current = w
        // review recordings drive the clock themselves and quit at the end; normal use: gone after the flight
        guard !ValseDebugClock.shared.active else { return }
        let token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { _ in
            MainActor.assumeIsolated { remove(w, from: parent) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + ValseEditorIntro.flightEnd + 0.15) {
            MainActor.assumeIsolated {
                remove(w, from: parent)
                NotificationCenter.default.removeObserver(token)
            }
        }
    }

    private static func remove(_ w: NSWindow, from parent: NSWindow) {
        parent.removeChildWindow(w)
        w.orderOut(nil)
        if current === w { current = nil }
    }
}

/// The flight: the logo draws itself large near the centre of the window, then shrinks and flies into the title-bar
/// mark (`ValseEditorIntro.markFrame`). Flat: no glow, no blur, no shadow.
struct ValseFlightView: View {
    let windowSize: CGSize
    @ObservedObject private var intro = ValseEditorIntro.shared
    @ObservedObject private var clock = ValseDebugClock.shared
    var body: some View {
        Group {
            if let t = clock.t {
                frame(t)
            } else if let start = intro.start {
                SwiftUI.TimelineView(.animation) { tl in frame(tl.date.timeIntervalSince(start)) }
            }
        }
        .frame(width: windowSize.width, height: windowSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    @ViewBuilder private func frame(_ t: Double) -> some View {
        if t < ValseEditorIntro.flightEnd {
            let big: CGFloat = min(170, windowSize.height * 0.22)
            let trim = ValseMotion.easeInOut(t / ValseEditorIntro.flightDraw)
            let f = ValseMotion.easeInOut((t - ValseEditorIntro.flightDraw) / (ValseEditorIntro.flightEnd - ValseEditorIntro.flightDraw))
            let target = intro.markFrame == .zero ? CGRect(x: windowSize.width / 2 - 12, y: 7, width: 24, height: 22) : intro.markFrame
            let from = CGPoint(x: windowSize.width / 2, y: windowSize.height * 0.36)
            let to = CGPoint(x: target.midX, y: target.midY)
            let h = big + (target.height - big) * CGFloat(f)
            ValseLogoDrawing(height: h, trim: trim, background: Theme.panel)
                .position(x: from.x + (to.x - from.x) * CGFloat(f), y: from.y + (to.y - from.y) * CGFloat(f))
        }
    }
}
