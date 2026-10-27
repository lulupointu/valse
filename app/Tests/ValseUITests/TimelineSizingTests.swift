import Testing
import Foundation
import CoreGraphics
import ValseCore
@testable import ValseUI

/// TL-SIZE-PRESETS (owner 2026-10-25): "Track height ▸ Short / Default / Tall" selects exact video lane / audio share /
/// audio lane sizes from `TimelineSizing`; thin lanes keep 24 pt × the preset scale; clip bands follow the row's preset.
@MainActor @Suite struct TimelineSizingTests {
    @Test func ownerPresetTable() {
        #expect(TimelineSizing.preset(.short) == TimelineSizing(videoLaneHeight: 70, audioStripFraction: 0.4, audioLaneHeight: 35))
        #expect(TimelineSizing.preset(.standard) == TimelineSizing(videoLaneHeight: 120, audioStripFraction: 0.3, audioLaneHeight: 60))
        #expect(TimelineSizing.preset(.tall) == TimelineSizing(videoLaneHeight: 170, audioStripFraction: 0.3, audioLaneHeight: 85))
        #expect(TimelineSizing.preset(nil) == .standard)
    }

    @Test func laneHeightsPerPreset() {
        let expected: [(TrackHeight?, CGFloat, CGFloat, CGFloat)] = [
            (nil, 120, 60, 24), (.standard, 120, 60, 24), (.short, 70, 35, 16), (.tall, 170, 85, 36)]
        for (p, video, audio, thin) in expected {
            #expect(TimelineLayout.height(for: .video, isMain: true, preset: p) == video)
            #expect(TimelineLayout.height(for: .video, isMain: false, preset: p) == video)
            #expect(TimelineLayout.height(for: .audio, isMain: false, preset: p) == audio)
            for k in [TrackKind.text, .sticker, .effect, .filter, .adjustment] {
                #expect(TimelineLayout.height(for: k, isMain: false, preset: p) == thin)
            }
        }
    }

    @Test func layoutRowsAndBandsFollowEachTracksPreset() {
        var tl = Timeline()
        var short = Track(kind: .video); short.heightPreset = .short
        var tallAudio = Track(kind: .audio); tallAudio.heightPreset = .tall
        tl.tracks = [Track(kind: .video, isMain: true), short, tallAudio, Track(kind: .audio)]
        let l = TimelineLayout(timeline: tl, pixelsPerSecond: 50, scrollTime: 0, scrollY: 0, viewSize: CGSize(width: 1000, height: 600))
        // row order: overlay, main, audio tracks
        #expect(l.rows.map(\.height) == [70, 120, 85, 60])
        #expect(l.rows.map(\.preset) == [.short, .standard, .tall, .standard])
        for i in 1..<l.rows.count { #expect(l.rows[i].y == l.rows[i - 1].maxY + TimelineLayout.rowGap) }
        // audio strip: 40 % of a short lane, 30 % of a default one
        let s = l.videoBands(of: l.rows[0], hasAudio: true)
        #expect(s.audioStrip == 28 && s.hasVolumeLine)
        let m = l.videoBands(of: l.rows[1], hasAudio: true)
        #expect(m.audioStrip == 36 && m.hasVolumeLine)
        #expect(l.videoBands(of: l.rows[1], hasAudio: false).audioStrip == 0)
        #expect(TimelineLayout.videoBands(height: 170, hasAudio: true, sizing: .tall).audioStrip == 51)
        // hit-testing follows the rows
        #expect(l.rowIndex(atY: l.rows[1].y + 110) == 1)
    }

    @Test func zeroAudioShareMeansNoStrip() {
        let none = TimelineSizing(videoLaneHeight: 120, audioStripFraction: 0, audioLaneHeight: 60)
        #expect(TimelineLayout.videoBands(height: 120, hasAudio: true, sizing: none).audioStrip == 0)
        #expect(TimelineLayout.videoBands(height: 40, hasAudio: true, sizing: none).audioStrip == 0)
        #expect(!TimelineLayout.videoBands(height: 120, hasAudio: true, sizing: none).hasVolumeLine)
    }

    /// The former TL-SIZE-TUNER preference keys are never read: values stored on a machine do not change the lanes.
    @Test func tunerPreferencesAreIgnored() {
        let d = AppDefaults.store
        let keys = ["valse.timeline.sizing.video", "valse.timeline.sizing.audioShare", "valse.timeline.sizing.audioLane"]
        let saved = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } } }
        d.set(200.0, forKey: keys[0]); d.set(0.5, forKey: keys[1]); d.set(150.0, forKey: keys[2])
        #expect(TimelineLayout.height(for: .video, isMain: true) == 120)
        #expect(TimelineLayout.height(for: .audio, isMain: false) == 60)
        #expect(TimelineLayout.videoBands(height: 120, hasAudio: true).audioStrip == 36)
    }
}
