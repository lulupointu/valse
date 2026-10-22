import Testing
import Foundation
import AppKit
import SwiftUI
import MontageCore
@testable import MontageUI

/// OB-09: video clips use the same bands (name chip, filmstrip, waveform strip) on every visual track, scaled by lane
/// height. OB-08: the magnet toggle draws its own glyph (SF Symbols has no "magnet").
@MainActor @Suite struct TimelineClipBandsTests {
    @Test func bandsDependOnHeightNotTrack() {
        let main = TimelineLayout.height(for: .video, isMain: true)
        let overlayTall = TimelineLayout.height(for: .video, isMain: false, preset: .tall)
        let full = TimelineLayout.videoBands(height: main, hasAudio: true)
        #expect(full.nameBand == 18 && full.audioStrip == 16 && full.hasVolumeLine)
        // A tall overlay lane is drawn exactly like the main track.
        #expect(TimelineLayout.videoBands(height: overlayTall, hasAudio: true) == full)
    }

    @Test func overlayLaneGetsCompactChipAndWaveform() {
        let overlay = TimelineLayout.height(for: .video, isMain: false)
        let b = TimelineLayout.videoBands(height: overlay, hasAudio: true)
        #expect(b.nameBand > 0 && b.audioStrip >= 8)
        #expect(b.chipTop + b.chipHeight <= b.nameBand)
        #expect(overlay - b.nameBand - b.audioStrip >= 16)   // filmstrip keeps room
        #expect(!b.hasVolumeLine)                              // 8 pt strip: clip drag wins over the volume line
        #expect(TimelineLayout.videoBands(height: overlay, hasAudio: false).audioStrip == 0)
    }

    @Test func shortLanesDropTheBands() {
        let b = TimelineLayout.videoBands(height: 26, hasAudio: true)
        #expect(b.nameBand == 0 && b.audioStrip == 0)
    }

    @Test func magnetGlyphExistsAndIsDrawn() {
        let p = MagnetShape().path(in: CGRect(x: 0, y: 0, width: 14, height: 14))
        #expect(!p.isEmpty)
        let box = p.boundingRect
        #expect(box.width > 6 && box.height > 10 && box.maxX <= 14 && box.maxY <= 14)
    }
}
