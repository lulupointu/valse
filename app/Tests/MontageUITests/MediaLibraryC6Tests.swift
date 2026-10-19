import Testing
import Foundation
import AppKit
import SwiftUI
import MontageCore
import MontageEngine
@testable import MontageUI
import MontageTestSupport

/// C6: media grid size, list-view filmstrips, click-to-preview at the hovered time, custom tooltips.
@MainActor @Suite(.serialized) struct MediaLibraryC6Tests {
    static func asset(_ name: String, seconds: Double = 10, kind: MediaKind = .video, size: Size2 = Size2(1920, 1080)) -> MediaAsset {
        var a = TimelineUITests.asset(name, seconds: seconds, kind: kind)
        a.pixelSize = size
        return a
    }

    // MARK: 1. grid

    @Test func gridHasAboutThreeBigTilesAtDefaultWidth() {
        // default layout: asset panel 0.34 × 1687 pt window − 120 pt rail ≈ 453 pt of grid
        #expect(MediaGrid.columns(width: 453) == 3)
        #expect(MediaGrid.tileWidth(width: 453) > 130)
        // narrower / wider panels reflow, tiles stay big
        for w in stride(from: 260.0, through: 900.0, by: 20) {
            let t = MediaGrid.tileWidth(width: w)
            #expect(t >= 110 && t <= 175, "width \(w) → tile \(t)")
        }
        #expect(MediaGrid.columns(width: 700) > MediaGrid.columns(width: 453))
        #expect(MediaGrid.columns(width: 300) < 3)
        // Retina: a 175 pt tile (3:2, aspect-fit) is ≤ 117 pt tall → 288 px posters are ≥ 2×
        #expect(Double(MediaThumbs.height) >= 2 * 175 / 1.5)
    }

    // MARK: 2. list filmstrips

    @Test func listStripTilesCoverTheWidth() {
        let land = Self.asset("l")
        let portrait = Self.asset("p", size: Size2(1080, 1920))
        let w: CGFloat = 430
        for a in [land, portrait] {
            let n = MediaRow.tileCount(a, width: w)
            #expect(CGFloat(n) * MediaRow.stripHeight * MediaThumbs.stripTileAspect(a) >= w)
            let times = MediaThumbs.stripTimes(a, count: n)
            #expect(times.count == n)
            #expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 })
            #expect(times.first! > .zero && times.last!.seconds < 10)
        }
        // portrait frames become square tiles (CapCut screenshot 27): more tiles, more source pixels
        #expect(MediaThumbs.stripTileAspect(portrait) == 1)
        #expect(MediaRow.tileCount(portrait, width: w) > MediaRow.tileCount(land, width: w))
        #expect(MediaThumbs.stripFrameHeight(portrait) > MediaThumbs.stripFrameHeight(land))
        #expect(MediaThumbs.stripFrameHeight(land) >= Int(2 * MediaRow.stripHeight))
        #expect(MediaRow.tileCount(Self.asset("a", kind: .audio), width: w) == 1)
        #expect(MediaThumbs.stripTimes(Self.asset("i", kind: .image), count: 3) == [.zero, .zero, .zero])
    }

    // MARK: 3. click = preview at the hovered time

    @Test func hoverTimeFollowsTheMouse() {
        let a = Self.asset("v", seconds: 8)
        #expect(MediaRow.hoverTime(a, x: 0, width: 200) == .zero)
        #expect(abs(MediaRow.hoverTime(a, x: 150, width: 200)!.seconds - 6) < 1e-6)
        #expect(abs(MediaRow.hoverTime(a, x: 900, width: 200)!.seconds - 8) < 1e-6)   // clamped
        #expect(MediaRow.hoverTime(Self.asset("i", kind: .image), x: 50, width: 200) == nil)
    }

    @Test func clickOnPreviewedMediaSeeksItOthersOpenAtStart() async throws {
        let s = EditorStore()
        s.autosaveEnabled = false
        var p = Project()
        let urls = [try await TestMedia.video(.solid(.red), seconds: 2), try await TestMedia.video(.solid(.blue), seconds: 3)]
        p.media = await MediaProbe.probeAll(urls).0
        s.load(project: p)
        let a = s.project.media[0].id, b = s.project.media[1].id
        func time() -> Double { (s.playerUI.previewTime - (s.playerUI.preview?.range.start ?? .zero)).seconds }

        s.previewMedia(a, hoverTime: Time(1.5))                    // not in the preview: opens at its beginning
        #expect(s.playerUI.preview?.itemID == a.description && time() == 0)
        s.previewMedia(a, hoverTime: Time(1.5))                    // in the preview: jumps to the hovered time
        #expect(abs(time() - 1.5) < 0.001)
        s.previewMedia(a, hoverTime: Time(60))                     // clamped inside the media
        #expect(time() < 2 && time() > 1.9)
        s.previewMedia(a)                                          // no hover time (keyboard): stays where it is
        #expect(time() > 1.9)
        s.previewMedia(b, hoverTime: Time(2))                      // another media: its beginning
        #expect(s.playerUI.preview?.itemID == b.description && time() == 0)
        #expect(s.project.timeline.allClips.isEmpty)
        s.exitPreview()
    }

