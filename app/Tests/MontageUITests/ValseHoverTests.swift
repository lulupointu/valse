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
