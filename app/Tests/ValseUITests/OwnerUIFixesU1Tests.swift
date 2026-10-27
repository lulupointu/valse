import Testing
import Foundation
import AppKit
import ValseCore
@testable import ValseUI

/// U1: owner UI fixes — splitter jitter, Settings sideways scroll, "Sous-titres", no ellipsis on in-app titles, wrapped
/// tooltips, timeline follow during playback.
@MainActor @Suite(.serialized) struct OwnerUIFixesU1Tests {

    // MARK: 1. splitter (flicker while resizing panels)

    /// The panel size is absolute (size at press + mouse travel): replaying a steady drag gives a monotonic size that
    /// follows the mouse 1:1. The old delta-in-local-space mapping gave half the travel, alternating between two values.
    @Test func splitterSizeFollowsTheMouseOneToOne() {
        var sizes: [CGFloat] = []
        for i in 1...20 {
            sizes.append(Splitter.size(start: 500, translation: CGSize(width: CGFloat(i) * 3, height: 7), axis: .vertical, sign: 1))
        }
        #expect(sizes.last == 560)
        #expect(zip(sizes, sizes.dropFirst()).allSatisfy { $0 < $1 })
        // the panel after the splitter (inspector / vertical player) shrinks when dragging right
        #expect(Splitter.size(start: 400, translation: CGSize(width: 30, height: 0), axis: .vertical, sign: -1) == 370)
        #expect(Splitter.size(start: 300, translation: CGSize(width: 99, height: -20), axis: .horizontal, sign: 1) == 280)
    }

    // MARK: 2 / 4. Settings strings

    @Test func inAppTitlesHaveNoEllipsisButTheMenuItemKeepsIt() {
        ValseBootstrap.registerResources()
        let en = L10n.shared.strings(for: "en"), fr = L10n.shared.strings(for: "fr")
        #expect(en["settings.title"] == "Settings")
        #expect(fr["settings.title"] == "Paramètres")
        #expect(en["keymap.title"].map { !$0.contains("…") && !$0.contains("...") } == true)
        #expect(fr["keymap.title"].map { !$0.contains("…") && !$0.contains("...") } == true)
        // standard macOS app-menu item (opens a window): the ellipsis stays
        #expect(en["menu.settings"] == "Settings…")
        #expect(fr["menu.settings"] == "Paramètres…")
    }

    // MARK: 3. Captions → Sous-titres

    @Test func frenchCaptionsAreSousTitres() {
        ValseBootstrap.registerResources()
        let fr = L10n.shared.strings(for: "fr")
        #expect(fr["tab.captions"] == "Sous-titres")
        #expect(fr["inspector.tab.captions"] == "Sous-titres")
        #expect(fr["captions.tab"] == "Sous-titres")
        #expect(fr["captions.playFrom"]?.contains("ce sous-titre") == true)
        // "légende" stays only where it means a social-media post caption (credit line of CC BY music)
        let left = fr.filter { $0.value.lowercased().contains("légende") }.map(\.key).sorted()
        #expect(left == ["audio.license.creditBody"], "still 'légende': \(left)")
    }

    /// U1-4: the shortcut list (Settings ▸ Shortcuts, Keyboard Shortcuts window) names menu commands without the menu
    /// item's "…" — only the app-menu item keeps it.
    @Test func shortcutListDropsTheMenuEllipsis() {
        #expect(ShortcutList.title("Settings…") == "Settings")
        #expect(ShortcutList.title("Paramètres…") == "Paramètres")
        #expect(ShortcutList.title("Keyboard Shortcuts...") == "Keyboard Shortcuts")
        #expect(ShortcutList.title("Split") == "Split")
        let entry = Keymap.menuCommands.first { $0.id == "menu.settings" }!
        #expect(!ShortcutList.title(entry).hasSuffix("…"))
    }

    // MARK: 5. tooltips wrap instead of losing their end

    @Test func longTooltipWrapsAndShowsEveryWord() {
        let w = TooltipWindow()
        let one = "Split (⌘B)"
        w.setText(one)
        let oneLine = w.frame.height
        let long = "Double-cliquez pour lire à partir de cette légende (texte de l’info-bulle plus long que la largeur maximale)"
        w.setText(long)
        #expect(w.frame.width <= TooltipWindow.maxTextWidth + 16 + 0.5)
        #expect(w.frame.height > oneLine + 8)                  // two lines
        // the label's frame is big enough for the wrapped text: nothing clipped
        let need = TooltipWindow.textSize(long, font: .systemFont(ofSize: 12))
        #expect(w.labelFrame.height >= need.height - 0.5)
        let cell = NSTextFieldCell(textCell: long)
        cell.font = .systemFont(ofSize: 12); cell.wraps = true
        #expect(cell.cellSize(forBounds: CGRect(x: 0, y: 0, width: w.labelFrame.width, height: 10_000)).height <= w.labelFrame.height + 0.5)
    }

