import Foundation
import ValseCore

/// Phase-vocoder pitch shifter with independent formant (timbre) control.
///
/// Analysis estimates each bin's true frequency from the phase advance; synthesis moves bin k to k·pitch with
/// frequency ×pitch and accumulates phase (Laroche/Dolson; S. Bernsee's formulation). Formants: the spectral envelope
/// (cepstrally smoothed log magnitude) is divided out before shifting and re-applied, warped by `formant`, afterwards.
/// `formant` = 1 keeps the original timbre (natural pitch change), `formant` = pitch gives the classic "chipmunk".
final class PitchShiftTransform: SpectralTransform {
    var pitch: Double
    var formant: Double
    let n: Int, hop: Int, sampleRate: Double
    private var lastPhase: [[Float]], sumPhase: [[Float]]
    private var mag: [Float], freq: [Float], synMag: [Float], synFreq: [Float], env: [Float], logBuf: [Float]
    private var anaPhase: [Float], src: [Int], peaks: [Int]
    private let ceps: RealFFT
    private var cRe: [Float], cIm: [Float]
    private let lifter: Int
    /// Overlap-add gain lost because shifting the spectrum by `pitch` compresses each frame's time envelope.
    private var olaComp: Float = 1

    init(pitch: Double, formant: Double, n: Int, hop: Int, sampleRate: Double, channels: Int) {
        self.pitch = pitch; self.formant = formant; self.n = n; self.hop = hop; self.sampleRate = sampleRate
        let bins = n / 2 + 1
        lastPhase = Array(repeating: [Float](repeating: 0, count: bins), count: channels); sumPhase = lastPhase
        mag = [Float](repeating: 0, count: bins); freq = mag; synMag = mag; synFreq = mag; env = mag; anaPhase = mag
        src = [Int](repeating: -1, count: bins); peaks = []; peaks.reserveCapacity(bins)
        logBuf = [Float](repeating: 0, count: n)
        ceps = RealFFT(n: n)
        cRe = [Float](repeating: 0, count: bins); cIm = cRe
        lifter = max(8, Int(sampleRate * 0.0028))
        // Spectrum stretched by p ⇒ frame content ≈ √p·Hann(p·t) (after energy normalization); compensate its overlap
        // with the synthesis window relative to the identity case (Σ w²).
        let c = Double(n) / 2
        func w(_ t: Double) -> Double { t < 0 || t >= Double(n) ? 0 : 0.5 - 0.5 * cos(2 * .pi * t / Double(n)) }
        var ww = 0.0, wpw = 0.0
        for t in 0..<n { let x = Double(t); ww += w(x) * w(x); wpw += w(c + (x - c) * pitch) * w(x) }
        olaComp = Float(ww / (sqrt(pitch) * max(wpw, 1e-9)))
    }

    /// Smoothed spectral envelope of `mag` (linear) → `env`.
    private func envelope() {
        let bins = n / 2 + 1
        for k in 0..<bins { logBuf[k] = log(mag[k] + 1e-9) }
        for k in 1..<(n / 2) { logBuf[n - k] = logBuf[k] }
        logBuf.withUnsafeBufferPointer { lp in
            cRe.withUnsafeMutableBufferPointer { r in cIm.withUnsafeMutableBufferPointer { i in ceps.forward(lp.baseAddress!, r.baseAddress!, i.baseAddress!) } }
        }
        for q in 0..<bins { cIm[q] = 0; if q >= lifter { cRe[q] = 0 } }
        logBuf.withUnsafeMutableBufferPointer { lp in
            cRe.withUnsafeBufferPointer { r in cIm.withUnsafeBufferPointer { i in ceps.inverse(r.baseAddress!, i.baseAddress!, lp.baseAddress!) } }
        }
        for k in 0..<bins { env[k] = exp(logBuf[k]) }
    }

