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
        let overlay = TimelineLayout.height(for: .video, isMain: false)
        let full = TimelineLayout.videoBands(height: main, hasAudio: true)
        // TL-IMOVIE-HEIGHT: no name band (the chip sits over the filmstrip), audio strip = 25 % of the lane
        #expect(full.nameBand == 0 && full.audioStrip == 28 && full.hasVolumeLine)
        #expect(full.chipTop + full.chipHeight < main - full.audioStrip)
        // An overlay lane is drawn exactly like the main track.
        #expect(TimelineLayout.videoBands(height: overlay, hasAudio: true) == full)
        #expect(TimelineLayout.videoBands(height: overlay, hasAudio: false).audioStrip == 0)
    }

    /// TL-IMOVIE-HEIGHT (owner, iMovie measurements): main and overlay video lanes 110 pt (~83 pt filmstrip + ~27 pt
    /// waveform), audio lanes 83 pt, thin lanes unchanged; the Track height preset scales all of them.
    @Test func iMovieLaneHeights() {
        #expect(TimelineLayout.height(for: .video, isMain: true) == 110)
        #expect(TimelineLayout.height(for: .video, isMain: false) == 110)
        #expect(TimelineLayout.height(for: .audio, isMain: false) == 83)
        for k in [TrackKind.text, .sticker, .effect, .filter, .adjustment] { #expect(TimelineLayout.height(for: k, isMain: false) == 24) }
        #expect(TimelineLayout.height(for: .video, isMain: true, preset: .short) == 72)
        #expect(TimelineLayout.height(for: .video, isMain: false, preset: .tall) == 165)
        #expect(TimelineLayout.height(for: .audio, isMain: false, preset: .short) == 54)
        let short = TimelineLayout.videoBands(height: 72, hasAudio: true)
        #expect(short.audioStrip == 18 && short.hasVolumeLine)
        // audio clips: the waveform / volume line fill the clip
        let wr = TimelineLayout.audioWaveRect(CGRect(x: 10, y: 100, width: 50, height: 83))
        #expect(wr.minY == 102 && wr.height == 79)
        // waveform bars on a dB scale: 0 dBFS fills the area, −21 dB half, −42 dB and silence nothing
        #expect(TimelineLayout.waveformLevel(1) == 1 && TimelineLayout.waveformLevel(2) == 1)
        #expect(abs(TimelineLayout.waveformLevel(pow(10, -21.0 / 20)) - 0.5) < 1e-9)
        #expect(TimelineLayout.waveformLevel(0.001) == 0 && TimelineLayout.waveformLevel(0) == 0)
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
