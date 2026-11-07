import Foundation
import Testing
@testable import ValseCore

@Suite struct FadeShapeTests {
    @Test func curveEndpointsAndMidpoints() {
        for s in FadeShape.allCases {
            #expect(abs(s.gain(0)) < 1e-12)
            #expect(abs(s.gain(1) - 1) < 1e-12)
        }
        #expect(abs(FadeShape.linear.gain(0.25) - 0.25) < 1e-12)
        #expect(abs(FadeShape.plus3dB.gain(0.5) - sin(.pi / 4)) < 1e-12)        // −3 dB at the middle
        #expect(abs(FadeShape.sCurve.gain(0.5) - 0.5) < 1e-12)
        #expect(abs(FadeShape.minus3dB.gain(0.5) - (1 - cos(.pi / 4))) < 1e-12)
        // ordering: +3 dB is above linear, −3 dB below
        #expect(FadeShape.plus3dB.gain(0.3) > FadeShape.linear.gain(0.3))
        #expect(FadeShape.minus3dB.gain(0.3) < FadeShape.linear.gain(0.3))
    }

    @Test func progressInvertsTheCurve() {
        for s in FadeShape.allCases {
            let t = s.progress(reaching: 0.2)
            #expect(abs(s.gain(t) - 0.2) < 1e-6)
        }
    }

    @Test func fadeGainRisesAndFallsAndClamps() {
        var a = AudioProps()
        a.fadeIn = Time(1); a.fadeOut = Time(1)
        a.fadeInShape = .linear; a.fadeOutShape = .plus3dB
        let d = Time(4)
        #expect(a.fadeGain(at: .zero, clipDuration: d) == 0)
        #expect(abs(a.fadeGain(at: Time(0.5), clipDuration: d) - 0.5) < 1e-9)
        #expect(a.fadeGain(at: Time(2), clipDuration: d) == 1)
        #expect(abs(a.fadeGain(at: Time(3.5), clipDuration: d) - cos(.pi / 4)) < 1e-9)   // equal-power out
        #expect(abs(a.fadeGain(at: d, clipDuration: d)) < 1e-9)
        // overlapping fades are clamped: fade-in wins, the sum never exceeds the clip
        a.fadeIn = Time(3); a.fadeOut = Time(3)
        let f = a.effectiveFades(clipDuration: d)
        #expect(f.fadeIn == Time(3) && f.fadeOut == Time(1))
    }

    @Test func newFadesAreEqualPowerAndOldFilesDecodeLinear() throws {
        #expect(AudioProps().fadeInShape == .plus3dB)
        let old = try JSONDecoder().decode(AudioProps.self, from: Data(#"{"volume":1,"fadeIn":0,"fadeOut":0}"#.utf8))
        #expect(old.fadeInShape == .linear && old.fadeOutShape == .linear)
        var a = AudioProps(); a.fadeOutShape = .sCurve
        let back = try JSONDecoder().decode(AudioProps.self, from: JSONEncoder().encode(a))
        #expect(back.fadeInShape == .plus3dB && back.fadeOutShape == .sCurve)
    }
}
