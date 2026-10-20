import Testing
import Foundation
import AppKit
import MontageCore
@testable import MontageUI

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
        MontageBootstrap.registerResources()
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
        MontageBootstrap.registerResources()
        let fr = L10n.shared.strings(for: "fr")
        #expect(fr["tab.captions"] == "Sous-titres")
        #expect(fr["inspector.tab.captions"] == "Sous-titres")
        #expect(fr["captions.tab"] == "Sous-titres")
        #expect(fr["captions.playFrom"]?.contains("ce sous-titre") == true)
        // "légende" stays only where it means a social-media post caption (credit line of CC BY music)
        let left = fr.filter { $0.value.lowercased().contains("légende") }.map(\.key).sorted()
        #expect(left == ["audio.license.creditBody"], "still 'légende': \(left)")
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

    // MARK: 6. playback follow

    /// 100 px/s, 1000 px of clip area → 10 s visible, padding 40 px = 0.4 s.
    func run(_ f: inout PlayheadFollow, playing: Bool = true, _ t: Double, scroll: Double) -> Double? {
        f.update(isPlaying: playing, playhead: t, scrollTime: scroll, pixelsPerSecond: 100, visibleWidth: 1000)
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
        f.userScrolled(isPlaying: true)
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
        f.userScrolled(isPlaying: true)
        #expect(run(&f, playing: false, 3.1, scroll: 50) == nil)
        #expect(!f.manual)
        #expect(run(&f, 3.1, scroll: 50).map { abs($0 - 2.7) < 1e-9 } == true)
    }

    @Test func scrollsWhilePausedDontTurnFollowOff() {
        var f = PlayheadFollow()
        f.userScrolled(isPlaying: false)
        #expect(!f.manual)
        #expect(run(&f, playing: false, 5, scroll: 50) == nil)   // paused: never moves the timeline
        #expect(run(&f, 5, scroll: 50) != nil)                  // play: brings it in
    }
}
