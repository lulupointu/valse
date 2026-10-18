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
    private var window: [Float]
    private var inFIFO: [[Float]], outFIFO: [[Float]], accum: [[Float]]
    private var frame: [Float]
    private var re: [UnsafeMutablePointer<Float>], im: [UnsafeMutablePointer<Float>]
    private var rover: Int
    private let norm: Float
    var latency: Int { n }

    init(n: Int = 2048, hop: Int = 512, channels: Int, transform: SpectralTransform) {
        self.n = n; self.hop = hop; self.channels = channels; self.transform = transform
        fft = RealFFT(n: n)
        window = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
        // overlap-add of w² at this hop = n / hop * 3/8
        norm = 1 / (Float(n) / Float(hop) * 0.375)
        inFIFO = Array(repeating: [Float](repeating: 0, count: n), count: channels)
        outFIFO = inFIFO
        accum = Array(repeating: [Float](repeating: 0, count: 2 * n), count: channels)
        frame = [Float](repeating: 0, count: n)
        re = (0..<channels).map { _ in .allocate(capacity: n / 2 + 1) }
        im = (0..<channels).map { _ in .allocate(capacity: n / 2 + 1) }
        rover = n - hop
    }
    deinit { re.forEach { $0.deallocate() }; im.forEach { $0.deallocate() } }

    func process(_ b: AudioBlock) {
        let lat = n - hop
        for i in 0..<b.frames {
            for c in 0..<channels {
                let x = b[min(c, b.channels - 1)][i]
                inFIFO[c][rover] = x
                if c < b.channels { b[c][i] = outFIFO[c][rover - lat] }
            }
            rover += 1
            if rover >= n {
                rover = lat
                processFrame()
            }
        }
    }

    private func processFrame() {
        let bins = n / 2 + 1
        for c in 0..<channels {
            for k in 0..<n { frame[k] = inFIFO[c][k] * window[k] }
            frame.withUnsafeBufferPointer { fft.forward($0.baseAddress!, re[c], im[c]) }
        }
        transform.transform(re: re, im: im, bins: bins, channels: channels)
        for c in 0..<channels {
            frame.withUnsafeMutableBufferPointer { fft.inverse(re[c], im[c], $0.baseAddress!) }
            for k in 0..<n { accum[c][k] += frame[k] * window[k] * norm }
            for k in 0..<hop { outFIFO[c][k] = accum[c][k] }
            accum[c].withUnsafeMutableBufferPointer { p in
                let base = p.baseAddress!
                base.update(from: base + hop, count: 2 * n - hop)
                (base + 2 * n - hop).update(repeating: 0, count: hop)
            }
            inFIFO[c].withUnsafeMutableBufferPointer { p in
                let base = p.baseAddress!
                base.update(from: base + hop, count: n - hop)
            }
        }
    }
}
