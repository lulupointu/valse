import Testing
import Foundation
import AppKit
import SwiftUI
@testable import MontageUI

/// FB-07: an in-window modal (Settings…) owns the pointer: the views it covers stop changing the cursor and showing
/// tooltips; only its card may (UI side: fb_settings_modal_hover.json).
@MainActor @Suite(.serialized) struct OwnerFeedbackFB07Tests {
    static func window() -> NSWindow {
        NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
    }

    @Test func modalShieldBlocksEverythingOutsideItsCard() throws {
        let w = Self.window()
        let other = Self.window()
        #expect(!ModalHoverGate.isBlocked(CGPoint(x: 10, y: 10), in: w))
        let shield = ModalShieldView(frame: CGRect(x: 100, y: 100, width: 200, height: 100))
        w.contentView?.addSubview(shield)
        #expect(ModalHoverGate.isActive(in: w))
        #expect(ModalHoverGate.isBlocked(CGPoint(x: 10, y: 10), in: w))        // timeline / canvas under the backdrop
        #expect(ModalHoverGate.isBlocked(nil, in: w))
        #expect(!ModalHoverGate.isBlocked(CGPoint(x: 150, y: 150), in: w))     // inside the card
        #expect(!ModalHoverGate.isBlocked(CGPoint(x: 10, y: 10), in: other))   // another window is not covered
        // two stacked modals: the topmost card wins
        let top = ModalShieldView(frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        w.contentView?.addSubview(top)
        #expect(!ModalHoverGate.isBlocked(CGPoint(x: 10, y: 10), in: w))
        #expect(ModalHoverGate.isBlocked(CGPoint(x: 150, y: 150), in: w))
        top.removeFromSuperview()
        #expect(ModalHoverGate.isBlocked(CGPoint(x: 10, y: 10), in: w))
        shield.removeFromSuperview()
        #expect(!ModalHoverGate.isActive(in: w))
        #expect(!ModalHoverGate.isBlocked(CGPoint(x: 10, y: 10), in: w))
    }

    @Test func tooltipsUnderAModalStayHidden() throws {
        let w = Self.window()
        let c = TooltipCenter(delay: 10)
        c.ordersWindow = false
        let under = TooltipAnchorView(text: "Split (⌘B)", center: c)
        under.frame = CGRect(x: 10, y: 10, width: 26, height: 26)
        let inCard = TooltipAnchorView(text: "Close", center: c)
        inCard.frame = CGRect(x: 120, y: 120, width: 26, height: 26)
        w.contentView?.addSubview(under)
        w.contentView?.addSubview(inCard)
        c.enter(under)
        #expect(c.pendingText == "Split (⌘B)")
        let shield = ModalShieldView(frame: CGRect(x: 100, y: 100, width: 200, height: 100))
        w.contentView?.addSubview(shield)
        c.modalDidAppear()                       // (the shared centre is told by the gate; this one is local)
        #expect(c.pendingText == nil)
        c.enter(under)
        #expect(c.pendingText == nil)
        c.enter(inCard)
        #expect(c.pendingText == "Close")
        c.exit(inCard)
        shield.removeFromSuperview()
        c.enter(under)
        #expect(c.pendingText == "Split (⌘B)")
        c.exit(under)
    }
}
