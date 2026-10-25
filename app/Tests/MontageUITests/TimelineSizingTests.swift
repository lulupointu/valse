import Testing
import Foundation
import CoreGraphics
import MontageCore
@testable import MontageUI

/// TL-SIZE-TUNER: TimelineLayout reads its lane sizes from `TimelineSizing` (tunable live in the toolbar's Sizes
/// popover); the Track height preset scales them; clip bands follow the audio share. Never touches the shared prefs.
@MainActor @Suite struct TimelineSizingTests {
    let custom = TimelineSizing(videoLaneHeight: 150, audioStripFraction: 0.4, audioLaneHeight: 60)

    @Test func defaultsAreTheIMovieSizes() {
        #expect(TimelineSizing.defaults == TimelineSizing(videoLaneHeight: 110, audioStripFraction: 0.25, audioLaneHeight: 83))
        #expect(TimelineLayout.height(for: .video, isMain: true, sizing: .defaults) == 110)
        #expect(TimelineLayout.height(for: .audio, isMain: false, sizing: .defaults) == 83)
    }

    @Test func laneHeightsFollowTheSizing() {
        #expect(TimelineLayout.height(for: .video, isMain: true, sizing: custom) == 150)
        #expect(TimelineLayout.height(for: .video, isMain: false, sizing: custom) == 150)
        #expect(TimelineLayout.height(for: .audio, isMain: false, sizing: custom) == 60)
        #expect(TimelineLayout.height(for: .text, isMain: false, sizing: custom) == 24)
        // presets scale the tuned sizes
        #expect(TimelineLayout.height(for: .video, isMain: true, preset: .short, sizing: custom) == (150 * CGFloat(TrackHeight.short.scale)).rounded())
        #expect(TimelineLayout.height(for: .audio, isMain: false, preset: .tall, sizing: custom) == (60 * CGFloat(TrackHeight.tall.scale)).rounded())
    }

    @Test func layoutRowsAndBandsUseTheSizing() {
        var tl = Timeline()
        tl.tracks = [Track(kind: .video, isMain: true), Track(kind: .video), Track(kind: .audio)]
        let l = TimelineLayout(timeline: tl, pixelsPerSecond: 50, scrollTime: 0, scrollY: 0,
                               viewSize: CGSize(width: 1000, height: 600), sizing: custom)
        #expect(l.sizing == custom)
        #expect(l.rows.map(\.height) == [150, 150, 60])
        // rows stack with the tuned heights
        #expect(l.rows[1].y == l.rows[0].maxY + TimelineLayout.rowGap)
        #expect(l.rows[2].y == l.rows[1].maxY + TimelineLayout.rowGap)
        let b = l.videoBands(of: l.rows[0], hasAudio: true)
        #expect(b.audioStrip == 60 && b.hasVolumeLine)
        #expect(l.videoBands(of: l.rows[0], hasAudio: false).audioStrip == 0)
        // hit-testing follows the rows: a point in the lower part of the tall main lane is on that row
        #expect(l.rowIndex(atY: l.rows[0].y + 140) == 0)
    }

    @Test func zeroAudioShareMeansNoStrip() {
        let none = TimelineSizing(videoLaneHeight: 110, audioStripFraction: 0, audioLaneHeight: 83)
        #expect(TimelineLayout.videoBands(height: 110, hasAudio: true, sizing: none).audioStrip == 0)
        #expect(TimelineLayout.videoBands(height: 40, hasAudio: true, sizing: none).audioStrip == 0)
        #expect(!TimelineLayout.videoBands(height: 110, hasAudio: true, sizing: none).hasVolumeLine)
    }

    @Test func clampingAndPersistence() throws {
        let wild = TimelineSizing(videoLaneHeight: 999.4, audioStripFraction: -1, audioLaneHeight: 47.6)
        #expect(wild.clamped == TimelineSizing(videoLaneHeight: 220, audioStripFraction: 0, audioLaneHeight: 48))
        let name = "montage.test.sizing.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        #expect(TimelineSizing.load(from: d) == .defaults)
        TimelineSizing.store(custom, in: d)
        #expect(TimelineSizing.load(from: d) == custom)
        TimelineSizing.store(.defaults, in: d)
        #expect(d.object(forKey: TimelineSizing.keys.video) == nil)
        #expect(TimelineSizing.load(from: d) == .defaults)
    }

    @Test func summaryLine() {
        // language-neutral (other suites switch the language): whole points, the share as a whole percent
        #expect(custom.summary == tr("sizes.summary", 150, 40, 60))
        let odd = TimelineSizing(videoLaneHeight: 110, audioStripFraction: 0.333, audioLaneHeight: 83)
        #expect(odd.summary == tr("sizes.summary", 110, 33, 83))
    }
}
