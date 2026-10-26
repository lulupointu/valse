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
///   VALSE_DEBUG_PRESS_AT=<s>, VALSE_DEBUG_RELEASE_AT=<s>, VALSE_DEBUG_UNHOVER_AT=<s>
///                                press / release / pointer exit of the forced-hover element (feature cards, selection
///                                bar buttons: `ValseSpringValue`).
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
    let pressAt: Double? = ProcessInfo.processInfo.environment["VALSE_DEBUG_PRESS_AT"].flatMap(Double.init)
    let releaseAt: Double? = ProcessInfo.processInfo.environment["VALSE_DEBUG_RELEASE_AT"].flatMap(Double.init)
    let unhoverAt: Double? = ProcessInfo.processInfo.environment["VALSE_DEBUG_UNHOVER_AT"].flatMap(Double.init)
    var active: Bool { t != nil }

    /// Review clock: the forced element's hover at the current time (nil = not under review, use the real pointer).
    func debugHover(_ id: String) -> Bool? {
        guard let t, ValseDebugHover.forced(id) else { return nil }
        if let u = unhoverAt, t >= u { return false }
        return t >= hoverAt
    }

    /// Review clock: the forced element is held down (VALSE_DEBUG_PRESS_AT … RELEASE_AT).
    func debugPressed(_ id: String) -> Bool {
        guard let t, ValseDebugHover.forced(id), let p = pressAt, t >= p else { return false }
        if let r = releaseAt, t >= r { return false }
        return true
    }

    /// Review clock: the forced element's hover in / out as spring retargets (`ValseLift.spring`).
    func hoverEvents(_ id: String) -> [ValseSpringEvent] {
        guard ValseDebugHover.forced(id) else { return [] }
        let up = ValseLift.spring(hover: true), down = ValseLift.spring(hover: false)
        var e = [ValseSpringEvent(at: hoverAt, target: 1, response: up.response, damping: up.damping)]
        if let u = unhoverAt { e.append(ValseSpringEvent(at: u, target: 0, response: down.response, damping: down.damping)) }
        return e
    }

    /// Review clock: the forced element's press / release as spring retargets (`ValsePress`).
    func pressEvents(_ id: String, response: Double = ValsePress.response, damping: Double = ValsePress.damping) -> [ValseSpringEvent] {
        guard ValseDebugHover.forced(id), let p = pressAt else { return [] }
        var e = [ValseSpringEvent(at: p, target: 1, response: response, damping: damping)]
        if let r = releaseAt { e.append(ValseSpringEvent(at: r, target: 0, response: response, damping: damping)) }
        return e
    }

    /// Renders the requested frame range of the clock, one PNG per frame (review videos).
    func recordIfRequested() async {
        guard let spec = ProcessInfo.processInfo.environment["VALSE_DEBUG_FRAMES"] else { return }
        defer { recordingFinished = true }
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
    private var recordingFinished = false

    /// `--snapshot` runs exit right after their PNG: with VALSE_DEBUG_FRAMES set, wait for the frame recording first.
    static func waitForRecording() async {
        guard ProcessInfo.processInfo.environment["VALSE_DEBUG_FRAMES"] != nil else { return }
        while !shared.recordingFinished { try? await Task.sleep(for: .milliseconds(200)) }
    }
}

