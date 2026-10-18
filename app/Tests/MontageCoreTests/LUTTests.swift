import Testing
import Foundation
import simd
@testable import MontageCore

@Suite struct LUTTests {
    @Test func parsesCube3DWithRedFastest() throws {
        // 2³ LUT that swaps red and blue.
        var s = "TITLE \"swap\"\n# comment\nLUT_3D_SIZE 2\n"
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { s += "\(b) \(g) \(r)\n" } } }
        let l = try LUT.parseCube(s)
        #expect(l.kind == .threeD && l.size == 2 && l.title == "swap")
        let o = l.apply(SIMD3(1, 0.5, 0))
        #expect(abs(o.x - 0) < 1e-5 && abs(o.y - 0.5) < 1e-5 && abs(o.z - 1) < 1e-5)
    }

    @Test func parsesCube1DAndBakes() throws {
        let l = try LUT.parseCube("LUT_1D_SIZE 3\n0 0 0\n0.25 0.5 0.75\n1 1 1\n")
        #expect(l.kind == .oneD)
        let mid = l.apply(SIMD3(0.5, 0.5, 0.5))
        #expect(abs(mid.x - 0.25) < 1e-5 && abs(mid.z - 0.75) < 1e-5)
        let b = l.baked3D(size: 9)
        #expect(b.kind == .threeD && b.size == 9 && b.values.count == 729)
        #expect(abs(b.apply(SIMD3(0.5, 0.5, 0.5)).y - 0.5) < 1e-4)
    }

    @Test func domainIsRespected() throws {
        let l = try LUT.parseCube("LUT_1D_SIZE 2\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 2 2 2\n0 0 0\n1 1 1\n")
        #expect(abs(l.apply(SIMD3(1, 1, 1)).x - 0.5) < 1e-5)
    }

    @Test func parses3DLBlueFastestWithBitDepth() throws {
        // 2-point mesh, 10-bit: output = inverted colour.
        var s = "0 1023\n"
        for r in 0..<2 { for g in 0..<2 { for b in 0..<2 { s += "\((1 - r) * 1023) \((1 - g) * 1023) \((1 - b) * 1023)\n" } } }
        let l = try LUT.parse3DL(s)
        #expect(l.size == 2)
        let o = l.apply(SIMD3(1, 0, 0.25))
        #expect(abs(o.x - 0) < 1e-4 && abs(o.y - 1) < 1e-4 && abs(o.z - 0.75) < 1e-3)
    }

    @Test func rejectsMalformed() {
        #expect(throws: LUTError.self) { try LUT.parseCube("LUT_3D_SIZE 2\n0 0 0\n") }
        #expect(throws: LUTError.self) { try LUT.parseCube("") }
        #expect(throws: LUTError.self) { try LUT.parseCube("LUT_3D_SIZE 2\n0 0\n") }
    }

    @Test func cubeRoundTrip() throws {
        let l = LUT.make(size: 5) { SIMD3($0.y, $0.z, $0.x) }
        let r = try LUT.parseCube(l.cubeText())
        #expect(r.size == 5)
        for (a, b) in zip(l.values, r.values) { #expect(simd_length(a - b) < 1e-5) }
    }
}
