import Foundation

/// Text-to-speech provenance of a generated audio clip (W10). nil on ordinary clips.
public struct TTSInfo: Hashable, Codable, Sendable {
    /// Text clip the speech was generated from (CapCut keeps them associated: "Text and speech are added to the track").
    public var sourceText: ClipID
    public var voice: String
    /// Speed (1 = normal) and pitch multipliers.
    public var rate: Double
    public var pitch: Double
    /// Text that was spoken (to detect script edits).
    public var text: String
    /// "Update speech according to script".
    public var autoUpdate: Bool
    /// Emotion / style preset (AU-030). Files written before styles existed decode as `.neutral`.
    public var style: TTSStyle
    public init(sourceText: ClipID, voice: String, rate: Double = 1, pitch: Double = 1, text: String, autoUpdate: Bool = true,
                style: TTSStyle = .neutral) {
        self.sourceText = sourceText; self.voice = voice; self.rate = rate; self.pitch = pitch; self.text = text; self.autoUpdate = autoUpdate
        self.style = style
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceText = try c.decode(ClipID.self, forKey: .sourceText)
        voice = try c.decode(String.self, forKey: .voice)
        rate = try c.decodeIfPresent(Double.self, forKey: .rate) ?? 1
        pitch = try c.decodeIfPresent(Double.self, forKey: .pitch) ?? 1
        text = try c.decode(String.self, forKey: .text)
        autoUpdate = try c.decodeIfPresent(Bool.self, forKey: .autoUpdate) ?? true
        // unknown raw values (a newer file) fall back to neutral instead of failing the whole project
        style = (try? c.decodeIfPresent(TTSStyle.self, forKey: .style)) ?? .neutral
    }
}

/// Speaking style presets for the system voices (AU-030 / AI-006 "emotions / styles").
///
/// What this really is: AVSpeechSynthesizer has no emotion control, so a style is a prosody recipe the on-device stack
/// does honour — speaking rate, pitch, pauses between sentences, a pitch lift on exclamations (all through SSML
/// `<prosody>` / `<break>`, macOS 13+) — plus post-processing on the generated clip through the existing audio chain
/// (gain + a 10-band EQ tilt). It sounds calmer / brighter / more energetic; it is not an expressive (ML) voice.
public enum TTSStyle: String, Codable, CaseIterable, Sendable {
    case neutral, cheerful, calm, serious, excited

    public var nameKey: String { "tts.style.\(rawValue)" }

    public var prosody: TTSProsody {
        switch self {
        case .neutral:  TTSProsody()
        case .cheerful: TTSProsody(rate: 1.08, pitch: 1.15, sentencePauseMs: 120, exclamationPitch: 1.08, gainDB: 0,
                                   eq: [0, 0, 0, -1, 0, 1, 2.5, 3, 1.5, 0])
        case .calm:     TTSProsody(rate: 0.85, pitch: 0.92, sentencePauseMs: 450, exclamationPitch: 1, gainDB: -2,
                                   eq: [0, 0, 1.5, 1.5, 0.5, 0, -1, -2, -3, -3])
        case .serious:  TTSProsody(rate: 0.92, pitch: 0.85, sentencePauseMs: 300, exclamationPitch: 1, gainDB: 0,
                                   eq: [0, 0.5, 2, 1.5, 0, 0, 0, -1, -1.5, -1.5])
        case .excited:  TTSProsody(rate: 1.2, pitch: 1.25, sentencePauseMs: 60, exclamationPitch: 1.12, gainDB: 0,
                                   eq: [0, 0, 0, -1.5, -0.5, 1, 3, 3.5, 2, 0.5])
        }
    }
}

/// The parameters a `TTSStyle` maps to. Multipliers apply on top of the user's Speed / Pitch.
public struct TTSProsody: Hashable, Sendable {
    public var rate: Double
    public var pitch: Double
    /// Extra silence after each sentence.
    public var sentencePauseMs: Int
    /// Further pitch multiplier on sentences ending with "!".
    public var exclamationPitch: Double
    /// Clip gain (dB) applied to the generated speech clip.
    public var gainDB: Double
    /// 10-band EQ (dB, `AudioEQ.frequencies`) applied to the generated clip, nil = flat.
    public var eq: [Double]?
    public init(rate: Double = 1, pitch: Double = 1, sentencePauseMs: Int = 0, exclamationPitch: Double = 1, gainDB: Double = 0, eq: [Double]? = nil) {
        self.rate = rate; self.pitch = pitch; self.sentencePauseMs = sentencePauseMs; self.exclamationPitch = exclamationPitch
        self.gainDB = gainDB; self.eq = eq
    }