/// Review videos (VALSE_DEBUG_FRAMES) from `--snapshot` runs: main.swift waits for the recording before its snapshot.
@MainActor public enum ValseReview {
    public static func waitForRecording() async { await ValseDebugClock.waitForRecording() }
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
    /// A sequence of spring retargets as a sum of step responses (review clock, tests). Exact when one retarget lands
    /// after the previous one settled; mid-flight it approximates SwiftUI's velocity-preserving retarget.
    static func replay(_ events: [ValseSpringEvent], at t: Double, from start: Double = 0) -> Double {
        var v = start, prev = start
        for e in events {
            v += (e.target - prev) * spring(t - e.at, response: e.response, damping: e.damping)
            prev = e.target
        }
        return v
    }
    static func easeInOut(_ x: Double) -> Double { let c = min(max(x, 0), 1); return c * c * (3 - 2 * c) }
    /// One 3/4 bar (100 bpm): a swell on beat one that relaxes over beats two and three, 0…1.
    static func waltz(_ t: Double, bar: Double = 1.8) -> Double {
        let ph = (t / bar).truncatingRemainder(dividingBy: 1)
        let swell = ph < 0.22 ? easeInOut(ph / 0.22) : 1 - easeInOut((ph - 0.22) / 0.78)
        return swell
    }
}

/// A 0 → 1 → 0 progress that follows `on` with a SwiftUI spring. `content(p)`: p == 0 off, p == 1 on (may overshoot).
///
/// Bug 2 (owner: "sometimes it stops in the middle, sometimes it stops elevated"): this used to be a time-driven tween
/// whose value was computed from `TimelineView` ticks, and the TimelineView was paused by a `Task.sleep(settle)` that
/// flipped `moving = false`. The rendered value was therefore whatever the LAST tick had computed: when ticks stopped
/// before the settle time (TimelineView throttled / not redrawn while the window was inactive or occluded, the sleep
/// task cancelled or outliving a re-render with a stale date), the element froze mid-spring and stayed there until the
/// next hover change. Now the model value `p` is always exactly the target (0 or 1); only the presentation animates,
/// through SwiftUI's own animation engine (`Animatable`), which is interruptible and retargets from the current value
/// and velocity, and always lands on the model value. `.task(id: on)` (keyed on the value, not on an event) cannot miss
/// a change. Reduce Motion, UI tests and plain screenshots: no animation, the state changes instantly.
struct ValseTween<Content: View>: View {
    let on: Bool
    var response: Double
    var damping: Double
    let content: (Double) -> Content
    @ObservedObject private var clock = ValseDebugClock.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var p: Double

    init(on: Bool, response: Double = 0.42, damping: Double = 0.58, @ViewBuilder content: @escaping (Double) -> Content) {
        self.on = on
        self.response = response
        self.damping = damping
        self.content = content
        _p = State(initialValue: ValseTweenTarget.value(on))
    }

    var body: some View {
        if let t = clock.t {
            // review clock (VALSE_DEBUG_ANIM_T / VALSE_DEBUG_FRAMES): the same spring, scrubbable frame by frame
            content(on ? ValseMotion.spring(t - clock.hoverAt, response: response, damping: damping) : 0)
        } else {
            ValseAnimatedProgress(p: p, content: content)
                .task(id: on) { settle(on) }
        }
    }

    private func settle(_ on: Bool) {
        let target = ValseTweenTarget.value(on)
        guard p != target else { return }
        if let a = ValseTweenTarget.animation(live: ValseMotion.live(reduceMotion), response: response, damping: damping) {
            withAnimation(a) { p = target }
        } else {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { p = target }
        }
    }
}

/// The tween's model value and transition (pure, ValseHoverTests).
enum ValseTweenTarget {
    static func value(_ on: Bool) -> Double { on ? 1 : 0 }
    /// nil = change instantly (Reduce Motion, UI tests, plain screenshots).
    static func animation(live: Bool, response: Double, damping: Double) -> Animation? {
        live ? .spring(response: response, dampingFraction: damping) : nil
    }
}

