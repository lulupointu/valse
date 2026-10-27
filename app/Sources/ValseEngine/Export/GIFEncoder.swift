import Foundation

/// Streaming animated-GIF writer (GIF89a, looping). Pure Swift, no GPL code: per-frame median-cut palette (256 colours
/// from a 15-bit histogram), Floyd–Steinberg dithering, and a standard variable-width LZW coder. Frames are written to
/// disk as they arrive, so memory stays at one frame regardless of length.
public final class GIFEncoder {
    public let width: Int, height: Int
    private let handle: FileHandle
    private var frameIndex = 0
    private var buffer = Data()
    /// Centisecond clock (GIF delays are integer 1/100 s): frame i ends at round((i+1)·100/fps).
    private let fps: Double
    public var dither = true

    public init(url: URL, width: Int, height: Int, fps: Double, loopCount: Int = 0) throws {
        precondition(width > 0 && height > 0 && width < 65536 && height < 65536)
        self.width = width; self.height = height; self.fps = fps
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        handle.truncateFile(atOffset: 0)
        var h = Data("GIF89a".utf8)
        h.le16(width); h.le16(height)
        h.append(contentsOf: [0x00, 0x00, 0x00])            // no global colour table, bg 0, aspect 0
        // NETSCAPE2.0 looping extension
        h.append(contentsOf: [0x21, 0xFF, 0x0B]); h.append(contentsOf: Array("NETSCAPE2.0".utf8))
        h.append(contentsOf: [0x03, 0x01]); h.le16(loopCount); h.append(0x00)
        handle.write(h)
    }

    /// Delay of frame `i` in centiseconds (drift-free rounding; at least 2 cs — browsers clamp smaller delays).
    func delay(ofFrame i: Int) -> Int {
        let a = Int((Double(i) * 100 / fps).rounded()), b = Int((Double(i + 1) * 100 / fps).rounded())
        return max(2, b - a)
    }

    /// Adds one frame of 8-bit BGRA pixels (`bytesPerRow` may include padding). Alpha is ignored.
    public func addFrame(bgra: UnsafeRawPointer, bytesPerRow: Int) {
        let n = width * height
        let px = bgra.assumingMemoryBound(to: UInt8.self)
        // 1. histogram on 5-bit channels
        var hist = [UInt32](repeating: 0, count: 32768)
        for y in stride(from: 0, to: height, by: 1) {
            let row = px + y * bytesPerRow
            for x in 0..<width {
                let b = Int(row[4 * x]) >> 3, g = Int(row[4 * x + 1]) >> 3, r = Int(row[4 * x + 2]) >> 3
                hist[(r << 10) | (g << 5) | b] &+= 1
            }
        }
        let palette = Self.medianCut(hist, maxColors: 256)
        // 2. 15-bit colour → nearest palette index, filled lazily (only colours that occur, incl. dithered ones)
        var lut = [Int16](repeating: -1, count: 32768)
        func index(_ key: Int) -> UInt8 {
            let v = lut[key]
            if v >= 0 { return UInt8(v) }
            let i = Self.nearest(palette, ((key >> 10) & 31) << 3 | 4, ((key >> 5) & 31) << 3 | 4, (key & 31) << 3 | 4)
            lut[key] = Int16(i)
            return i
        }
        // 3. map (+ Floyd–Steinberg)
        var indices = [UInt8](repeating: 0, count: n)
        if dither {
            var err = [Int32](repeating: 0, count: (width + 2) * 3 * 2)
            let stride = (width + 2) * 3
            for y in 0..<height {
                let cur = (y & 1) * stride, nxt = ((y + 1) & 1) * stride
                for i in 0..<stride { err[nxt + i] = 0 }
                let row = px + y * bytesPerRow
                for x in 0..<width {
                    let e = cur + (x + 1) * 3
                    let r = clamp8(Int32(row[4 * x + 2]) + err[e] / 16)
                    let g = clamp8(Int32(row[4 * x + 1]) + err[e + 1] / 16)
                    let b = clamp8(Int32(row[4 * x]) + err[e + 2] / 16)
                    let idx = index((Int(r) >> 3) << 10 | (Int(g) >> 3) << 5 | Int(b) >> 3)
                    indices[y * width + x] = idx
                    let p = palette[Int(idx)]
                    let dr = r - Int32(p.0), dg = g - Int32(p.1), db = b - Int32(p.2)
                    // right 7, below-left 3, below 5, below-right 1 (/16)
                    err[e + 3] += dr * 7; err[e + 4] += dg * 7; err[e + 5] += db * 7
                    let bl = nxt + x * 3
                    err[bl] += dr * 3; err[bl + 1] += dg * 3; err[bl + 2] += db * 3
                    err[bl + 3] += dr * 5; err[bl + 4] += dg * 5; err[bl + 5] += db * 5
                    err[bl + 6] += dr; err[bl + 7] += dg; err[bl + 8] += db
                }
            }
        } else {
            for y in 0..<height {
                let row = px + y * bytesPerRow
                for x in 0..<width {
                    indices[y * width + x] = index((Int(row[4 * x + 2]) >> 3) << 10 | (Int(row[4 * x + 1]) >> 3) << 5 | Int(row[4 * x]) >> 3)
                }
            }
        }
        // 4. write: graphic control ext, image descriptor with local table, LZW data
        var d = Data()
        d.append(contentsOf: [0x21, 0xF9, 0x04, 0x04]); d.le16(delay(ofFrame: frameIndex)); d.append(contentsOf: [0x00, 0x00])
        d.append(0x2C); d.le16(0); d.le16(0); d.le16(width); d.le16(height)
        d.append(0x87)                                       // local colour table, 256 entries (2^(7+1))
        for i in 0..<256 {
            let c = i < palette.count ? palette[i] : (0, 0, 0)
            d.append(contentsOf: [c.0, c.1, c.2])
        }
        d.append(0x08)                                       // LZW minimum code size
        Self.lzw(indices, minCodeSize: 8, into: &d)
        handle.write(d)
        frameIndex += 1
    }

