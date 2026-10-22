import Foundation
import MontageCore
import MontageEngine

/// Home ▸ Long video to shorts (AI-031): transcript of the long video (cached, whisper.cpp → Apple speech) → the AI
/// clipper's highlight picks (local LLM when available + `Highlights` heuristics) in the chosen duration bucket →
/// one 9:16 project per highlight, auto reframed onto the subject (Vision subject path, `ReframePath`) and captioned
/// from the same transcript. The caller saves the projects in the library.
public enum LongToShorts {
    public enum Phase: String, Sendable { case analyzing, converting
        public var titleKey: String { "shorts.phase.\(rawValue)" }
    }

    public struct Options: Sendable {
        public var duration: ShortsDuration = .auto
        public var range: ClosedRange<Double>? = nil
        public var captions = true
        public var reframe = true
        public var useLLM = true
        public init() {}
    }

    public static func run(_ asset: MediaAsset, options o: Options, progress: (@Sendable (Double) -> Void)? = nil,
                           phase: (@Sendable (Phase) -> Void)? = nil) async throws -> [Project] {
        if let p = ShortsPlanner.validate(asset) { throw AIToolError.unavailable(p.rawValue) }
        phase?(.analyzing)
        let t = try await AIClipper.transcript(asset, language: nil) { progress?(0.45 * $0) }
        let words = ShortsPlanner.words(t, in: o.range)
        let s = Highlights.sentences(words)
        guard !s.isEmpty else { throw AIToolError.noSpeech }
        let span = (s.last!.end - s.first!.start)
        let count = ShortsPlanner.count(forSeconds: span)
        var boost: Set<ClosedRange<Int>> = []
        if o.useLLM, OnDeviceLLM.isAvailable {
            var co = AIClipper.Options()
            co.count = count
            co.duration = nearest(o.duration)
            boost = (try? await AIClipper.llmPicks(s, options: co)) ?? []
        }
        let hs = Highlights.pick(s, range: o.duration.range, count: count, boost: boost).sorted { $0.start < $1.start }
        guard !hs.isEmpty else { throw AIToolError.noSpeech }
        progress?(0.5)
        phase?(.converting)
        var out: [Project] = []
        let base = (asset.name as NSString).deletingPathExtension
        for (i, h) in hs.enumerated() {
            try Task.checkCancellation()
            var p = ShortsPlanner.project(for: h, asset: asset, index: i, name: tr("shorts.projectName", base, i + 1))
            if o.reframe, let clip = p.timeline.mainTrack?.clips.first {
                let k = Double(i), n = Double(hs.count)
                if let cmd = try? await AutoReframe.run(project: p, clipID: clip.id, options: ReframeOptions(ratio: "9:16"),
                                                        progress: { progress?(0.5 + 0.5 * (k + 0.8 * $0) / n) }) {
                    try? cmd.apply(to: &p)
                }
            }
            if o.captions, let clip = p.timeline.mainTrack?.clips.first {
                let segs = SpeechCaptions.segments(t, for: clip)
                if !segs.isEmpty, let id = CaptionOps.addCaptionTrack(segs, to: &p, origin: .auto) {
                    SpeechCaptions.finish(trackID: id, in: &p)
                }
            }
            out.append(p)
            progress?(0.5 + 0.5 * Double(i + 1) / Double(hs.count))
        }
        return out
    }

    static func nearest(_ d: ShortsDuration) -> ClipDuration {
        switch d { case .auto: return .auto; case .under60: return .upTo60; case .from60to90, .from90to180: return .over60 }
    }
}