/// Hover lift of the feature cards' icon tile (and of the whole card in hover option A): one value 0 → 1 that follows
/// the hover. Up = the sidebar sticker's spring (0.34 / 0.55, one small overshoot); down = critically damped. An
/// underdamped exit undershoots below rest, and with a clamped block it re-lifted the round 4 Shorts card after the
/// pointer had left.
enum ValseLift {
    static func spring(hover: Bool) -> (response: Double, damping: Double) { hover ? (0.34, 0.55) : (0.26, 1.0) }
    /// Offset of the lifted content (negative = up-left).
    static func offset(_ v: Double, depth: CGFloat) -> CGFloat { -depth * CGFloat(v) }
    /// Offset of the solid block behind it (down-right).
    static func block(_ v: Double, depth: CGFloat) -> CGFloat { depth * CGFloat(max(0, v)) }
    /// The block is drawn only while lifted.
    static func showsBlock(_ v: Double) -> Bool { v > 0.02 }
}

/// Press feel, the hero's "Custom" button recipe (`ValsePressLabel`): spring response 0.25, damping 0.55 (reacts on
/// mouse down, the release springs back just past rest) and the fill dimmed to 75 % while held. The selection bar keys
/// use it with Custom's squash; the feature cards use the same spring and dim with a different motion (`ValseCardPress`).
enum ValsePress {
    static let response = 0.25, damping = 0.55
    static let fillOpacity = 0.75
    static let keyScale: CGFloat = 0.95
    static func scale(_ k: Double, to s: CGFloat) -> CGFloat { 1 - (1 - s) * CGFloat(k) }
}

/// Feature card motion (round 7, hover "A"). Hover lifts the card `depth` up-left off a solid block of its colour and
/// pops its icon tile `tileDepth` off the tile's own block. Press drives the card down onto its block (`k`, its own
/// quicker spring with Custom's single release pop): it travels the lift plus `sink` of the block depth, so only a sliver of the block is left showing while held;
/// the icon tile settles onto its block a beat later (`k2`, a slightly slower spring) and pops back a beat after the
/// card on release. Pure (ValseHoverTests).
enum ValseCardPress {
    static let depth: CGFloat = 2, tileDepth: CGFloat = 1.5
    /// How far into the block the card goes while held (0.8 = 80 %: a 0.4 pt sliver of the 2 pt block is left).
    static let sink: CGFloat = 0.8
    /// The card's own press spring (round 8, owner: "a bit slow"): Custom's character (one short pop on release) but
    /// faster than Custom's 0.25 / 0.55, so the 4 pt travel lands as quickly as Custom's tiny squash.
    static let response = 0.17, damping = 0.6
    /// The tile's settle: a hair behind the card (one gesture with a follow-through, not two events), no bounce.
    static let tileResponse = 0.2, tileDamping = 0.75
    /// Card offset (both axes; negative = up-left) for hover `h` and press `k`.
    static func card(h: Double, k: Double) -> CGFloat {
        let lift = depth * CGFloat(max(0, h))
        return -lift + CGFloat(k) * (lift + sink * depth)
    }
    /// The card's block offset (it stays put while the card is pushed onto it).
    static func block(h: Double) -> CGFloat { depth * CGFloat(max(0, h)) }
    /// Icon tile lift above the card for hover `h` and the tile's press value `k2`.
    static func tile(h: Double, k2: Double) -> CGFloat { tileDepth * CGFloat(max(0, h)) * (1 - CGFloat(min(1, max(0, k2)))) }
}

/// The press value 0 → 1 with `ValsePress`'s spring, through `ValseSpringValue` (interruptible, always converges,
/// replayable under the review clock). `pressed` comes straight from the button's `isPressed`: nothing else holds
/// state. The release bounces slightly below 0 (a squash just past full size), as Custom's does.
struct ValsePressValue<Content: View>: View {
    let pressed: Bool
    var debugID = ""
    var response = ValsePress.response
    var damping = ValsePress.damping
    @ViewBuilder let content: (Double) -> Content
    @ObservedObject private var clock = ValseDebugClock.shared
    var body: some View {
        ValseSpringValue(target: pressed || clock.debugPressed(debugID) ? 1 : 0, response: response, damping: damping,
                         debugEvents: clock.pressEvents(debugID, response: response, damping: damping), content: content)
    }
}

