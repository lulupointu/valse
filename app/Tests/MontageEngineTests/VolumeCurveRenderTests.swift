@preconcurrency import AVFoundation
import Testing
import MontageCore
@testable import MontageEngine

/// C3b: the audio render follows the volume curve the timeline draws (`KeyframeTrack.value`), eased spans included.
@Suite struct VolumeCurveRenderTests {
    /// Gain the mix applies at timeline time `t` (linear interpolation inside the ramp covering it).
    static func mixGain(_ p: AVMutableAudioMixInputParameters, at t: Time) -> Double? {
        var cursor = CMTime.zero
        while true {
            var a: Float = 0, b: Float = 0
            var r = CMTimeRange()
            guard p.getVolumeRamp(for: cursor, startVolume: &a, endVolume: &b, timeRange: &r), r.duration.seconds > 0 else { return nil }
            if t.seconds >= r.start.seconds, t.seconds <= r.end.seconds {
                let f = (t.seconds - r.start.seconds) / r.duration.seconds
                return Double(a) + (Double(b) - Double(a)) * f
            }
            cursor = r.end
        }
    }

    @Test(arguments: [Easing.linear, .easeInOut, .easeIn])
    func renderMatchesTheDrawnCurve(_ easing: Easing) {
        var c = Clip(content: .solid(RGBA(1, 1, 1)), start: Time(2), duration: Time(10))
        c.keyframes[ParamKey.volume.raw] = KeyframeTrack([Keyframe(time: 1, value: .scalar(1), easing: easing),
                                                          Keyframe(time: 7, value: .scalar(0.1))])
        let p = AVMutableAudioMixInputParameters()
        CompositionBuilder.applyVolume(c, to: p)
        for local in stride(from: 0.5, through: 9.5, by: 0.37) {
            let want = c.value(.volume, at: Time(local))!.scalar!
            let got = Self.mixGain(p, at: c.start + Time(local))
            #expect(got != nil)
            // within 0.4 dB of what the timeline draws
            #expect(abs(AudioProps.decibels(got ?? 0) - AudioProps.decibels(want)) < 0.4, "t \(local) \(easing): \(got ?? -1) vs \(want)")
        }
    }

    /// Clips overlapping on one lane (bad layout) must not give overlapping ramps: AVFoundation throws on them
    /// (quick cut crash, 1023 project). The later clip's ramps start where the earlier one ends.
    @Test func overlappingClipsOnALaneGiveDisjointRamps() {
        var a = Clip(content: .solid(RGBA(1, 1, 1)), start: Time(0), duration: Time(4))
        a.audio.fadeOut = Time(2)
        var b = Clip(content: .solid(RGBA(1, 1, 1)), start: Time(3), duration: Time(4))
        b.audio.fadeIn = Time(2)
        let p = AVMutableAudioMixInputParameters()
        let floor = CompositionBuilder.applyVolume(a, to: p)
        #expect(floor == Time(4))
        #expect(CompositionBuilder.applyVolume(b, to: p, after: floor) == Time(7))
        var cursor = CMTime.zero, end = CMTime.zero
        var x: Float = 0, y: Float = 0
        var r = CMTimeRange()
        while p.getVolumeRamp(for: cursor, startVolume: &x, endVolume: &y, timeRange: &r), r.duration > .zero, r.duration.isNumeric {   // last = hold at 0
            #expect(CMTimeCompare(r.start, end) >= 0, "ramp \(r.start.seconds) starts before \(end.seconds)")
            end = r.end; cursor = r.end
        }
        #expect(end == Time(7).cmTime)
        // after a's end, b's fade-in continues on its own curve (1.5 s into 2 s)
        #expect(abs((Self.mixGain(p, at: Time(4.5)) ?? -1) - 0.75) < 0.01)
    }
}
