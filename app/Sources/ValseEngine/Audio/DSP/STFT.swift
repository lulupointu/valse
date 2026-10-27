import Accelerate
import Foundation

/// Real FFT of size n (power of two) via vDSP. `forward` yields the true DFT X[k], k = 0…n/2 (n/2+1 bins).
final class RealFFT {
    let n: Int
    let log2n: vDSP_Length
    private let setup: FFTSetup
    private var re: [Float], im: [Float]

    init(n: Int) {
        self.n = n
        log2n = vDSP_Length(log2(Double(n)).rounded())
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        re = [Float](repeating: 0, count: n / 2); im = re
    }
    deinit { vDSP_destroy_fftsetup(setup) }

    var bins: Int { n / 2 + 1 }

    /// x (n samples) → outRe/outIm (n/2+1 bins).
    func forward(_ x: UnsafePointer<Float>, _ outRe: UnsafeMutablePointer<Float>, _ outIm: UnsafeMutablePointer<Float>) {
        let h = n / 2
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                x.withMemoryRebound(to: DSPComplex.self, capacity: h) { vDSP_ctoz($0, 2, &sc, 1, vDSP_Length(h)) }
                vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(kFFTDirection_Forward))
                outRe[0] = rp[0] * 0.5; outIm[0] = 0
                outRe[h] = ip[0] * 0.5; outIm[h] = 0
                for k in 1..<h { outRe[k] = rp[k] * 0.5; outIm[k] = ip[k] * 0.5 }
            }
        }
    }

    /// inRe/inIm (n/2+1 bins of a true DFT) → x (n samples).
    func inverse(_ inRe: UnsafePointer<Float>, _ inIm: UnsafePointer<Float>, _ x: UnsafeMutablePointer<Float>) {
        let h = n / 2
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                rp[0] = inRe[0]; ip[0] = inRe[h]
                for k in 1..<h { rp[k] = inRe[k]; ip[k] = inIm[k] }
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                x.withMemoryRebound(to: DSPComplex.self, capacity: h) { vDSP_ztoc(&sc, 1, $0, 2, vDSP_Length(h)) }
                var s = 1 / Float(n)
                vDSP_vsmul(x, 1, &s, x, 1, vDSP_Length(n))
            }
        }
    }
}

/// Per-frame spectral transform. `re[c]`/`im[c]` hold `bins` values per channel; modify in place.
protocol SpectralTransform: AnyObject {
    func transform(re: [UnsafeMutablePointer<Float>], im: [UnsafeMutablePointer<Float>], bins: Int, channels: Int)
}

/// Streaming short-time Fourier transform with overlap-add resynthesis (Hann analysis + synthesis windows).
/// Latency = `n - hop` samples. `process` consumes and produces the same number of samples.
final class StreamingSTFT {
    let n: Int, hop: Int, channels: Int
    let fft: RealFFT
    let transform: SpectralTransform
    // flat, pointer-backed buffers (hot loop; fast in debug builds too)
    private let window: UnsafeMutablePointer<Float>
    private let inFIFO: [UnsafeMutablePointer<Float>], outFIFO: [UnsafeMutablePointer<Float>], accum: [UnsafeMutablePointer<Float>]
    private let frame: UnsafeMutablePointer<Float>
    private var re: [UnsafeMutablePointer<Float>], im: [UnsafeMutablePointer<Float>]
    private var rover: Int
    private var norm: Float
    var latency: Int { n }

    init(n: Int = 2048, hop: Int = 512, channels: Int, transform: SpectralTransform) {
        self.n = n; self.hop = hop; self.channels = channels; self.transform = transform
        fft = RealFFT(n: n)
        func buf(_ count: Int) -> UnsafeMutablePointer<Float> { let p = UnsafeMutablePointer<Float>.allocate(capacity: count); p.initialize(repeating: 0, count: count); return p }
        window = buf(n)
        for k in 0..<n { window[k] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(k) / Double(n))) }
        // overlap-add of w² at this hop = n / hop * 3/8
        norm = 1 / (Float(n) / Float(hop) * 0.375)
        inFIFO = (0..<channels).map { _ in buf(n) }
        outFIFO = (0..<channels).map { _ in buf(n) }
        accum = (0..<channels).map { _ in buf(2 * n) }
        frame = buf(n)
        re = (0..<channels).map { _ in buf(n / 2 + 1) }
        im = (0..<channels).map { _ in buf(n / 2 + 1) }
        rover = n - hop
    }
    deinit {
        ([window, frame] + inFIFO + outFIFO + accum + re + im).forEach { $0.deallocate() }
    }

    func process(_ b: AudioBlock) {
        let lat = n - hop
        var i = 0
        let frames = b.frames
        while i < frames {
            // copy as many samples as fit before the next frame boundary
            let count = min(n - rover, frames - i)
            for c in 0..<channels { (inFIFO[c] + rover).update(from: b[min(c, b.channels - 1)] + i, count: count) }
            for c in 0..<min(channels, b.channels) { (b[c] + i).update(from: outFIFO[c] + (rover - lat), count: count) }
            rover += count; i += count
            if rover >= n {
                rover = lat
                processFrame()
            }
        }
    }

    private func processFrame() {
        let bins = n / 2 + 1
        let N = vDSP_Length(n)
        for c in 0..<channels {
            vDSP_vmul(inFIFO[c], 1, window, 1, frame, 1, N)
            fft.forward(frame, re[c], im[c])
        }
        transform.transform(re: re, im: im, bins: bins, channels: channels)
        for c in 0..<channels {
            fft.inverse(re[c], im[c], frame)
            vDSP_vsmul(frame, 1, &norm, frame, 1, N)
            vDSP_vma(frame, 1, window, 1, accum[c], 1, accum[c], 1, N)
            outFIFO[c].update(from: accum[c], count: hop)
            accum[c].update(from: accum[c] + hop, count: 2 * n - hop)
            (accum[c] + 2 * n - hop).update(repeating: 0, count: hop)
            inFIFO[c].update(from: inFIFO[c] + hop, count: n - hop)
        }
    }
}