/// A spring retarget at review-clock time `at` (debug replays of hover / press / release / exit).
struct ValseSpringEvent: Equatable {
    var at: Double
    var target: Double
    var response: Double
    var damping: Double
}

/// `ValseTween` for any target value and spring. Same engine: the model value is always exactly the
/// target and SwiftUI's interruptible spring animates the presentation (retargets keep the current velocity), so it
/// always converges. Under the review clock the timeline in `debugEvents` is replayed (`ValseMotion.replay`).
struct ValseSpringValue<Content: View>: View {
    let target: Double
    var response: Double
    var damping: Double
    var debugEvents: [ValseSpringEvent] = []
    let content: (Double) -> Content
    @ObservedObject private var clock = ValseDebugClock.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var p: Double

    init(target: Double, response: Double, damping: Double, debugEvents: [ValseSpringEvent] = [],
         @ViewBuilder content: @escaping (Double) -> Content) {
        self.target = target
        self.response = response
        self.damping = damping
        self.debugEvents = debugEvents
        self.content = content
        _p = State(initialValue: target)
    }

    var body: some View {
        if let t = clock.t {
            content(debugEvents.isEmpty ? target : ValseMotion.replay(debugEvents, at: t))
        } else {
            ValseAnimatedProgress(p: p, content: content)
                // same frame as the change (a press reacts on mouse down, like a plain SwiftUI `.animation`)…
                .onValueChange(of: target) { _, t in settle(t) }
                // …and keyed on the value as the safety net that cannot miss a change (settle is idempotent)
                .task(id: target) { settle(target) }
        }
    }

    private func settle(_ target: Double) {
        guard p != target else { return }
        if let a = ValseTweenTarget.animation(live: ValseMotion.live(reduceMotion), response: response, damping: damping) {
            withAnimation(a) { p = target }
        } else {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { p = target }
        }
    }
}

private struct ValsePressedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// The enclosing `ValsePressReportingStyle` button is pressed.
    var valsePressed: Bool {
        get { self[ValsePressedKey.self] }
        set { self[ValsePressedKey.self] = newValue }
    }
}

/// Hands the button's pressed state to its label (`@Environment(\.valsePressed)`), which draws its own press.
struct ValsePressReportingStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.environment(\.valsePressed, configuration.isPressed)
    }
}

/// Hands SwiftUI's interpolated `p` to the content on every animation frame.
private struct ValseAnimatedProgress<Content: View>: View, Animatable {
    var p: Double
    let content: (Double) -> Content
    var animatableData: Double {
        get { p }
        set { p = newValue }
    }
    var body: some View { content(p) }
}

/// Hover state machine (pure, ValseHoverTests). `.onHover` only flips on enter / exit events, and macOS drops the exit
/// in several situations (HoverReset), which left elements lifted / spun after the pointer had gone. Here every pointer
/// move inside re-asserts the state, any reset or disappearance clears it, and a move only counts while the app is
/// active and no in-window modal covers the point.
enum ValseHoverModel {
    enum Event: Equatable {
        /// `onContinuousHover(.active)`: the pointer moved inside the view.
        case moved(appActive: Bool, blockedByModal: Bool)
        /// `onContinuousHover(.ended)`: the pointer left.
        case ended
        /// `HoverReset` (deactivation, key loss, menu closed, scroll, modal) or the view left the hierarchy.
        case reset
    }
    static func next(_ hovering: Bool, _ e: Event) -> Bool {
        switch e {
        case .moved(let active, let blocked): return active && !blocked
        case .ended, .reset: return false
        }
    }
}

