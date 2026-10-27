@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import ValseCore
import ValseEngine

/// On-device ML voice isolation (AI-009/010/011, AU-007/008/009) with Apple's `AUSoundIsolation` audio unit
/// (the model behind macOS "Voice Isolation"; ~35× real time on M1, runs offline through AVAudioEngine manual
/// rendering). Produces `AudioStemStore` stems: `voice` (speech only) and `novoice` (original − voice).
public enum VoiceIsolator {
    public enum Stem: String, Sendable, CaseIterable { case voice, novoice }

    static let component = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0x766F_6973 /* 'vois' */,
                                                     componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)

    public static var isAvailable: Bool { !AVAudioUnitComponentManager.shared().components(matching: component).isEmpty }

    public static func isReady(_ a: MediaAsset, _ s: Stem) -> Bool { AudioStemStore.shared.readyStem(media: a, kind: s.rawValue) != nil }

    /// Makes both stems of a media item (cached). `progress` 0…1.
    public static func separate(_ asset: MediaAsset, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if Stem.allCases.allSatisfy({ isReady(asset, $0) }) { progress?(1); return }
        guard isAvailable else { throw AIToolError.unavailable("AUSoundIsolation") }
        let pcm = try await decode(asset.url) { progress?(0.2 * $0) }
        defer { try? FileManager.default.removeItem(at: pcm) }
        let store = AudioStemStore.shared
        let voiceTmp = store.directory.appendingPathComponent("tmp-\(UUID().uuidString).caf")
        let restTmp = store.directory.appendingPathComponent("tmp-\(UUID().uuidString).caf")
        do {
            try isolate(pcm, voice: voiceTmp, rest: restTmp) { progress?(0.2 + 0.8 * $0) }
            for (tmp, s) in [(voiceTmp, Stem.voice), (restTmp, Stem.novoice)] {
                let dst = store.stemURL(media: asset, kind: s.rawValue)
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.moveItem(at: tmp, to: dst)
            }
        } catch {
            try? FileManager.default.removeItem(at: voiceTmp); try? FileManager.default.removeItem(at: restTmp)
            throw error
        }
        progress?(1)
    }

    static let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    /// Media audio → 48 kHz stereo float CAF (the AU's working format).
    static func decode(_ url: URL, progress: (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw AIToolError.noInput }
        let total = max(try await asset.load(.duration).seconds, 0.001)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? AIToolError.noInput }
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("valse-iso-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: dst, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let interleaved = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        // blocking read loop: off the cooperative pool (OffPool)
        try await OffPool.run { ctx in
            while let sb = out.copyNextSampleBuffer() {
                try ctx.checkCancellation()
                let n = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
                guard n > 0, let src = AVAudioPCMBuffer(pcmFormat: interleaved, frameCapacity: n),
                      let dstBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { continue }
                src.frameLength = n
                try CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: src.mutableAudioBufferList)
                // de-interleave
                let s = src.floatChannelData![0], l = dstBuf.floatChannelData![0], r = dstBuf.floatChannelData![1]
                for i in 0..<Int(n) { l[i] = s[2 * i]; r[i] = s[2 * i + 1] }
                dstBuf.frameLength = n
                try file.write(from: dstBuf)
                progress(CMSampleBufferGetPresentationTimeStamp(sb).seconds / total)
            }
        }
        return dst
    }

    /// Runs the PCM file through AUSoundIsolation offline; writes the voice and (original − voice), latency-aligned.
    static func isolate(_ pcm: URL, voice: URL, rest: URL, progress: (Double) -> Void) throws {
        let input = try AVAudioFile(forReading: pcm)
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let fx = AVAudioUnitEffect(audioComponentDescription: component)
        engine.attach(player); engine.attach(fx)
        engine.connect(player, to: fx, format: format)
        engine.connect(fx, to: engine.mainMixerNode, format: format)
        let chunk: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: chunk)
        try engine.start()
        defer { engine.stop() }
        player.scheduleFile(input, at: nil)
        player.play()
        let latency = Int((fx.auAudioUnit.latency * 48_000).rounded())
        let total = Int(input.length)
        let vOut = try AVAudioFile(forWriting: voice, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rOut = try AVAudioFile(forWriting: rest, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let orig = try AVAudioFile(forReading: pcm)
        guard let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: chunk),
              let ob = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw AIToolError.noInput }
        var rendered = 0, written = 0
        while written < total {
            try Task.checkCancellation()
            let st = try engine.renderOffline(chunk, to: buf)
            guard st == .success else { break }
            var n = Int(buf.frameLength)
            var offset = 0
            // drop the AU's latency at the start so stems line up with the media
            if rendered < latency { let skip = min(latency - rendered, n); offset = skip; n -= skip }
            rendered += Int(buf.frameLength)
            n = min(n, total - written)
            guard n > 0 else { continue }
            guard let vb = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
                  let rb = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { break }
            ob.frameLength = 0
            try orig.read(into: ob, frameCount: AVAudioFrameCount(n))
            let m = min(n, Int(ob.frameLength))
            for c in 0..<2 {
                let v = buf.floatChannelData![c].advanced(by: offset), o = ob.floatChannelData![c]
                let vd = vb.floatChannelData![c], rd = rb.floatChannelData![c]
                for i in 0..<m { vd[i] = v[i]; rd[i] = o[i] - v[i] }
            }
            vb.frameLength = AVAudioFrameCount(m); rb.frameLength = AVAudioFrameCount(m)
            try vOut.write(from: vb); try rOut.write(from: rb)
            written += m
            if m < n { break }
            progress(Double(written) / Double(max(total, 1)))
        }
        // the tail still inside the AU: flush with silence input until all frames are written
        player.stop()
    }
}
