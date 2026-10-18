import AVFoundation

public struct StretchCheck {
    public let inputHz: Double
    public let outputHz: Double
    public let consumedRatio: Double   // input samples consumed / output samples produced (≈ rate)
    public var pitchRatio: Double { outputHz / inputHz }
}

/// Time-stretch with pitch preservation through AVAudioEngine + AVAudioUnitTimePitch (the same
/// node a real-time multitrack engine would use per track; rate can be automated for curve speed).
/// Rendered offline (manual rendering mode) so we can verify duration and pitch numerically.
public enum AudioStretch {
    public static func loadPCM(url: URL, seconds: Double) async throws -> AVAudioPCMBuffer {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw NSError(domain: "Montage", code: 40) }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 48000))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(out); reader.startReading()
        var samples: [Float] = []
        while let sb = out.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            let len = CMBlockBufferGetDataLength(bb)
            var chunk = [Float](repeating: 0, count: len / 4)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            samples += chunk
        }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        return buf
    }

    public static func zeroCrossingHz(_ p: UnsafePointer<Float>, from: Int, count: Int, sampleRate: Double) -> Double {
        var crossings = 0
        for i in (from + 1)..<(from + count) where (p[i - 1] < 0) != (p[i] < 0) { crossings += 1 }
        return Double(crossings) / 2 / (Double(count) / sampleRate)
    }

    public static func check(input: AVAudioPCMBuffer, rate: Float) throws -> StretchCheck {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let tp = AVAudioUnitTimePitch()
        tp.rate = rate
        tp.pitch = 0
        engine.attach(player); engine.attach(tp)
        engine.connect(player, to: tp, format: input.format)
        engine.connect(tp, to: engine.mainMixerNode, format: input.format)
        try engine.enableManualRenderingMode(.offline, format: input.format, maximumFrameCount: 4096)
        try engine.start()
        player.scheduleBuffer(input, at: nil)
        player.play()
        let outFrames = Int(Double(input.frameLength) / Double(rate) * 0.9)
        let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(outFrames))!
        let chunk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        while Int(out.frameLength) < outFrames {
            let n = min(4096, outFrames - Int(out.frameLength))
            _ = try engine.renderOffline(AVAudioFrameCount(n), to: chunk)
            let dst = out.floatChannelData![0] + Int(out.frameLength)
            dst.update(from: chunk.floatChannelData![0], count: Int(chunk.frameLength))
            out.frameLength += chunk.frameLength
        }
        var consumed = 0.0
        if let nt = player.lastRenderTime, let pt = player.playerTime(forNodeTime: nt) { consumed = Double(pt.sampleTime) }
        engine.stop()
        let sr = input.format.sampleRate
        let inHz = zeroCrossingHz(input.floatChannelData![0], from: Int(sr * 0.5), count: Int(sr), sampleRate: sr)
        let outHz = zeroCrossingHz(out.floatChannelData![0], from: Int(sr * 0.5), count: Int(sr), sampleRate: sr)
        return StretchCheck(inputHz: inHz, outputHz: outHz, consumedRatio: consumed / Double(out.frameLength))
    }
}