    // MARK: 4. tooltips

    func anchors(_ center: TooltipCenter) -> (NSWindow, TooltipAnchorView, TooltipAnchorView) {
        let w = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 300, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        let a = TooltipAnchorView(text: "Split (⌘B)", center: center)
        let b = TooltipAnchorView(text: "Undo (⌘Z)", center: center)
        a.frame = CGRect(x: 10, y: 10, width: 26, height: 26)
        b.frame = CGRect(x: 50, y: 10, width: 26, height: 26)
        w.contentView?.addSubview(a)
        w.contentView?.addSubview(b)
        return (w, a, b)
    }

    func wait(_ s: Double) async throws { try await Task.sleep(for: .milliseconds(Int(s * 1000))) }

    @Test func tooltipAppearsAfterShortDelayAndLeavesAtOnce() async throws {
        #expect((150...250).contains(Tooltips.initialDelayMilliseconds))
        let c = TooltipCenter(delay: 0.1)
        c.ordersWindow = false
        let (w, a, b) = anchors(c)
        c.enter(a)
        #expect(c.shownText == nil && c.pendingText == "Split (⌘B)")
        try await wait(0.3)
        #expect(c.shownText == "Split (⌘B)")
        // moving to the next element: hidden at once, the delay starts again (no instant AppKit hand-over)
        c.enter(b)
        #expect(c.shownText == nil && c.pendingText == "Undo (⌘Z)")
        try await wait(0.3)
        #expect(c.shownText == "Undo (⌘Z)")
        // leaving: gone immediately; a late exit of another anchor changes nothing
        c.exit(b)
        #expect(c.shownText == nil && c.pendingText == nil)
        c.enter(a)
        c.exit(a)                                                  // left before the delay: never shows
        try await wait(0.3)
        #expect(c.shownText == nil)
        _ = w
    }

    @Test func clickHidesTooltipUntilTheMouseLeaves() async throws {
        let c = TooltipCenter(delay: 0.05)
        c.ordersWindow = false
        let (w, a, b) = anchors(c)
        c.enter(a)
        try await wait(0.2)
        #expect(c.shownText != nil)
        c.dismissForInteraction()
        #expect(c.shownText == nil)
        c.mouseMoved(to: CGPoint(x: 20, y: 20), in: w)             // still on it: stays hidden
        try await wait(0.2)
        #expect(c.shownText == nil)
        c.mouseMoved(to: CGPoint(x: 60, y: 20), in: w)             // next element
        try await wait(0.2)
        #expect(c.shownText == "Undo (⌘Z)")
        b.text = "Redo (⇧⌘Z)"                                      // live text change (toggle buttons)
        #expect(c.shownText == "Redo (⇧⌘Z)")
        c.mouseMoved(to: CGPoint(x: 200, y: 80), in: w)            // empty area
        #expect(c.shownText == nil)
        c.mouseMoved(to: CGPoint(x: 20, y: 20), in: w)             // back on the first one: shows again
        try await wait(0.2)
        #expect(c.shownText == "Split (⌘B)")
        a.removeFromSuperview()                                    // element goes away
        #expect(c.shownText == nil)
    }

    @Test func tooltipPillStaysOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 120, height: 22)
        let below = TooltipWindow.origin(size: size, anchor: CGRect(x: 500, y: 400, width: 26, height: 26), screen: screen)
        #expect(below.y + size.height <= 400 && abs(below.x + size.width / 2 - 513) < 0.01)
        let atBottom = TooltipWindow.origin(size: size, anchor: CGRect(x: 500, y: 5, width: 26, height: 26), screen: screen)
        #expect(atBottom.y >= 31)                                  // flipped above
        let atEdge = TooltipWindow.origin(size: size, anchor: CGRect(x: 990, y: 400, width: 10, height: 26), screen: screen)
        #expect(atEdge.x + size.width <= 1000)
    }

    @Test func helpModifierUsesMontageTooltips() {
        // `.help(String)` inside MontageUI resolves to the custom tooltip (shadowing SwiftUI's), keeping the hint
        let v = Text(verbatim: "x").help("Split")
        #expect(String(describing: type(of: v)).contains("TooltipModifier"))
        let host = NSHostingView(rootView: Text(verbatim: "x").help("Split").frame(width: 40, height: 20))
        host.frame = CGRect(x: 0, y: 0, width: 40, height: 20)
        let w = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 40, height: 20), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        defer { w.contentView = nil }
        func find(_ v: NSView) -> TooltipAnchorView? { (v as? TooltipAnchorView) ?? v.subviews.lazy.compactMap(find).first }
        #expect(find(host)?.text == "Split")
    }
}