    public var framesWritten: Int { frameIndex }

    public func finish() {
        handle.write(Data([0x3B]))
        try? handle.close()
    }

    @inline(__always) private func clamp8(_ v: Int32) -> Int32 { min(255, max(0, v)) }

    // MARK: Palette

    typealias RGB = (UInt8, UInt8, UInt8)

    /// Median cut over the populated 15-bit histogram bins (weighted by count): repeatedly split the box with the
    /// largest span × population on its widest channel at the weighted median.
    static func medianCut(_ hist: [UInt32], maxColors: Int) -> [RGB] {
        var keys: [Int] = [], counts: [UInt32] = []
        for k in 0..<hist.count where hist[k] > 0 { keys.append(k); counts.append(hist[k]) }
        if keys.isEmpty { return [(0, 0, 0)] }
        @inline(__always) func ch(_ k: Int, _ c: Int) -> Int { c == 0 ? (k >> 10) & 31 : (c == 1 ? (k >> 5) & 31 : k & 31) }
        struct Box { var lo: Int; var hi: Int; var channel: Int; var span: Int; var pop: UInt64 }
        func box(_ lo: Int, _ hi: Int) -> Box {
            var mn = (31, 31, 31), mx = (0, 0, 0), pop: UInt64 = 0
            for i in lo..<hi {
                let k = keys[i]
                let r = (k >> 10) & 31, g = (k >> 5) & 31, b = k & 31
                mn = (min(mn.0, r), min(mn.1, g), min(mn.2, b)); mx = (max(mx.0, r), max(mx.1, g), max(mx.2, b))
                pop += UInt64(counts[i])
            }
            let spans = [mx.0 - mn.0, mx.1 - mn.1, mx.2 - mn.2]
            let c = spans[1] >= spans[0] && spans[1] >= spans[2] ? 1 : (spans[0] >= spans[2] ? 0 : 2)
            return Box(lo: lo, hi: hi, channel: c, span: spans[c], pop: pop)
        }
        var boxes = [box(0, keys.count)]
        while boxes.count < maxColors {
            var best = -1, bestScore = 0.0
            for (i, b) in boxes.enumerated() where b.hi - b.lo > 1 && b.span > 0 {
                let score = Double(b.span) * Double(b.pop)
                if score > bestScore { bestScore = score; best = i }
            }
            if best < 0 { break }
            let b = boxes[best]
            // sort the box's bins on its channel (indices sorted together)
            let order = (b.lo..<b.hi).sorted { ch(keys[$0], b.channel) < ch(keys[$1], b.channel) }
            let ks = order.map { keys[$0] }, cs = order.map { counts[$0] }
            for (j, i) in (b.lo..<b.hi).enumerated() { keys[i] = ks[j]; counts[i] = cs[j] }
            var acc: UInt64 = 0, cut = b.lo + 1
            for j in b.lo..<b.hi {
                acc += UInt64(counts[j])
                if acc * 2 >= b.pop { cut = min(max(j + 1, b.lo + 1), b.hi - 1); break }
            }
            boxes[best] = box(b.lo, cut)
            boxes.append(box(cut, b.hi))
        }
        return boxes.map { b in
            var s0: UInt64 = 0, s1: UInt64 = 0, s2: UInt64 = 0
            for j in b.lo..<b.hi {
                let k = keys[j], w = UInt64(counts[j])
                s0 += UInt64(ch(k, 0) << 3 | 4) * w; s1 += UInt64(ch(k, 1) << 3 | 4) * w; s2 += UInt64(ch(k, 2) << 3 | 4) * w
            }
            let n = max(b.pop, 1)
            return (UInt8(s0 / n), UInt8(s1 / n), UInt8(s2 / n))
        }
    }

