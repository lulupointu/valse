import Foundation
import MontageCore
import MontageEngine

/// AI clipper / Long video to shorts (AI-031): transcript (cached whisper / Apple speech) → sentences → highlight
/// windows. With an on-device LLM (Apple Foundation Models or the local Qwen model) the model picks the moments
/// (sentence ranges, honouring "More requirements"), snapped to valid windows; otherwise / additionally the
/// `Highlights` heuristics rank them.
public enum AIClipper {
    public struct Options: Sendable {
        public var duration: ClipDuration = .auto
        public var count: Int? = nil
        public var requirements = ""
        public var language: String? = nil
        public var useLLM = true
        public init() {}
    }

    public static func highlights(_ asset: MediaAsset, options o: Options, progress: (@Sendable (Double) -> Void)? = nil) async throws -> [Highlight] {
        guard asset.hasAudio else { throw AIToolError.noInput }
        let t = try await transcript(asset, language: o.language) { progress?($0 * 0.8) }
        let s = Highlights.sentences(t.words)
        guard !s.isEmpty else { throw AIToolError.noSpeech }
        var boost: Set<ClosedRange<Int>> = []
        if o.useLLM, OnDeviceLLM.isAvailable {
            boost = (try? await llmPicks(s, options: o)) ?? []
        }
        progress?(1)
        return Highlights.pick(s, duration: o.duration, count: o.count, boost: boost)
    }

    /// Cached transcript of the whole media, else a new one (whisper when installed).
    static func transcript(_ a: MediaAsset, language: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        if let t = TranscriptStore.shared.latest(hash: a.contentHash), !t.words.isEmpty { progress(1); return t }
        let key = TranscriptStore.key(hash: a.contentHash, range: nil, language: language, engine: .automatic, fillers: true)
        let wav = try await AudioExtractor.wav16k(a.url, range: nil)
        defer { try? FileManager.default.removeItem(at: wav) }
        let t = try await Transcriber.transcribe(wav: wav, request: .init(language: language, engine: .automatic, keepFillers: true), progress: progress)
        TranscriptStore.shared.put(t, key)
        return t
    }

    /// Asks the LLM for sentence ranges, snapped to candidate windows of the requested length.
    static func llmPicks(_ s: [Highlights.Sentence], options o: Options) async throws -> Set<ClosedRange<Int>> {
        var lines: [String] = [], budget = 11_000
        for (i, x) in s.enumerated() {
            let l = "\(i + 1) [\(Int(x.start))s] \(x.text)"
            budget -= l.count
            if budget < 0 { break }
            lines.append(l)
        }
        let r = o.duration.range
        let want = o.count ?? Highlights.autoCount(s)
        let req = o.requirements.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = """
        Transcript of a video, one numbered sentence per line with its start time:
        \(lines.joined(separator: "\n"))

        Pick the \(want) best highlight moments for short social videos. Each moment is a range of consecutive sentences \
        that makes sense on its own (a complete idea, a strong hook at the start) and lasts between \(Int(r.lowerBound)) \
        and \(Int(r.upperBound)) seconds.\(req.isEmpty ? "" : " Viewer requirements: \(req).")
        Reply with one range per line as FIRST-LAST sentence numbers (for example 12-17), best first, nothing else.
        """
        let reply = try await OnDeviceLLM.respond(prompt, instructions: "You are a video editor who finds viral highlights in transcripts.", temperature: 0.2, maxTokens: 120)
        let cands = Highlights.candidates(s, range: r)
        var out: Set<ClosedRange<Int>> = []
        for line in reply.split(whereSeparator: \.isNewline) {
            let nums = line.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard nums.count >= 2, nums[0] >= 1, nums[1] >= nums[0], nums[1] <= s.count else { continue }
            let want = (nums[0] - 1)...(nums[1] - 1)
            // nearest valid window: most overlap, then closest start
            func overlap(_ c: ClosedRange<Int>) -> Int { max(0, min(c.upperBound, want.upperBound) - max(c.lowerBound, want.lowerBound) + 1) }
            if let best = cands.max(by: { (overlap($0), -abs($0.lowerBound - want.lowerBound)) < (overlap($1), -abs($1.lowerBound - want.lowerBound)) }),
               overlap(best) > 0 { out.insert(best) }
        }
        return out
    }
}