    /// Speed range the synthesizer accepts (CapCut 0.5×…2×) and pitch range (AVSpeech 0.5…2).
    public static let rateRange: ClosedRange<Double> = 0.5...2
    public static let pitchRange: ClosedRange<Double> = 0.5...2

    /// SSML for `text` with this prosody on top of the user's `rate` / `pitch` (1 = normal). With SSML the
    /// synthesizer ignores the utterance's rate / pitch properties, so everything is expressed here. Sentences are
    /// split with Foundation's sentence tokenizer; a pause follows every sentence but the last.
    public func ssml(_ text: String, rate userRate: Double = 1, pitch userPitch: Double = 1) -> String {
        let r = min(max(userRate * rate, Self.rateRange.lowerBound), Self.rateRange.upperBound)
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
            if let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { sentences.append(s) }
        }
        if sentences.isEmpty { sentences = [text.trimmingCharacters(in: .whitespacesAndNewlines)] }
        var out = "<speak>"
        for (i, s) in sentences.enumerated() {
            let lift = Self.isExclamation(s) ? exclamationPitch : 1
            let p = min(max(userPitch * pitch * lift, Self.pitchRange.lowerBound), Self.pitchRange.upperBound)
            out += "<prosody rate=\"\(Self.percent(r))\" pitch=\"\(Self.signedPercent(p))\">\(Self.escape(s))</prosody>"
            if sentencePauseMs > 0, i < sentences.count - 1 { out += "<break time=\"\(sentencePauseMs)ms\"/>" }
        }
        return out + "</speak>"
    }

    static func isExclamation(_ s: String) -> Bool {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " \u{00A0}\"'»”)")).hasSuffix("!")
    }
    static func percent(_ m: Double) -> String { "\(Int((m * 100).rounded()))%" }
    static func signedPercent(_ m: Double) -> String {
        let v = Int(((m - 1) * 100).rounded())
        return v >= 0 ? "+\(v)%" : "\(v)%"
    }
    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Post-processing of the generated clip through the existing audio chain (gain + EQ). Neutral leaves it untouched.
    public func apply(to audio: inout AudioProps) {
        if gainDB != 0 { audio.volume = pow(10, gainDB / 20) }
        if let eq, eq.count == AudioEQ.frequencies.count { audio.eq = AudioEQ(gains: eq) }
    }
}

public enum TTSOps {
    /// The generated speech clip of a text clip, if any.
    public static func speechClip(for text: ClipID, in tl: Timeline) -> Clip? { tl.allClips.first { $0.tts?.sourceText == text } }

    /// Places (or replaces) the speech clip of `textID`: audio clip at the text clip's start on a free audio track.
    @discardableResult
    public static func placeSpeech(_ asset: MediaAsset, info: TTSInfo, in project: inout Project) throws -> ClipID {
        guard let text = project.timeline.clip(info.sourceText) else { throw EditError.clipNotFound }
        var tl = project.timeline
        if let old = speechClip(for: info.sourceText, in: tl) {
            for ti in tl.tracks.indices { tl.tracks[ti].clips.removeAll { $0.id == old.id } }
        }
        if !project.media.contains(where: { $0.id == asset.id }) { project.media.append(asset) }
        var c = TimelineOps.makeClip(for: asset, at: text.start)
        c.tts = info
        info.style.prosody.apply(to: &c.audio)   // AU-030: style gain + EQ tilt on the generated clip
        c.name = info.text
        let range = c.range
        let ti: Int
        if let i = tl.tracks.firstIndex(where: { $0.kind == .audio && !$0.isLocked && !$0.clips.contains { $0.range.overlaps(range) } }) { ti = i }
        else { let id = TimelineOps.addTrack(.audio, to: &tl); ti = tl.trackIndex(id)! }
        tl.tracks[ti].clips.append(c)
        tl.tracks[ti].sortClips()
        TimelineOps.removeEmptyTracks(&tl)
        project.timeline = tl
        return c.id
    }

    /// Text clips whose speech is stale ("Update speech according to script" on, text edited since).
    public static func staleSpeech(in tl: Timeline) -> [(text: Clip, speech: Clip)] {
        tl.allClips.compactMap { s in
            guard let info = s.tts, info.autoUpdate, let t = tl.clip(info.sourceText), case .text(let tc) = t.content,
                  tc.string != info.text, !tc.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (t, s)
        }
    }
}