/// Convergent hover tracking for Home's micro-interactions (replaces `.onHover { hover = $0 }`).
struct ValseHoverTracking: ViewModifier {
    @Binding var hovering: Bool
    func body(content: Content) -> some View {
        content
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active:
                    let e = NSApp.currentEvent
                    apply(.moved(appActive: NSApp.isActive,
                                 blockedByModal: ModalHoverGate.isBlocked(e?.locationInWindow, in: e?.window)))
                case .ended: apply(.ended)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: HoverReset.notification)) { _ in apply(.reset) }
            .onAppear { HoverReset.install() }
            .onDisappear { apply(.reset) }
    }
    private func apply(_ e: ValseHoverModel.Event) {
        let v = ValseHoverModel.next(hovering, e)
        if v != hovering { hovering = v }
    }
}

/// Folder icon tints: small colour moments that rotate through the palette.
enum ValsePlayfulTint {
    static let cycle: [Color] = [Theme.Valse.teal, Theme.Valse.mustard, Theme.Valse.mint, Theme.Valse.orange]
    static func folder(_ i: Int) -> Color { cycle[i % cycle.count] }
}

/// Hard offset shadow, 80s print / sticker style: a solid block of `color` behind the shape, shifted down-right by
/// `depth`, zero blur. Used for every lift and selection on Home (no glows, no blurred shadows anywhere).
struct ValseHardShadow: ViewModifier {
    var color: Color
    var radius: CGFloat
    var depth: CGFloat
    /// Grows the block beyond the content's frame (e.g. to sit under an outside frame).
    var inset: CGFloat = 0
    func body(content: Content) -> some View {
        content.background(RoundedRectangle(cornerRadius: radius).fill(color).padding(-inset)
            .offset(x: depth, y: depth).opacity(depth > 0.05 ? 1 : 0))
    }
}

/// Selection (round 4): flat 80s "sticker". A solid mint block with ink content (10.3:1), lifted on a solid teal
/// offset block (zero blur); weight goes bold. On select the sticker springs up and its offset block slides out.
/// Block + offset shape + weight (+ a check on content) carry the state without relying on hue.
struct ValseSticker: ViewModifier {
    let selected: Bool
    var radius: CGFloat
    var depth: CGFloat = 3
    func body(content: Content) -> some View {
        ValseTween(on: selected, response: 0.34, damping: 0.55) { p in
            content
                .background(RoundedRectangle(cornerRadius: radius).fill(selected ? Theme.Valse.mint : .clear))
                .modifier(ValseHardShadow(color: Theme.Valse.teal, radius: radius, depth: selected ? depth * max(0, p) : 0))
                .offset(x: selected ? -1 * min(1, max(0, p)) : 0, y: selected ? -1 * min(1, max(0, p)) : 0)
        }
    }
}

/// Plain flat check badge (cards, rows, selection bar): a solid disc with a bold check and a 1.5 pt ink rim, popping in.
struct ValseCheckBadge: View {
    var size: CGFloat = 18
    var fill: Color = Theme.Valse.mint
    var mark: Color = Theme.Valse.ink
    @State private var shown = false
    var body: some View {
        ValseTween(on: shown || ValseMotion.isStaticRun, response: 0.36, damping: 0.5) { p in
            Circle().fill(fill)
                .overlay(Circle().strokeBorder(Theme.Valse.ink, lineWidth: 1.5))
                .overlay(Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .heavy)).foregroundStyle(mark))
                .frame(width: size, height: size)
                .scaleEffect(max(0.001, p))
        }
        .onAppear { shown = true }
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
    func valseSticker(_ selected: Bool, radius: CGFloat, depth: CGFloat = 3) -> some View {
        modifier(ValseSticker(selected: selected, radius: radius, depth: depth))
    }
    /// Hover flag that always converges to the pointer's real position (ValseHoverTracking).
    func valseHover(_ hovering: Binding<Bool>) -> some View { modifier(ValseHoverTracking(hovering: hovering)) }
    func valseHardShadow(_ color: Color, radius: CGFloat, depth: CGFloat) -> some View {
        modifier(ValseHardShadow(color: color, radius: radius, depth: depth))
    }
}
