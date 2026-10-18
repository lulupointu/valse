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
    public init(sourceText: ClipID, voice: String, rate: Double = 1, pitch: Double = 1, text: String, autoUpdate: Bool = true) {
        self.sourceText = sourceText; self.voice = voice; self.rate = rate; self.pitch = pitch; self.text = text; self.autoUpdate = autoUpdate
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
