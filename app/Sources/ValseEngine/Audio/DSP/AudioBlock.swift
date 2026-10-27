import Foundation

/// Non-interleaved Float32 audio block (views into buffers owned by the caller). Never allocates.
public struct AudioBlock {
    public let channels: Int
    public let frames: Int
    let pointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>

    public init(channels: Int, frames: Int, pointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>) {
        self.channels = channels; self.frames = frames; self.pointers = pointers
    }
    @inline(__always) public subscript(_ c: Int) -> UnsafeMutablePointer<Float> { pointers[c] }

    /// A sub-range [offset, offset+count) of the same channels (uses `scratch` for the pointer table).
    public func slice(_ offset: Int, _ count: Int, scratch: UnsafeMutablePointer<UnsafeMutablePointer<Float>>) -> AudioBlock {
        for c in 0..<channels { scratch[c] = pointers[c] + offset }
        return AudioBlock(channels: channels, frames: count, pointers: scratch)
    }
}

/// Owned multichannel float buffer (tests, offline rendering, analysis).
public final class AudioBuffer: @unchecked Sendable {
    public let channels: Int
    public let frames: Int
    public let sampleRate: Double
    private let table: UnsafeMutablePointer<UnsafeMutablePointer<Float>>

    public init(channels: Int, frames: Int, sampleRate: Double) {
        self.channels = channels; self.frames = frames; self.sampleRate = sampleRate
        table = .allocate(capacity: max(channels, 1))
        for c in 0..<channels {
            table[c] = .allocate(capacity: max(frames, 1))
            table[c].initialize(repeating: 0, count: max(frames, 1))
        }
    }

    public convenience init(_ data: [[Float]], sampleRate: Double) {
        self.init(channels: data.count, frames: data.first?.count ?? 0, sampleRate: sampleRate)
        for c in 0..<channels { data[c].withUnsafeBufferPointer { table[c].update(from: $0.baseAddress!, count: min(frames, $0.count)) } }
    }

    /// `seconds` of `f(channel, time)` sampled at `sampleRate`.
    public convenience init(seconds: Double, sampleRate: Double = 48000, channels: Int = 2, _ f: (Int, Double) -> Float) {
        self.init(channels: channels, frames: Int(seconds * sampleRate), sampleRate: sampleRate)
        for c in 0..<channels { for i in 0..<frames { table[c][i] = f(c, Double(i) / sampleRate) } }
    }

    deinit {
        for c in 0..<channels { table[c].deallocate() }
        table.deallocate()
    }

    public func copy() -> AudioBuffer {
        let b = AudioBuffer(channels: channels, frames: frames, sampleRate: sampleRate)
        for c in 0..<channels { b.table[c].update(from: table[c], count: frames) }
        return b
    }

    public func pointer(_ c: Int) -> UnsafeMutablePointer<Float> { table[c] }
    public subscript(_ c: Int, _ i: Int) -> Float {
        get { table[c][i] }
        set { table[c][i] = newValue }
    }
    public func channel(_ c: Int) -> [Float] { Array(UnsafeBufferPointer(start: table[c], count: frames)) }

    /// The whole buffer as one block (valid while the buffer is alive).
    public var block: AudioBlock { AudioBlock(channels: channels, frames: frames, pointers: table) }

    /// Feeds the buffer to `body` in chunks of `chunk` frames (simulates real-time block processing).
    public func process(chunk: Int = 512, _ body: (AudioBlock) -> Void) {
        let t = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: max(channels, 1))
        defer { t.deallocate() }
        var o = 0
        while o < frames {
            let n = min(chunk, frames - o)
            for c in 0..<channels { t[c] = table[c] + o }
            body(AudioBlock(channels: channels, frames: n, pointers: t))
            o += n
        }
    }

    public func rms(channel: Int = 0, from: Int = 0, to: Int? = nil) -> Double {
        let e = min(to ?? frames, frames), s0 = max(0, from)
        guard e > s0 else { return 0 }
        var s = 0.0
        for i in s0..<e { let v = Double(table[channel][i]); s += v * v }
        return sqrt(s / Double(e - s0))
    }

    public func rms(seconds a: Double, _ b: Double, channel: Int = 0) -> Double {
        rms(channel: channel, from: Int(a * sampleRate), to: Int(b * sampleRate))
    }

    public var peak: Float {
        var m: Float = 0
        for c in 0..<channels { for i in 0..<frames { m = max(m, abs(table[c][i])) } }
        return m
    }
}

public func dB(_ linear: Double) -> Double { 20 * log10(max(linear, 1e-12)) }
