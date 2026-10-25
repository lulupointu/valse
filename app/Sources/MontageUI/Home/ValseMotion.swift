import SwiftUI
import AppKit

/// Valse Home motion (VALSE-HOME round 3): explicit, time-driven micro-animations so they can be scrubbed frame by
/// frame for review videos, run on `TimelineView` only while moving, stop when the window is inactive, and collapse to
/// their final frame under Reduce Motion, in UI tests and in plain `--snapshot` screenshots (deterministic baselines).
///
/// Debug only (review videos, never set in normal use):
///   VALSE_DEBUG_HOVER=<id>       force one hover (hero, card0, feature0, feature1, feature2, nav.<id>); any value
///                                also ignores the real pointer.
///   VALSE_DEBUG_ANIM_T=<s>       freeze the clock at t seconds (intro starts at 0, hovers / selections at HOVER_AT).
///   VALSE_DEBUG_HOVER_AT=<s>     when the forced hover / selection / view-mode change happens (default 0).
///   VALSE_DEBUG_FRAMES=<dir>,<t0>,<t1>,<fps>   render frames t0…t1 of the clock into dir/f0000.png… then write dir/done.

/// Radii (rounder than the editor's).
enum ValseShape {
    static let control: CGFloat = 9
    static let card: CGFloat = 14
    static let hero: CGFloat = 20
}

enum ValseDebugHover {
    static let target = ProcessInfo.processInfo.environment["VALSE_DEBUG_HOVER"] ?? ""
    static func forced(_ id: String) -> Bool { !id.isEmpty && target == id }
    /// Any value set: ignore the real pointer (offscreen screenshots otherwise pick up stray hovers).
    static let ignoreReal = !target.isEmpty
    static func merge(_ real: Bool, _ id: String) -> Bool { (real && !ignoreReal) || forced(id) }
}

/// The review clock. `t == nil` in normal use.
@MainActor
final class ValseDebugClock: ObservableObject {
    static let shared = ValseDebugClock()
    @Published var t: Double? = ProcessInfo.processInfo.environment["VALSE_DEBUG_ANIM_T"].flatMap(Double.init)
    let hoverAt: Double = ProcessInfo.processInfo.environment["VALSE_DEBUG_HOVER_AT"].flatMap(Double.init) ?? 0
    var active: Bool { t != nil }

    /// Renders the requested frame range of the clock, one PNG per frame (review videos).
    func recordIfRequested() async {
        guard let spec = ProcessInfo.processInfo.environment["VALSE_DEBUG_FRAMES"] else { return }
        let p = spec.split(separator: ",").map(String.init)
        guard p.count == 4, let t0 = Double(p[1]), let t1 = Double(p[2]), let fps = Double(p[3]) else { return }
        let dir = URL(fileURLWithPath: p[0])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        t = t0
        try? await Task.sleep(for: .seconds(2))   // covers, layout
        guard let window = NSApp.windows.first(where: { $0.contentView != nil && $0.frame.width > 600 }) else { return }
        let n = Int(((t1 - t0) * fps).rounded())
        for i in 0...n {
            t = t0 + Double(i) / fps
            try? await Task.sleep(for: .milliseconds(70))
            _ = SnapshotRegistry.shared.writePNG(window: window, to: dir.appendingPathComponent(String(format: "f%04d.png", i)))
        }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("done").path, contents: Data())
    }
}

enum ValseMotion {
    /// UI tests and plain screenshots render the settled frame (deterministic baselines).
    static let isStaticRun: Bool = {
        let a = CommandLine.arguments
        return a.contains("--uitest") || (a.contains("--snapshot") && ProcessInfo.processInfo.environment["VALSE_DEBUG_FRAMES"] == nil
                                          && ProcessInfo.processInfo.environment["VALSE_DEBUG_ANIM_T"] == nil)
    }()
    @MainActor static func live(_ reduceMotion: Bool) -> Bool { !reduceMotion && !isStaticRun && !ValseDebugClock.shared.active }

    /// Damped spring step response 0 → 1 (SwiftUI-like `response` / `dampingFraction`), overshoots when damping < 1.
    static func spring(_ t: Double, response: Double = 0.42, damping: Double = 0.58) -> Double {
        guard t > 0 else { return 0 }
        let w0 = 2 * Double.pi / response, z = min(damping, 0.999)
        let wd = w0 * (1 - z * z).squareRoot()
        return 1 - exp(-z * w0 * t) * (cos(wd * t) + z * w0 / wd * sin(wd * t))
    }
    /// Time for `spring` to settle within 0.1 %.
    static func settle(response: Double = 0.42, damping: Double = 0.58) -> Double {
        let w0 = 2 * Double.pi / response
        return 6.9 / (min(damping, 0.999) * w0)
    }
    static func easeInOut(_ x: Double) -> Double { let c = min(max(x, 0), 1); return c * c * (3 - 2 * c) }
    /// One 3/4 bar (100 bpm): a swell on beat one that relaxes over beats two and three, 0…1.
    static func waltz(_ t: Double, bar: Double = 1.8) -> Double {
        let ph = (t / bar).truncatingRemainder(dividingBy: 1)
        let swell = ph < 0.22 ? easeInOut(ph / 0.22) : 1 - easeInOut((ph - 0.22) / 0.78)
        return swell
    }
}