    func transform(re: [UnsafeMutablePointer<Float>], im: [UnsafeMutablePointer<Float>], bins: Int, channels: Int) {
        let osamp = Double(n) / Double(hop)
        let freqPerBin = sampleRate / Double(n)
        let expct = 2 * Double.pi * Double(hop) / Double(n)
        let p = Float(pitch)
        let warp = abs(formant - pitch) > 1e-3
        for c in 0..<channels {
            let r = re[c], i = im[c]
            var eIn: Float = 0
            for k in 0..<bins {
                let m = sqrt(r[k] * r[k] + i[k] * i[k])
                let ph = atan2(i[k], r[k])
                var d = Double(ph - lastPhase[c][k]); lastPhase[c][k] = ph
                d -= Double(k) * expct
                d = d - 2 * Double.pi * (d / (2 * Double.pi)).rounded()
                d = osamp * d / (2 * Double.pi)
                mag[k] = m
                anaPhase[k] = ph
                eIn += m * m
                freq[k] = Float((Double(k) + d) * freqPerBin)
            }
            if warp { envelope() }
            // inverse mapping: output bin k reads the analysis spectrum at k / pitch (no holes when shifting up)
            for k in 0..<bins {
                let x = Double(k) / pitch
                let a = Int(x)
                guard a < bins else { synMag[k] = 0; synFreq[k] = 0; src[k] = -1; continue }
                let t = Float(x - Double(a))
                let b = min(a + 1, bins - 1)
                synMag[k] = mag[a] * (1 - t) + mag[b] * t
                let s0 = t < 0.5 ? a : b
                src[k] = s0
                synFreq[k] = freq[s0] * p
            }
            if warp {
                // output bin k came from k/pitch; move its envelope from env(k/pitch) to env(k/formant).
                // Clamped to ±18 dB so isolated partials (pure tones) don't explode.
                func envAt(_ x: Double) -> Float {
                    let a = Int(x), t = Float(x - Double(a))
                    if a + 1 < bins { return env[a] * (1 - t) + env[a + 1] * t }
                    return env[bins - 1]
                }
                for k in 0..<bins where synMag[k] > 0 {
                    let corr = envAt(Double(k) / formant) / max(envAt(Double(k) / pitch), 1e-9)
                    synMag[k] *= min(max(corr, 0.125), 8)
                }
            }
            // keep the frame's energy (bin collisions / holes and the envelope round trip change it)
            var eOut: Float = 0
            for k in 0..<bins { eOut += synMag[k] * synMag[k] }
            if eOut > 1e-20 {
                let g = min(4, sqrt(eIn / eOut)) * olaComp
                for k in 0..<bins { synMag[k] *= g }
            }
            // Identity phase locking (Laroche & Dolson): only spectral peaks accumulate phase; the bins around a peak
            // keep their analysis phase offset to it, so each partial stays coherent (no "phasiness", no OLA loss).
            peaks.removeAll(keepingCapacity: true)
            for k in 0..<bins where synMag[k] > 0 {
                var isPeak = true
                for j in max(0, k - 2)...min(bins - 1, k + 2) where j != k && synMag[j] > synMag[k] { isPeak = false; break }
                if isPeak { peaks.append(k) }
            }
            for k in peaks {
                var d = Double(synFreq[k])
                d -= Double(k) * freqPerBin
                d /= freqPerBin
                d = 2 * Double.pi * d / osamp
                d += Double(k) * expct
                var s = Double(sumPhase[c][k]) + d
                s = s - 2 * Double.pi * (s / (2 * Double.pi)).rounded()
                sumPhase[c][k] = Float(s)
            }
            var pi = 0
            for k in 0..<bins {
                guard synMag[k] > 0, !peaks.isEmpty else { r[k] = 0; i[k] = 0; continue }
                while pi + 1 < peaks.count && abs(peaks[pi + 1] - k) <= abs(peaks[pi] - k) { pi += 1 }
                let pk = peaks[pi]
                var phase = sumPhase[c][pk]
                if pk != k, src[k] >= 0, src[pk] >= 0 {
                    // analysis offset to the peak, with the frame-centring linear phase (π per bin) moved from the
                    // source bin spacing to the destination spacing so each partial stays centred in the frame
                    let ds = Float(src[k] - src[pk]), dk = Float(k - pk)
                    phase += anaPhase[src[k]] - anaPhase[src[pk]] + .pi * ds - .pi * dk
                    sumPhase[c][k] = phase
                }
                r[k] = synMag[k] * cos(phase); i[k] = synMag[k] * sin(phase)
            }
        }
    }
}

/// Robot voice: zero phase at a fixed hop → every frame starts in phase, giving a monotone buzz at sampleRate / hop.
final class RobotTransform: SpectralTransform {
    func transform(re: [UnsafeMutablePointer<Float>], im: [UnsafeMutablePointer<Float>], bins: Int, channels: Int) {
        for c in 0..<channels {
            for k in 0..<bins { re[c][k] = sqrt(re[c][k] * re[c][k] + im[c][k] * im[c][k]); im[c][k] = 0 }
        }
    }
}

