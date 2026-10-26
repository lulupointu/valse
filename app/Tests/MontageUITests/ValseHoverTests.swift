import Testing
import AppKit
@testable import MontageUI

/// VALSE-HOME bug 2: Home hover / lift / spin states always converge to the pointer's real state, whatever the order.
@MainActor @Suite struct ValseHoverTests {
    typealias E = ValseHoverModel.Event
    static let inside = E.moved(appActive: true, blockedByModal: false)

    func run(_ events: [E], from start: Bool = false) -> Bool { events.reduce(start) { ValseHoverModel.next($0, $1) } }

    @Test func inAndOut() {
        #expect(run([Self.inside]))
        #expect(!run([Self.inside, .ended]))
        // fast in / out / in / out, and an exit without an enter
        #expect(!run([Self.inside, .ended, Self.inside, .ended]))
        #expect(!run([.ended]))
        #expect(run([Self.inside, .ended, Self.inside]))
    }

    @Test func deactivationMidHoverNeverLeavesItLifted() {
        // the app resigns active while hovered: AppKit sends no exit, only the reset
        #expect(!run([Self.inside, .reset]))
        // moves delivered while inactive do not re-lift it
        #expect(!run([Self.inside, .reset, .moved(appActive: false, blockedByModal: false)]))
        // back active, the next move inside re-asserts the hover
        #expect(run([Self.inside, .reset, .moved(appActive: false, blockedByModal: false), Self.inside]))
        // a hover that started while inactive never lifts
        #expect(!run([.moved(appActive: false, blockedByModal: false)]))
    }

    @Test func scrollMenuAndModalResets() {
        // scrolled away under a still pointer / menu closed elsewhere: reset, no exit ever comes
        #expect(!run([Self.inside, .reset]))
        // an in-window modal covers the view: moves underneath never hover it
        #expect(!run([Self.inside, .moved(appActive: true, blockedByModal: true)]))
        #expect(!run([.moved(appActive: true, blockedByModal: true)]))
    }

    @Test func everySequenceEndingWithExitOrResetRests() {
        // exhaustive over every 6-event order of the four kinds of events, from both start states
        let kinds: [E] = [Self.inside, .moved(appActive: false, blockedByModal: false), .ended, .reset]
        var seqs: [[E]] = [[]]
        for _ in 0..<5 { seqs = seqs.flatMap { s in kinds.map { s + [$0] } } }
        for s in seqs {
            for start in [false, true] {
                #expect(!run(s + [.ended], from: start))
                #expect(!run(s + [.reset], from: start))
                #expect(run(s + [Self.inside], from: start))
            }
        }
    }

    @Test func tweenTargetIsTheModelValueAndStaticRunsDoNotAnimate() {
        #expect(ValseTweenTarget.value(true) == 1)
        #expect(ValseTweenTarget.value(false) == 0)
        #expect(ValseTweenTarget.animation(live: false, response: 0.4, damping: 0.6) == nil)   // Reduce Motion / tests
        #expect(ValseTweenTarget.animation(live: true, response: 0.4, damping: 0.6) != nil)
    }

    // MARK: round 5: feature cards and selection bar keys (ValseLift)

    @Test func liftStates() {
        #expect(ValseLift.state(hover: false, pressed: false) == .rest)
        #expect(ValseLift.state(hover: true, pressed: false) == .hover)
        #expect(ValseLift.state(hover: true, pressed: true) == .pressed)
        #expect(ValseLift.state(hover: false, pressed: true) == .pressed)   // pointer dragged off while held
        #expect(ValseLift.state(hover: true, pressed: true, enabled: false) == .disabled)
        #expect([ValseLift.State.rest, .hover, .pressed, .disabled].map(ValseLift.target) == [0, 1, -1, 0])
        // lifted: content up-left, block down-right; at rest and pressed there is no block
        #expect(ValseLift.offset(1, depth: 2) == -2 && ValseLift.block(1, depth: 2) == 2)
        #expect(ValseLift.offset(-1, depth: 2) == 2 && ValseLift.block(-1, depth: 2) == 0)
        #expect(ValseLift.block(0, depth: 2) == 0)
        #expect(ValseLift.showsBlock(1) && !ValseLift.showsBlock(0) && !ValseLift.showsBlock(-1))
    }

    func event(_ at: Double, _ s: ValseLift.State) -> ValseSpringEvent {
        let k = ValseLift.spring(to: s)
        return ValseSpringEvent(at: at, target: ValseLift.target(s), response: k.response, damping: k.damping)
    }

    /// Round 4 Shorts card bug: one very bouncy spring (damping 0.22) drove the lift through a clamp, so after the
    /// pointer left the value undershot below rest and came back up, re-lifting the card (its block blinking on / off).
    @Test func leavingNeverDipsBelowRestOrComesBack() {
        let seq = [event(0, .hover), event(1.5, .rest)]
        var last = 1.0
        for i in 0...150 {
            let v = ValseMotion.replay(seq, at: 1.5 + Double(i) / 100)
            #expect(v > -0.01, "undershoot below rest at \(i)")
            #expect(v <= last + 1e-4, "value rises again after the exit at \(i)")   // monotone back to rest
            last = v
        }
        #expect(abs(ValseMotion.replay(seq, at: 3)) < 0.001)
    }

    @Test func hoverOvershootIsSmallAndSettles() {
        let seq = [event(0, .hover)]
        let peak = stride(from: 0.0, through: 1.5, by: 0.005).map { ValseMotion.replay(seq, at: $0) }.max() ?? 0
        #expect(peak > 1.05 && peak < 1.2)   // one small sticker-like overshoot, not a 49 % bounce
        #expect(abs(ValseMotion.replay(seq, at: 1.5) - 1) < 0.002)
    }

    @Test func pressReleaseExitConverges() {
        let seq = [event(0, .hover), event(1, .pressed), event(1.2, .hover), event(2.5, .rest)]
        let pressed = ValseMotion.replay(seq, at: 1.15)
        #expect(pressed < -0.9 && pressed > -1.1)   // pushed in, no bounce out of the press
        #expect(ValseMotion.replay(seq, at: 2.4) > 0.99)
        #expect(abs(ValseMotion.replay(seq, at: 4)) < 0.001)
    }

    @Test func deactivationKeyLossAndMenuCloseResetEveryHover() {
        HoverReset.install()
        HoverReset.install()   // idempotent
        let nc = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification, NSMenu.didEndTrackingNotification] {
            let before = HoverReset.generation
            nc.post(name: name, object: nil)
            #expect(HoverReset.generation == before + 1, "\(name.rawValue) must reset hovers once")
        }
    }
}