    static func nearest(_ p: [RGB], _ r: Int, _ g: Int, _ b: Int) -> UInt8 {
        var best = 0, bestD = Int.max
        for (i, c) in p.enumerated() {
            let dr = r - Int(c.0), dg = g - Int(c.1), db = b - Int(c.2)
            let d = 2 * dr * dr + 4 * dg * dg + 3 * db * db
            if d < bestD { bestD = d; best = i; if d == 0 { break } }
        }
        return UInt8(best)
    }

    // MARK: LZW

    /// GIF LZW: variable code width starting at minCodeSize+1, clear code at 4096 entries, packed LSB-first in
    /// ≤ 255-byte sub-blocks, terminated by a 0-length block.
    static func lzw(_ data: [UInt8], minCodeSize: Int, into out: inout Data) {
        let clear = 1 << minCodeSize, eoi = clear + 1
        var codeSize = minCodeSize + 1
        var next = eoi + 1
        var table = [Int32](repeating: -1, count: 4096 * 256)   // (prefix code << 8 | byte) → code
        var bitBuf: UInt32 = 0, bitCount = 0
        var block = [UInt8](); block.reserveCapacity(255)
        func flushBlock() {
            guard !block.isEmpty else { return }
            out.append(UInt8(block.count)); out.append(contentsOf: block); block.removeAll(keepingCapacity: true)
        }
        func emit(_ code: Int) {
            bitBuf |= UInt32(code) << UInt32(bitCount); bitCount += codeSize
            while bitCount >= 8 {
                block.append(UInt8(bitBuf & 0xFF)); bitBuf >>= 8; bitCount -= 8
                if block.count == 255 { flushBlock() }
            }
        }
        var touched: [Int] = []
        func reset() {
            for i in touched { table[i] = -1 }
            touched.removeAll(keepingCapacity: true)
            next = eoi + 1; codeSize = minCodeSize + 1
        }
        emit(clear)
        guard var prefix = data.first.map(Int.init) else { emit(eoi); if bitCount > 0 { block.append(UInt8(bitBuf & 0xFF)) }; flushBlock(); out.append(0); return }
        for i in 1..<max(1, data.count) where data.count > 1 {
            let k = Int(data[i])
            let key = prefix << 8 | k
            let found = table[key]
            if found >= 0 { prefix = Int(found); continue }
            emit(prefix)
            if next < 4096 {
                table[key] = Int32(next); touched.append(key)
                // grow after emitting the code that fills the current width (decoder-side lag)
                if next == (1 << codeSize) && codeSize < 12 { codeSize += 1 }
                next += 1
            } else {
                emit(clear); reset()
            }
            prefix = k
        }
        emit(prefix)
        emit(eoi)
        if bitCount > 0 { block.append(UInt8(bitBuf & 0xFF)) }
        flushBlock()
        out.append(0x00)
    }
}

extension Data {
    mutating func le16(_ v: Int) { append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF)) }
}