/// A 0 → 1 → 0 value that follows `on` with a spring, evaluated from time (scrubbable), ticking only while it moves.
/// `content(p)`: p == 0 off, p == 1 on (may overshoot slightly).
struct ValseTween<Content: View>: View {
    let on: Bool
    var response = 0.42
    var damping = 0.58
    @ViewBuilder let content: (Double) -> Content
    @ObservedObject private var clock = ValseDebugClock.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var changedAt = Date.distantPast
    @State private var from = 0.0
    @State private var moving = false

    var body: some View {
        if let t = clock.t {
            content(on ? ValseMotion.spring(t - clock.hoverAt, response: response, damping: damping) : 0)
        } else if !ValseMotion.live(reduceMotion) {
            content(on ? 1 : 0)
        } else {
            SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !moving)) { tl in
                content(value(at: tl.date))
            }
            .onValueChange(of: on) { _, _ in
                let now = Date()
                from = value(at: now, target: on ? 0 : 1)   // where the previous motion had got to
                changedAt = now
                moving = true
            }
            .task(id: changedAt) {
                try? await Task.sleep(for: .seconds(ValseMotion.settle(response: response, damping: damping)))
                moving = false
            }
        }
    }

    private func value(at d: Date, target: Double? = nil) -> Double {
        let to = target ?? (on ? 1 : 0)
        let s = ValseMotion.spring(d.timeIntervalSince(changedAt), response: response, damping: damping)
        return from + (to - from) * s
    }
}

/// Folder icon tints: small colour moments that rotate through the palette.
enum ValsePlayfulTint {
    static let cycle: [Color] = [Theme.Valse.teal, Theme.Valse.mustard, Theme.Valse.mint, Theme.Valse.orange]
    static func folder(_ i: Int) -> Color { cycle[i % cycle.count] }
}

/// Selection (round 3): no stripes. A teal ring + soft teal halo around a raised shape, a bold label and, on content
/// (cards, rows, the selection bar), a teal check badge that springs in. Ring + check + weight carry the state
/// without relying on hue.
struct ValseSelectedHalo: ViewModifier {
    let selected: Bool
    var radius: CGFloat
    var ring: CGFloat = 1.5
    var inset: CGFloat = 0
    func body(content: Content) -> some View {
        ValseTween(on: selected, response: 0.38, damping: 0.62) { p in
            content
                .overlay(RoundedRectangle(cornerRadius: radius + inset).strokeBorder(Theme.Valse.teal.opacity(min(1, p)), lineWidth: ring).padding(-inset))
                .shadow(color: Theme.Valse.teal.opacity(0.28 * min(1, max(0, p))), radius: 9)
                .scaleEffect(selected ? 0.97 + 0.03 * p : 1)   // a small springy settle on select
        }
    }
}

/// Teal check badge (cards, rows, selection bar), popping in with a spring.
struct ValseCheckBadge: View {
    var size: CGFloat = 18
    var visible = true
    var body: some View {
        ValseTween(on: visible, response: 0.36, damping: 0.5) { p in
            Image(systemName: "checkmark.circle.fill").font(.system(size: size, weight: .semibold))
                .foregroundStyle(Theme.Valse.ink, Theme.Valse.teal)
                .background(Circle().fill(Theme.Valse.ink).padding(-1.5))   // dark rim: reads on any cover
                .scaleEffect(max(0.001, p))
                .opacity(min(1, max(0, p * 2)))
        }
        .accessibilityHidden(true)
    }
}

/// Springs a floating element up from below when it appears (selection bar).
struct ValseRiseIn: ViewModifier {
    @State private var shown = false
    func body(content: Content) -> some View {
        ValseTween(on: shown, response: 0.4, damping: 0.62) { p in
            content.offset(y: 24 * (1 - p)).opacity(min(1, max(0, p * 1.6)))
        }
        .onAppear { shown = true }
    }
}

/// The empty state's mark, swaying gently in 3/4 (a lean on beat one, easing back over two and three).
struct ValseSwayingMark: View {
    @ObservedObject private var clock = ValseDebugClock.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    var body: some View {
        if let t = clock.t {
            mark(t)
        } else if !ValseMotion.live(reduceMotion) {
            mark(nil)
        } else {
            SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30, paused: activeState == .inactive)) { tl in
                mark(tl.date.timeIntervalSinceReferenceDate)
            }
        }
    }
    private func mark(_ t: Double?) -> some View {
        ValseMark().rotationEffect(.degrees(-6 + 5 * (t.map { ValseMotion.waltz($0, bar: 2.1) } ?? 0)), anchor: .bottom)
    }
}

extension View {
    func valseSelected(_ selected: Bool, radius: CGFloat, ring: CGFloat = 1.5, inset: CGFloat = 0) -> some View {
        modifier(ValseSelectedHalo(selected: selected, radius: radius, ring: ring, inset: inset))
    }
}