/// Whisper: random phases keep the spectral envelope but remove pitch.
final class WhisperTransform: SpectralTransform {
    var rng = XorShift()
    func transform(re: [UnsafeMutablePointer<Float>], im: [UnsafeMutablePointer<Float>], bins: Int, channels: Int) {
        for k in 0..<bins {
            let ph = Double(rng.next()) * Double.pi
            for c in 0..<channels {
                let m = sqrt(re[c][k] * re[c][k] + im[c][k] * im[c][k])
                re[c][k] = m * Float(cos(ph)); im[c][k] = m * Float(sin(ph))
            }
        }
    }
}

/// Speech denoiser: minimum-statistics noise tracking + decision-directed Wiener gain (Ephraim–Malah style) with a
/// strength-dependent floor. Stateless apart from its trackers, so it streams over files of any length.
final class DenoiseTransform: SpectralTransform {
    let strength: Float
    let floorGain: Float
    let over: Float
    private let subLen: Int, subCount: Int
    private var smoothed: [[Float]], subMin: [[Float]], ring: [[[Float]]], noise: [[Float]]
    private var prevGain: [[Float]], prevPost: [[Float]]
    private var frameInSub = 0, ringPos = 0, frames = 0
    private var seeded = false
    private let warmup: Int

    init(strength: Double, n: Int, hop: Int, sampleRate: Double, channels: Int) {
        self.strength = Float(min(max(strength, 0), 1))
        floorGain = Float(pow(10, -(6 + 24 * min(max(strength, 0), 1)) / 20))
        over = 1 + Float(strength)
        let bins = n / 2 + 1
        let framesPerSecond = sampleRate / Double(hop)
        subLen = max(4, Int(framesPerSecond * 0.15))
        subCount = 8   // ≈ 1.2 s minimum window
        warmup = n / hop
        let z = [Float](repeating: 0, count: bins), big = [Float](repeating: .greatestFiniteMagnitude, count: bins)
        smoothed = Array(repeating: z, count: channels)
        subMin = Array(repeating: big, count: channels)
        ring = Array(repeating: Array(repeating: big, count: subCount), count: channels)
        noise = Array(repeating: z, count: channels)
        prevGain = Array(repeating: [Float](repeating: 1, count: bins), count: channels)
        prevPost = Array(repeating: [Float](repeating: 1, count: bins), count: channels)
    }

    /// Seeds the noise estimate with a profile (per-bin power) measured beforehand (offline pre-scan).
    func seed(_ profile: [Float]) {
        for c in noise.indices {
            noise[c] = profile
            for u in 0..<subCount { ring[c][u] = profile }
        }
        seeded = true
    }

    func transform(re: [UnsafeMutablePointer<Float>], im: [UnsafeMutablePointer<Float>], bins: Int, channels: Int) {
        frames += 1
        frameInSub += 1
        let newSub = frameInSub >= subLen
        for c in 0..<channels {
            let r = re[c], i = im[c]
            for k in 0..<bins {
                let pw = r[k] * r[k] + i[k] * i[k]
                // the first frames are partly zero-padded: don't let them into the minimum tracker
                let s = frames <= warmup + 1 ? pw : 0.95 * smoothed[c][k] + 0.05 * pw
                smoothed[c][k] = s
                if frames > warmup, s < subMin[c][k] { subMin[c][k] = s }
                var m = subMin[c][k]
                for u in 0..<subCount where ring[c][u][k] < m { m = ring[c][u][k] }
                // minimum of a smoothed periodogram underestimates the mean noise power (bias ≈ 1.5–2 at α = 0.95)
                let nk = max(m * 1.8, 1e-12)
                noise[c][k] = (seeded || frames > subLen) ? nk : max(nk, noise[c][k])
                let nEst = noise[c][k] * over
                let post = pw / nEst
                let prio = 0.96 * prevGain[c][k] * prevGain[c][k] * prevPost[c][k] + 0.04 * max(post - 1, 0)
                var g = prio / (1 + prio)
                g = max(g, floorGain)
                prevGain[c][k] = g; prevPost[c][k] = post
                r[k] *= g; i[k] *= g
            }
            if newSub {
                ring[c][ringPos] = subMin[c]
                for k in 0..<bins { subMin[c][k] = .greatestFiniteMagnitude }
            }
        }
        if newSub { frameInSub = 0; ringPos = (ringPos + 1) % subCount }
    }
}

