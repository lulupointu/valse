import Foundation

/// Quick cut (TL-048) analysis of one media file, in media (source) time: 1 bit per 10 ms frame, set where speech or
/// speech-level sound was detected (docs/QUICK_CUT.md §4), plus `hasDynamics` (false = nothing qualifies as speech, or the
/// level never rises 10 dB above the floor: such a clip is left untouched). Computed by MontageEngine's
/// `QuickCutAnalyzer`, cached per content hash. ≈ 750 B per minute of media.
public struct QuickCutMask: Sendable, Equatable, Codable {
    /// Frame length (s).
    public static let frameSeconds = 0.01

    public let frameCount: Int
    public let hasDynamics: Bool
    /// Bit k of word k / 64 = frame k is speech.
    public let bits: [UInt64]
    /// Speech runs as frame ranges (derived from `bits`, sorted, disjoint, non-adjacent).
    public let speechRuns: [Range<Int>]

    public init(speech: [Bool], hasDynamics: Bool) {
        var b = [UInt64](repeating: 0, count: (speech.count + 63) / 64)
        for (i, s) in speech.enumerated() where s { b[i >> 6] |= 1 << UInt64(i & 63) }
        self.init(frameCount: speech.count, hasDynamics: hasDynamics, bits: b)
    }

    public init(frameCount: Int, hasDynamics: Bool, bits: [UInt64]) {
        self.frameCount = frameCount
        self.hasDynamics = hasDynamics
        self.bits = bits
        speechRuns = Self.runs(bits, count: frameCount)
    }

    /// Mask of a media without audio (or without decodable audio): no frames.
    public static let empty = QuickCutMask(frameCount: 0, hasDynamics: false, bits: [])

    public var duration: Double { Double(frameCount) * Self.frameSeconds }
    public var hasSpeech: Bool { !speechRuns.isEmpty }

    public subscript(frame: Int) -> Bool {
        guard frame >= 0, frame < frameCount else { return false }
        return bits[frame >> 6] & (1 << UInt64(frame & 63)) != 0
    }

    /// The mask as one Bool per frame.
    public var speech: [Bool] { (0..<frameCount).map { self[$0] } }

    static func runs(_ bits: [UInt64], count: Int) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var i = 0
        while i < count {
            let w = bits[i >> 6] >> UInt64(i & 63)
            if w == 0 { i = (i | 63) + 1; continue }   // rest of the word is blank
            i += w.trailingZeroBitCount
            guard i < count else { break }
            var j = i
            while j < count {
                let x = ~bits[j >> 6] >> UInt64(j & 63)   // blanks from j on
                if x == 0 { j = (j | 63) + 1; continue }
                j += x.trailingZeroBitCount
                break
            }
            j = min(j, count)
            out.append(i..<j)
            i = j
        }
        return out
    }

    // Compact coding: the bits as raw little-endian bytes (base64 in JSON).
    private enum CodingKeys: String, CodingKey { case frames, dynamics, bits }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let n = try c.decode(Int.self, forKey: .frames)
        let d = try c.decode(Data.self, forKey: .bits)
        let words = (n + 63) / 64
        guard n >= 0, d.count == words * 8 else {
            throw DecodingError.dataCorruptedError(forKey: .bits, in: c, debugDescription: "mask size mismatch")
        }
        var b = [UInt64](repeating: 0, count: words)
        b.withUnsafeMutableBytes { dst in d.withUnsafeBytes { src in dst.copyMemory(from: src) } }
        self.init(frameCount: n, hasDynamics: try c.decode(Bool.self, forKey: .dynamics), bits: b.map { UInt64(littleEndian: $0) })
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(frameCount, forKey: .frames)
        try c.encode(hasDynamics, forKey: .dynamics)
        let le = bits.map(\.littleEndian)
        try c.encode(le.withUnsafeBytes { Data($0) }, forKey: .bits)
    }
}
