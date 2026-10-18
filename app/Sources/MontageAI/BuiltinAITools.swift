@preconcurrency import AVFoundation
import Foundation
import MontageCore
import MontageEngine

public enum BuiltinAITools {
    /// Auto captions: transcribes the selected clip (or the first main-track clip with audio) and adds styled text clips
    /// on a new text track, one per caption line.
    public static let autoCaptions = AIToolDescriptor(
        id: "montage.ai.captions", nameKey: "ai.captions", descriptionKey: "ai.captions.desc", symbol: "captions.bubble",
        target: .project
    ) { input, progress in
        let project = input.project
        let clip = input.clip ?? project.timeline.mainTrack?.clips.first { $0.mediaID.flatMap(project.asset)?.hasAudio == true }
        guard let clip, let asset = clip.mediaID.flatMap(project.asset) else { throw AIToolError.noInput }
        progress.report(0.05)
        let audioURL = try await extractAudio(asset.url, range: clip.sourceRange)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        progress.report(0.2)
        let transcript = try await Transcriber.transcribe(url: audioURL, locale: Locale(identifier: input.language == "fr" ? "fr-FR" : "en-US"))
        progress.report(0.9)
        let rate = clip.speed.averageRate
        let lines = Transcriber.captionLines(transcript.words)
        guard !lines.isEmpty else { return .none }
        let clipStart = clip.start
        return .edit(Edit("cmd.captions") { p in
            var tl = p.timeline
            let track = TimelineOps.addTrack(.text, to: &tl)
            let ti = tl.trackIndex(track)!
            for l in lines {
                var t = TextContent(string: l.text, fontSize: 0.055)
                t.strokeColor = .black; t.strokeWidth = 0.08; t.bold = true
                var c = Clip(content: .text(t), start: clipStart + Time(l.start / rate), duration: Time(max(0.3, (l.end - l.start) / rate)))
                c.transform.position = Vec2(0, 0.36)
                c.name = l.text
                tl.tracks[ti].clips.append(c)
            }
            tl.tracks[ti].sortClips()
            // drop overlaps (keep order)
            var last = Time.zero
            for i in tl.tracks[ti].clips.indices {
                if tl.tracks[ti].clips[i].start < last { tl.tracks[ti].clips[i].start = last }
                last = tl.tracks[ti].clips[i].end
            }
            p.timeline = tl
        })
    }

    /// Remove background (person segmentation) → writes a matte movie into the cache. The compositor matte input is
    /// the next step of the AI workstream (see ARCHITECTURE "AI").
    public static let removeBackground = AIToolDescriptor(
        id: "montage.ai.removeBackground", nameKey: "ai.removeBackground", descriptionKey: "ai.removeBackground.desc",
        symbol: "person.crop.rectangle", target: .videoClip
    ) { input, progress in
        guard let clip = input.clip, let asset = input.asset, asset.kind == .video else { throw AIToolError.noInput }
        let dir = MontagePaths.cacheDirectory.appendingPathComponent("mattes", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(asset.contentHash)-person.mov")
        var frames = 0
        try await PersonSegmenter.forEachMask(url: asset.url, range: clip.sourceRange, quality: .balanced,
                                              progress: { progress.report($0) }) { _, _ in frames += 1 }
        EngineLog.info("segmented \(frames) frames for \(asset.name)")
        return .artifact(url)
    }

    public static let all: [AIToolDescriptor] = [autoCaptions, removeBackground]

    /// Extracts mono 16 kHz WAV of a source range (speech engines prefer it).
    static func extractAudio(_ url: URL, range: TimeRange) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw AIToolError.noInput }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("montage-stt-\(UUID().uuidString).wav")
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range.cmTimeRange
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                                       AVLinearPCMIsNonInterleaved: false]
        let ro = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(ro)
        let writer = try AVAssetWriter(outputURL: out, fileType: .wav)
        let wi = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        writer.add(wi)
        reader.startReading(); writer.startWriting(); writer.startSession(atSourceTime: range.start.cmTime)
        while let sb = ro.copyNextSampleBuffer() {
            while !wi.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            wi.append(sb)
        }
        wi.markAsFinished()
        await writer.finishWriting()
        return out
    }
}