    /// `VALSE_U1_SHOTS=<dir>`: writes the French caption tooltip pill as a PNG (docs/ux/parity/u1_tooltip.png).
    @Test func captionTooltipPillImage() throws {
        ValseBootstrap.registerResources()
        let lang = L10n.shared.language
        defer { L10n.shared.setLanguageForSession(lang) }
        L10n.shared.setLanguageForSession("fr")
        let text = CaptionRow.playFromHelp(Time(3.4))
        #expect(text == "Double-cliquez pour lire à partir de 00:00:03")
        L10n.shared.setLanguageForSession("en")
        #expect(CaptionRow.playFromHelp(Time(65)) == "Double-click to play from 00:01:05")
        guard let dir = ProcessInfo.processInfo.environment["VALSE_U1_SHOTS"] else { return }
        for (name, s) in [("tooltip-fr", text), ("tooltip-long-fr", "Double-cliquez pour lire à partir de cette légende (texte de l’info-bulle plus long que la largeur maximale)")] {
            let w = TooltipWindow()
            w.setText(s)
            let v = try #require(w.contentView)
            v.wantsLayer = true
            let rep = try #require(v.bitmapImageRepForCachingDisplay(in: v.bounds))
            v.cacheDisplay(in: v.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    // MARK: 7. marquee: edge autoscroll + content-anchored rectangle

    @Test func autoscrollSpeedRampsWithDistancePastTheEdge() {
        let lo: CGFloat = 120, hi: CGFloat = 1200, z = EdgeAutoscroll.zone
        #expect(EdgeAutoscroll.speed(600, lower: lo, upper: hi) == 0)              // middle
        #expect(EdgeAutoscroll.speed(hi - z - 1, lower: lo, upper: hi) == 0)       // just outside the band
        let atBand = EdgeAutoscroll.speed(hi - z + 1, lower: lo, upper: hi)
        let atEdge = EdgeAutoscroll.speed(hi, lower: lo, upper: hi)
        let past = EdgeAutoscroll.speed(hi + 60, lower: lo, upper: hi)
        #expect(atBand > 0 && atBand < atEdge && atEdge < past)                    // ramps
        #expect(EdgeAutoscroll.speed(hi + 10_000, lower: lo, upper: hi) == EdgeAutoscroll.maxSpeed)
        // symmetric at the start
        #expect(EdgeAutoscroll.speed(lo - 60, lower: lo, upper: hi) == -past)
        // speed is per second, independent of mouse events: 60 frames of 1/60 s = one second of scrolling
        let oneSecond = (0..<60).map { _ in EdgeAutoscroll.step(speed: atEdge, dt: 1.0 / 60) }.reduce(0, +)
        #expect(abs(oneSecond - atEdge) < 1e-6)
        // a stalled frame doesn't jump
        #expect(EdgeAutoscroll.step(speed: atEdge, dt: 2) == atEdge * EdgeAutoscroll.maxStep)
    }

    @Test func marqueeStartStaysOnItsTimeAndTrackWhileTheViewScrolls() {
        let size = CGSize(width: 1300, height: 400)
        let l0 = TimelineLayout(timeline: Timeline(), pixelsPerSecond: 100, scrollTime: 0, scrollY: 0, viewSize: size)
        let start = CGPoint(x: TimelineLayout.headerWidth + 300, y: 150)   // 3 s
        let a = MarqueeAnchor(viewPoint: start, layout: l0)
        #expect(abs(a.time - 3) < 1e-9)
        #expect(a.rect(to: CGPoint(x: 1280, y: 200), l0).minX == start.x)
        // the view scrolled 5 s right and 40 pt down, pointer still at the right edge
        let l1 = TimelineLayout(timeline: Timeline(), pixelsPerSecond: 100, scrollTime: 5, scrollY: 40, viewSize: size)
        let r = a.rect(to: CGPoint(x: 1280, y: 200), l1)
        #expect(abs(r.minX - (start.x - 500)) < 1e-9)   // the start moved left with its content: the rectangle EXTENDS
        #expect(abs(r.minY - 110) < 1e-9)
        #expect(abs(r.maxX - 1280) < 1e-9)
        // and the time span it covers grew by the 5 s scrolled: it still starts at 3 s
        let end0 = l0.time(atX: 1280).seconds, end1 = l1.time(atX: r.maxX).seconds
        #expect(abs(l1.time(atX: r.minX).seconds - 3) < 1e-6)
        #expect(abs(end1 - end0 - 5) < 1e-6)
    }

    // MARK: 6. playback follow

    /// 100 px/s, 1000 px of clip area → 10 s visible, padding 40 px = 0.4 s.
    func run(_ f: inout PlayheadFollow, playing: Bool = true, _ t: Double, scroll: Double, now: Double = 0) -> Double? {
        f.update(isPlaying: playing, playhead: t, scrollTime: scroll, pixelsPerSecond: 100, visibleWidth: 1000, now: now)
    }

    @Test func playStartBringsAnOffscreenPlayheadIn() {
        var f = PlayheadFollow()
        // off-screen to the left → line at the left + padding
        #expect(run(&f, 5, scroll: 20).map { abs($0 - 4.6) < 1e-9 } == true)
        f = PlayheadFollow()
        // off-screen to the right → line at the right − padding
        #expect(run(&f, 35, scroll: 20).map { abs($0 - 25.4) < 1e-9 } == true)
        f = PlayheadFollow()
        // visible → untouched
        #expect(run(&f, 25, scroll: 20) == nil)
        // near 0: never negative
        f = PlayheadFollow()
        #expect(run(&f, 0.1, scroll: 3) == 0)
    }

    @Test func playingPagesAtTheRightEdge() {
        var f = PlayheadFollow()
        #expect(run(&f, 25, scroll: 20) == nil)
        #expect(run(&f, 29.9, scroll: 20) == nil)
        // reaches the right edge (30 s) → next page, line at the left + padding
        #expect(run(&f, 30.02, scroll: 20).map { abs($0 - 29.62) < 1e-9 } == true)
        #expect(run(&f, 30.05, scroll: 29.62) == nil)
    }

    @Test func userScrollDuringPlaybackIsNeverFought() {
        var f = PlayheadFollow()
        #expect(run(&f, 25, scroll: 20) == nil)
        f.userScrolled(isPlaying: true, now: 0)
        #expect(f.manual)
        // the user scrolled far right: the playhead is off-screen to the left — stays there
        #expect(run(&f, 25.1, scroll: 60) == nil)
        // and far left: off-screen to the right / reaching the edge — stays there
        #expect(run(&f, 25.2, scroll: 0) == nil)
        for i in 1...200 { #expect(run(&f, 25.2 + Double(i) * 0.1, scroll: 0) == nil) }   // runs off the right edge
        #expect(f.manual)
        // a seek (or loop back) while playing follows again
        #expect(run(&f, 3, scroll: 60).map { abs($0 - 2.6) < 1e-9 } == true)   // backwards = seek
        #expect(!f.manual)
        // stopping clears it; the next play starts fresh
        f.userScrolled(isPlaying: true, now: 0)
        #expect(run(&f, playing: false, 3.1, scroll: 50) == nil)
        #expect(!f.manual)
        #expect(run(&f, 3.1, scroll: 50).map { abs($0 - 2.7) < 1e-9 } == true)
    }

    /// The user scrolls back to the playhead while playing and lets go: after `resumeAfter` the follow is back (pages
    /// at the right edge again); while they keep scrolling it stays off.
    @Test func followResumesWhenTheUserScrollsBackToThePlayhead() {
        var f = PlayheadFollow()
        #expect(run(&f, 25, scroll: 20, now: 0) == nil)
        f.userScrolled(isPlaying: true, now: 0.1)
        #expect(run(&f, 25.1, scroll: 60, now: 0.2) == nil)              // scrolled away: off-screen, untouched
        f.userScrolled(isPlaying: true, now: 0.5)                        // …and back: line visible at scroll 22
        #expect(run(&f, 25.5, scroll: 22, now: 0.9) == nil)
        #expect(f.manual)                                                 // still scrolling (< 1 s): stays off
        #expect(run(&f, 26, scroll: 22, now: 1.6) == nil)
        #expect(!f.manual)                                                // let go, line on screen: follow resumes
        #expect(run(&f, 31.9, scroll: 22, now: 2) == nil)
        #expect(run(&f, 32.01, scroll: 22, now: 2).map { abs($0 - 31.61) < 1e-9 } == true)   // right edge (32 s): pages
        // scrolled away and left there: never resumes on its own
        f.userScrolled(isPlaying: true, now: 3)
        for i in 1...50 { #expect(run(&f, 32.01 + Double(i) * 0.1, scroll: 80, now: 3 + Double(i) * 0.1) == nil) }
        #expect(f.manual)
    }

    @Test func scrollsWhilePausedDontTurnFollowOff() {
        var f = PlayheadFollow()
        f.userScrolled(isPlaying: false)
        #expect(!f.manual)
        #expect(run(&f, playing: false, 5, scroll: 50) == nil)   // paused: never moves the timeline
        #expect(run(&f, 5, scroll: 50) != nil)                  // play: brings it in
    }
}
