@preconcurrency import AVFoundation
import Foundation
import MontageCore
import MontageEngine

/// The demucs.cpp sidecar (`demucs`, multithreaded CPU + Accelerate BLAS). Lookup like whisper: `MONTAGE_DEMUCS_CLI`,
/// the app bundle (`Contents/Helpers/demucs`), Application Support/Montage/bin (scripts/build_ai_runtimes.sh).
public enum DemucsRuntime {
    public static var cliURL: URL? {
        let fm = FileManager.default
        var c: [String] = []
        if let e = ProcessInfo.processInfo.environment["MONTAGE_DEMUCS_CLI"], !e.isEmpty { c.append(e) }
        c.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/demucs").path)
        c.append(MontagePaths.supportDirectory.appendingPathComponent("bin/demucs").path)
        // the user's real App Support (UI tests sandbox `supportDirectory`, but runtimes aren't settings)
        if let u = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            c.append(u.appendingPathComponent("Montage/bin/demucs").path)
        }
        return c.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
    /// Installed model (6 stems preferred), nil when the runtime or the model is missing.
    public static var model: AIModelSpec? {
        guard cliURL != nil else { return nil }
        return [ModelCatalog.demucs6, ModelCatalog.demucs4].first { ModelCatalog.installedURL($0) != nil }
    }
    public static var isAvailable: Bool { model != nil }
}

/// Music source separation (AI-011 / AU-010 "Separate audio"): HTDemucs stems written into `AudioStemStore`
/// (`drums`, `bass`, `other`, `vocals`, + `guitar`, `piano` with the 6-stem model), aligned with the media.
public enum StemSeparator {
    public enum Stem: String, Sendable, CaseIterable {
        case vocals, drums, bass, other, guitar, piano
        public var nameKey: String { "stem.\(rawValue)" }
        /// demucs.cpp output name index.
        func file(sixStems: Bool) -> String? {
            switch self {
            case .drums: return "target_0_drums.wav"
            case .bass: return "target_1_bass.wav"
            case .other: return "target_2_other.wav"
            case .vocals: return "target_3_vocals.wav"
            case .guitar: return sixStems ? "target_4_guitar.wav" : nil
            case .piano: return sixStems ? "target_5_piano.wav" : nil
            }
        }
        public var storeKind: String { "demucs-\(rawValue)" }
    }

    /// Stems this Mac can produce (model dependent).
    public static var availableStems: [Stem] {
        guard let m = DemucsRuntime.model else { return [] }
        return m.id == ModelCatalog.demucs6.id ? Stem.allCases : [.vocals, .drums, .bass, .other]
    }

    public static func isReady(_ a: MediaAsset, _ s: Stem) -> Bool { AudioStemStore.shared.readyStem(media: a, kind: s.storeKind) != nil }

    /// Separates the whole media (cached per stem). `progress` 0…1 (demucs prints none: time-based estimate).
    public static func separate(_ asset: MediaAsset, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard let cli = DemucsRuntime.cliURL, let spec = DemucsRuntime.model, let model = ModelCatalog.installedURL(spec) else {
            throw AIToolError.modelMissing(ModelCatalog.demucs4.id)
        }
        let six = spec.id == ModelCatalog.demucs6.id
        let wanted = Stem.allCases.filter { $0.file(sixStems: six) != nil }
        if wanted.allSatisfy({ isReady(asset, $0) }) { progress?(1); return }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("montage-demucs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        // 44.1 kHz stereo 16-bit WAV (the model's rate)
        let input = work.appendingPathComponent("in.wav")
        try await writeWAV(asset.url, to: input)
        progress?(0.05)
        let duration = max(asset.duration.seconds, 1)
        let p = Process()
        p.executableURL = cli
        p.arguments = [model.path, input.path, work.appendingPathComponent("out").path, String(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        let start = Date()
        let ticker = Task {
            // ~2.2× real time on an M1 Pro CPU: report a time-based estimate
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                progress?(min(0.95, 0.05 + 0.9 * Date().timeIntervalSince(start) / (duration * 2.5)))
            }
        }
        defer { ticker.cancel() }
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int32, Error>) in
                p.terminationHandler = { c.resume(returning: $0.terminationStatus) }
                do { try p.run() } catch { p.terminationHandler = nil; c.resume(throwing: error) }
            }
        } onCancel: { if p.isRunning { p.terminate() } }
        try Task.checkCancellation()
        guard status == 0 else { throw AIToolError.unavailable("demucs exit \(status)") }
        for s in wanted {
            guard let f = s.file(sixStems: six) else { continue }
            let src = work.appendingPathComponent("out").appendingPathComponent(f)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            let dst = AudioStemStore.shared.stemURL(media: asset, kind: s.storeKind)
            try? FileManager.default.removeItem(at: dst)
            try convertToCAF(src, dst)
        }
        progress?(1)
    }

    static func writeWAV(_ url: URL, to out: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw AIToolError.noInput }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                                       AVLinearPCMIsNonInterleaved: false]
        let ro = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(ro)
        let w = try AVAssetWriter(outputURL: out, fileType: .wav)
        let wi = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        w.add(wi)
        guard reader.startReading() else { throw reader.error ?? AIToolError.noInput }
        w.startWriting(); w.startSession(atSourceTime: .zero)
        while let sb = ro.copyNextSampleBuffer() {
            try Task.checkCancellation()
            while !wi.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            wi.append(sb)
        }
        wi.markAsFinished()
        await w.finishWriting()
    }

    /// demucs WAV → 48 kHz stereo float CAF (the stems' common format).
    static func convertToCAF(_ src: URL, _ dst: URL) throws {
        let inF = try AVAudioFile(forReading: src)
        let outFmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let out = try AVAudioFile(forWriting: dst, settings: outFmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let conv = AVAudioConverter(from: inF.processingFormat, to: outFmt) else { throw AIToolError.noInput }
        let chunk: AVAudioFrameCount = 32_768
        let inBuf = AVAudioPCMBuffer(pcmFormat: inF.processingFormat, frameCapacity: chunk)!
        var done = false
        while true {
            let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: AVAudioFrameCount(Double(chunk) * 48_000 / inF.processingFormat.sampleRate) + 64)!
            var err: NSError?
            let st = conv.convert(to: outBuf, error: &err) { _, status in
                if done { status.pointee = .endOfStream; return nil }
                inBuf.frameLength = 0
                try? inF.read(into: inBuf, frameCount: chunk)
                if inBuf.frameLength == 0 { done = true; status.pointee = .endOfStream; return nil }
                status.pointee = .haveData
                return inBuf
            }
            if let err { throw err }
            if outBuf.frameLength > 0 { try out.write(from: outBuf) }
            if st == .endOfStream || st == .error { break }
        }
    }
}
