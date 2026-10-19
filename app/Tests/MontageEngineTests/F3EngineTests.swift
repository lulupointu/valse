import Testing
import Foundation
import CoreGraphics
@preconcurrency import Metal
import MontageCore
import MontageEffects
@testable import MontageEngine
import MontageTestSupport

/// Finisher F3 render tests (text stroke position, …).
@Suite(.serialized) struct F3TextRenderTests {
    let h = TextRenderTests()

    /// TX-005: inside keeps the glyph's outer edge, centre grows it by half the width, outside by the whole width.
    @Test func strokePositionInsideCentreOutside() {
        let ink: (RGBA) -> Bool = { $0.luma > 0.2 || TextRenderTests.isRed($0) }
        let plain = h.box(h.render(h.text("O")), ink)!
        func styled(_ p: TextStrokePosition) -> Bitmap {
            h.render(h.text("O") { $0.strokeColor = RGBA(1, 0, 0); $0.strokeWidth = 0.1; $0.strokePosition = p })
        }
        let outside = styled(.outside), centre = styled(.center), inside = styled(.inside)
        let wOut = h.box(outside, ink)!.width, wMid = h.box(centre, ink)!.width, wIn = h.box(inside, ink)!.width
        // em = 72 px → w = 7.2 px each side
        #expect(abs(wIn - plain.width) <= 2, "inside \(wIn) vs plain \(plain.width)")
        #expect(abs(wMid - (plain.width + 7.2)) <= 3, "centre \(wMid)")
        #expect(abs(wOut - (plain.width + 14.4)) <= 3, "outside \(wOut)")
        // every position shows the stroke colour; inside eats into the white fill
        let white: (RGBA) -> Bool = { $0.r > 0.9 && $0.g > 0.9 }
        for img in [outside, centre, inside] { #expect(h.count(img, TextRenderTests.isRed) > 300) }
        #expect(h.count(inside, white) < h.count(outside, white) * 3 / 4)
    }

    @Test func strokePositionRoundTripsAndDefaultsToOutside() throws {
        var t = TextContent(string: "A"); t.strokePosition = .inside
        let back = try JSONDecoder().decode(TextContent.self, from: JSONEncoder().encode(t))
        #expect(back.strokePosition == .inside)
        let old = try JSONDecoder().decode(TextContent.self, from: Data(#"{"string":"A","strokeWidth":0.1}"#.utf8))
        #expect(old.strokePosition == .outside)
        t.strokeWidth = 0.1
        #expect(t.strokeExtentEm == 0)
        t.strokePosition = .center
        #expect(abs(t.strokeExtentEm - 0.05) < 1e-9)
    }
}
