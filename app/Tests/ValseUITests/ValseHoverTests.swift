import Testing
import AppKit
@testable import ValseUI

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

    // MARK: feature cards and selection bar keys (round 6)

    @Test func liftGeometry() {
        // lifted: content up-left, block down-right; no block at rest
        #expect(ValseLift.offset(1, depth: 2) == -2 && ValseLift.block(1, depth: 2) == 2)
        #expect(ValseLift.block(0, depth: 2) == 0 && ValseLift.block(-0.3, depth: 2) == 0)
        #expect(ValseLift.showsBlock(1) && !ValseLift.showsBlock(0) && !ValseLift.showsBlock(-0.3))
    }

    func hoverEvent(_ at: Double, _ on: Bool) -> ValseSpringEvent {
        let k = ValseLift.spring(hover: on)
        return ValseSpringEvent(at: at, target: on ? 1 : 0, response: k.response, damping: k.damping)
    }

    func cardPressEvent(_ at: Double, _ on: Bool) -> ValseSpringEvent {
        ValseSpringEvent(at: at, target: on ? 1 : 0, response: ValseCardPress.response, damping: ValseCardPress.damping)
    }

    /// Round 8 ("a bit slow"): the card press is quicker than Custom's and lands in about a tenth of a second, keeps one
    /// short release pop, and the tile follows within a few hundredths of a second (one gesture).
    @Test func cardPressIsSnappy() {
        #expect(ValseCardPress.response < ValsePress.response && ValseCardPress.tileResponse < 0.25)
        let down = [cardPressEvent(0, true)]
        let t90 = stride(from: 0.0, through: 0.5, by: 0.002).first { ValseMotion.replay(down, at: $0) >= 0.9 } ?? 1
        #expect(t90 < 0.08)
        let release = [cardPressEvent(0, true), cardPressEvent(0.5, false)]
        let after = stride(from: 0.5, through: 1.5, by: 0.002).map { ValseMotion.replay(release, at: $0) }
        let pop = -(after.min() ?? 0)
        #expect(pop > 0.04 && pop < 0.15)                                            // a pop survives, short
        let settled = stride(from: 0.5, through: 1.5, by: 0.002).first { t in
            stride(from: t, through: 1.5, by: 0.01).allSatisfy { abs(ValseMotion.replay(release, at: $0)) < 0.01 }
        } ?? 2
        #expect(settled - 0.5 < 0.35)                                                // quiet within 0.35 s
        let tile = [ValseSpringEvent(at: 0, target: 1, response: ValseCardPress.tileResponse, damping: ValseCardPress.tileDamping)]
        let tile90 = stride(from: 0.0, through: 0.5, by: 0.002).first { ValseMotion.replay(tile, at: $0) >= 0.9 } ?? 1
        #expect(tile90 > t90 && tile90 - t90 < 0.05)                                 // a hair behind the card
    }

    func pressEvent(_ at: Double, _ on: Bool) -> ValseSpringEvent {
        ValseSpringEvent(at: at, target: on ? 1 : 0, response: ValsePress.response, damping: ValsePress.damping)
    }

    /// Round 4 Shorts card bug: one very bouncy spring (damping 0.22) drove the lift through a clamp, so after the
    /// pointer left the value undershot below rest and came back up, re-lifting the card (its block blinking on / off).
    @Test func leavingNeverDipsBelowRestOrComesBack() {
        let seq = [hoverEvent(0, true), hoverEvent(1.5, false)]
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
        let seq = [hoverEvent(0, true)]
        let peak = stride(from: 0.0, through: 1.5, by: 0.005).map { ValseMotion.replay(seq, at: $0) }.max() ?? 0
        #expect(peak > 1.05 && peak < 1.2)   // one small sticker-like overshoot, not a 49 % bounce
        #expect(abs(ValseMotion.replay(seq, at: 1.5) - 1) < 0.002)
    }

    /// Every Home press (cards, bar keys) is the hero "Custom" button's: 0.25 / 0.55 spring, settles, bounces slightly.
    @Test func pressIsCustomsSpringAndSettles() {
        #expect(ValsePress.response == 0.25 && ValsePress.damping == 0.55 && ValsePress.fillOpacity == 0.75)
        let seq = [pressEvent(0, true), pressEvent(0.12, false)]
        #expect(ValseMotion.replay(seq, at: 0.1) > 0.6)                     // squashed while held
        let after = stride(from: 0.12, through: 1.2, by: 0.005).map { ValseMotion.replay(seq, at: $0) }
        #expect((after.min() ?? 0) < 0 && (after.min() ?? 0) > -0.3)         // release bounces just past full size
        #expect(abs(ValseMotion.replay(seq, at: 1.5)) < 0.001)
        #expect(ValsePress.scale(1, to: ValsePress.keyScale) == ValsePress.keyScale && ValsePress.scale(0, to: 0.9) == 1)
    }

    @Test func barKeyLookFollowsOnlyPointerAndPress() {
        typealias L = ValseBarKeyLook
        #expect(L.fill(hover: false, pressed: false, enabled: true) == .none)
        #expect(L.fill(hover: true, pressed: false, enabled: true) == .hover)
        #expect(L.fill(hover: true, pressed: true, enabled: true) == .lit)
        #expect(L.fill(hover: false, pressed: true, enabled: true) == .lit)   // dragged off while held
        #expect(L.fill(hover: true, pressed: true, enabled: false) == .none)
    }

    /// Round 7 card press: lifted off its block on hover, driven down onto it while held (a sliver left), back on release.
    @Test func cardPressDrivesTheCardOntoItsBlock() {
        typealias C = ValseCardPress
        #expect(C.card(h: 0, k: 0) == 0 && C.block(h: 0) == 0)                       // rest: flat, no block
        #expect(C.card(h: 1, k: 0) == -C.depth && C.block(h: 1) == C.depth)          // hover: 2 pt up-left, block 2 pt down-right
        let held = C.card(h: 1, k: 1)
        #expect(held > 0 && C.block(h: 1) - held > 0.2 && C.block(h: 1) - held < 0.6) // held: on the block, a 0.4 pt sliver left
        #expect(C.tile(h: 1, k2: 0) == C.tileDepth && C.tile(h: 1, k2: 1) == 0)      // tile settles flat onto its block
        #expect(C.tile(h: 1, k2: -0.2) == C.tileDepth && C.tile(h: 1, k2: 1.2) == 0)  // its spring never lifts it past either end
        // the tile settles a beat after the card (slower spring), with no visible bounce of its own
        let card = [cardPressEvent(0, true)]
        let tile = [ValseSpringEvent(at: 0, target: 1, response: C.tileResponse, damping: C.tileDamping)]
        #expect(ValseMotion.replay(tile, at: 0.06) < ValseMotion.replay(card, at: 0.06))
        let tilePeak = stride(from: 0.0, through: 1, by: 0.005).map { ValseMotion.replay(tile, at: $0) }.max() ?? 0
        #expect(tilePeak < 1.06)
    }

    /// Hover → press → release (the action fires) → still hovered: everything lands exactly on the lifted state; then the
    /// pointer leaves: back to rest, no re-lift.
    @Test func cardPressReleaseConverges() {
        let hover = [hoverEvent(0, true), hoverEvent(2, false)]
        let press = [cardPressEvent(1, true), cardPressEvent(1.15, false)]
        func card(_ t: Double) -> CGFloat {
            ValseCardPress.card(h: ValseMotion.replay(hover, at: t), k: ValseMotion.replay(press, at: t))
        }
        #expect(card(1.12) > 0.8)                                  // pushed down onto the block while held
        #expect(abs(card(1.9) + ValseCardPress.depth) < 0.02)       // back to the lifted state after the release
        #expect(abs(card(3)) < 0.01)                                // rest after the exit
    }

    @Test func heroRibbonFollowsTheLogo() {
        let size = CGSize(width: 1400, height: ValseHeroRibbon.heroHeight)
        let (pts, over) = ValseRibbon.logoCentreline(in: size, width: 38,
                                                     .init(turnFromTrailing: ValseHeroRibbon.turnFromTrailing, bottom: ValseHeroRibbon.turnBottom))
        let s = 38 / ValseRibbon.Logo.band
        // enters above the top edge, leaves past the trailing edge, and the whole band stays inside the hero
        #expect(pts.first!.y < 0 && pts.last!.x > size.width)
        // (the arm is meant to cross the top edge: check the loop's top and the turn's bottom)
        let loopTop = pts[over].map(\.y).min()!, lowest = pts.map(\.y).max()!
        #expect(loopTop - 19 > 8 && lowest + 19 < size.height - 4)
        // the loop's radius / band ratio is the logo's (71.7 / 90): the over pass starts with ≈ 90 pt of loop
        let loopPts = Array(pts[over.lowerBound..<over.lowerBound + 18])
        let c = CGPoint(x: size.width - ValseHeroRibbon.turnFromTrailing + (ValseRibbon.Logo.loop.x - ValseRibbon.Logo.turn.x) * s,
                        y: size.height - ValseHeroRibbon.turnBottom - (ValseRibbon.Logo.turn.y + ValseRibbon.Logo.turnR - ValseRibbon.Logo.loop.y) * s)
        for p in loopPts { #expect(abs(hypot(p.x - c.x, p.y - c.y) / 38 - 71.7 / 90) < 0.01) }
        // continuous: no gap between samples
        for i in 1..<pts.count { #expect(hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y) < 6) }
        // the loop and the Custom chip (top-right, ≈ 130 × 40 pt) never meet
        #expect(pts.filter { $0.y < 40 + 19 && $0.y > 0 }.allSatisfy { $0.x + 19 < size.width - 130 })
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
