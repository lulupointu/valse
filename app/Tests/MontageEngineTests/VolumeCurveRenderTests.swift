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
}