/// Measures a noise profile (per-bin power) from the quietest parts of a signal: the minimum over 150 ms windows of
/// the smoothed periodogram, ×1.8 bias — same estimator as `DenoiseTransform`.
final class NoiseProfiler {
    let n: Int, hop: Int
    let fft: RealFFT
    private var window: [Float], frame: [Float], re: [Float], im: [Float]
    private var fifo: [Float] = []
    private var smoothed: [Float], windowMin: [Float], best: [Float], windowEnergy: Float = 0
    private var bestEnergy: Float = .greatestFiniteMagnitude
    private var count = 0
    private let subLen: Int

    init(n: Int, hop: Int, sampleRate: Double) {
        self.n = n; self.hop = hop
        fft = RealFFT(n: n)
        window = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
        frame = [Float](repeating: 0, count: n)
        re = [Float](repeating: 0, count: n / 2 + 1); im = re
        smoothed = re; windowMin = [Float](repeating: .greatestFiniteMagnitude, count: n / 2 + 1); best = re
        subLen = max(4, Int(sampleRate / Double(hop) * 0.15))
    }

    /// Mono mix of the block's channels.
    func feed(_ b: AudioBlock) {
        for i in 0..<b.frames {
            var s: Float = 0
            for c in 0..<b.channels { s += b[c][i] }
            fifo.append(s / Float(max(1, b.channels)))
        }
        while fifo.count >= n {
            for k in 0..<n { frame[k] = fifo[k] * window[k] }
            frame.withUnsafeBufferPointer { f in re.withUnsafeMutableBufferPointer { r in im.withUnsafeMutableBufferPointer { ii in
                fft.forward(f.baseAddress!, r.baseAddress!, ii.baseAddress!) } } }
            var e: Float = 0
            for k in re.indices {
                let pw = re[k] * re[k] + im[k] * im[k]
                smoothed[k] = count == 0 ? pw : 0.95 * smoothed[k] + 0.05 * pw
                windowMin[k] = min(windowMin[k], smoothed[k])
                e += pw
            }
            windowEnergy += e
            count += 1
            if count % subLen == 0 {
                // keep the quietest window's minima (the most "noise only" stretch)
                if windowEnergy < bestEnergy { bestEnergy = windowEnergy; best = windowMin }
                windowEnergy = 0
                for k in windowMin.indices { windowMin[k] = .greatestFiniteMagnitude }
            }
            fifo.removeFirst(hop)
        }
    }

    var profile: [Float]? { bestEnergy < .greatestFiniteMagnitude ? best.map { max($0 * 1.8, 1e-12) } : nil }
}

/// Center-channel (vocal) extraction for stereo music: inter-channel coherence mask (Avendano & Jot), limited to the
/// vocal band. keepVocals → the masked centre on both channels; removeVocals → the residual.
/// Works on mixes where the lead vocal is panned centre (most music); mono material can't be separated this way.
final class VocalSeparationTransform: SpectralTransform {
    let mode: VocalSeparation
    let sampleRate: Double, n: Int
    private var prevMask: [Float]

    init(mode: VocalSeparation, n: Int, sampleRate: Double) {
        self.mode = mode; self.n = n; self.sampleRate = sampleRate
        prevMask = [Float](repeating: 0, count: n / 2 + 1)
    }

    func transform(re: [UnsafeMutablePointer<Float>], im: [UnsafeMutablePointer<Float>], bins: Int, channels: Int) {
        guard channels >= 2 else { return }
        let lr = re[0], li = im[0], rr = re[1], ri = im[1]
        let hz = sampleRate / Double(n)
        for k in 0..<bins {
            let f = Double(k) * hz
            // vocal band 120 Hz – 9 kHz with soft edges
            let band: Float = f < 80 ? 0 : f < 160 ? Float((f - 80) / 80) : f > 12000 ? 0 : f > 8000 ? Float((12000 - f) / 4000) : 1
            let cross = lr[k] * rr[k] + li[k] * ri[k]          // Re(L·R*)
            let e = lr[k] * lr[k] + li[k] * li[k] + rr[k] * rr[k] + ri[k] * ri[k]
            var psi: Float = e > 1e-12 ? max(0, 2 * cross / e) : 0
            psi = psi * psi * psi * psi
            let m = 0.5 * prevMask[k] + 0.5 * psi * band
            prevMask[k] = m
            let cr = 0.5 * (lr[k] + rr[k]) * m, ci = 0.5 * (li[k] + ri[k]) * m
            switch mode {
            case .keepVocals:
                lr[k] = cr; li[k] = ci; rr[k] = cr; ri[k] = ci
            case .removeVocals:
                lr[k] -= cr; li[k] -= ci; rr[k] -= cr; ri[k] -= ci
            }
        }
    }
}
