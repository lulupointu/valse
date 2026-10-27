import Foundation

/// One caption track per language (CAP-LANG-TRACKS, owner decision 2026-10-27): `Track.captionLanguage` names it, a
/// translation is a second caption track with the same timing that then diverges freely, "Shown in video" is the
/// track's visibility, bilingual = two visible tracks stacked. The old bilingual sub-line (`CaptionData.translation`)
/// becomes such a track when a project is opened.
public enum CaptionLanguageTracks {
    /// "fr-FR" → "fr-FR", "FR" → "fr", "" → nil.
    public static func normalized(_ code: String?) -> String? {
        guard let c = code?.trimmingCharacters(in: .whitespaces), !c.isEmpty else { return nil }
        let parts = c.replacingOccurrences(of: "_", with: "-").split(separator: "-")
        guard let first = parts.first else { return nil }
        return ([first.lowercased()] + parts.dropFirst().map(String.init)).joined(separator: "-")
    }

    /// Vertical offset of a stacked (bilingual) track: one caption block above the source.
    static func stackOffset(fontSize: Double) -> Double { -max(fontSize, 0.03) * 2.4 }

    /// A copy of caption track `source` in another language: same timing and look, new clip ids, texts from `texts`
    /// (by source clip id; missing = empty). `stacked` puts it above the source (bilingual display). Returns the new
    /// track id. The source's word timings are dropped (they belong to the other language).
    @discardableResult
    public static func addLanguage(from source: TrackID, language: String, texts: [ClipID: String], hidden: Bool,
                                   stacked: Bool, in project: inout Project) throws -> TrackID {
        var tl = project.timeline
        guard let si = tl.trackIndex(source) else { throw EditError.clipNotFound }
        let src = tl.tracks[si]
        let id = TimelineOps.addTrack(.text, to: &tl, above: si)
        guard let ti = tl.trackIndex(id) else { throw EditError.clipNotFound }
        var clips: [Clip] = []
        for c in src.clips {
            guard var t = CaptionOps.text(c) else { continue }
            var n = c
            n.id = ClipID()
            let s = texts[c.id] ?? ""
            t.string = s; t.runs = []
            if var d = t.caption { d.words = []; d.translation = nil; d.display = nil; d.subStyle = nil; d.origin = .manual; t.caption = d }
            else { t.caption = CaptionData(origin: .manual) }
            n.content = .text(t)
            n.name = s.replacingOccurrences(of: "\n", with: " ")
            n.linkedTo = c.linkedTo
            if stacked { n.transform.position.y += stackOffset(fontSize: t.fontSize) }
            clips.append(n)
        }
        tl.tracks[ti].clips = clips
        tl.tracks[ti].isHidden = hidden
        tl.tracks[ti].isCaptions = src.isCaptions
        tl.tracks[ti].captionLanguage = normalized(language)
        tl.tracks[ti].captionSplit = src.captionSplit
        project.timeline = tl
        return id
    }

    /// Opening a project: every caption track gets a language (detected from its text by `detect`) and each bilingual
    /// sub-line (`CaptionData.translation`) moves to its own language track. "Translation only" hides the original.
    /// Returns true when something changed.
    @discardableResult
    public static func migrate(_ project: inout Project, detect: (String) -> String?) -> Bool {
        var changed = false
        for ti in CaptionOps.captionTracks(project.timeline).reversed() {
            let track = project.timeline.tracks[ti]
            if track.captionLanguage == nil {
                let sample = track.clips.prefix(30).compactMap { CaptionOps.text($0)?.string }.joined(separator: " ")
                if let l = normalized(detect(sample)) { project.timeline.tracks[ti].captionLanguage = l; changed = true }
            }
            var texts: [ClipID: String] = [:]
            var onlyTranslation = false
            for c in track.clips {
                guard let d = CaptionOps.text(c)?.caption, let tr = d.translation, !tr.isEmpty else { continue }
                texts[c.id] = tr
                if d.display == .translationOnly { onlyTranslation = true }
            }
            guard !texts.isEmpty else { continue }
            let lang = normalized(detect(texts.values.prefix(30).joined(separator: " "))) ?? "und"
            guard (try? addLanguage(from: track.id, language: lang, texts: texts, hidden: false, stacked: !onlyTranslation,
                                    in: &project)) != nil, let si = project.timeline.trackIndex(track.id) else { continue }
            for k in project.timeline.tracks[si].clips.indices {
                guard var t = CaptionOps.text(project.timeline.tracks[si].clips[k]), t.caption != nil else { continue }
                t.caption?.translation = nil; t.caption?.display = nil; t.caption?.subStyle = nil
                project.timeline.tracks[si].clips[k].content = .text(t)
            }
            if onlyTranslation { project.timeline.tracks[si].isHidden = true }
            changed = true
        }
        return changed
    }
}
