import Foundation

/// Multi-audio-track media (MI-014): right-click ▸ Audio track ▸ Track N picks the stream a clip plays; "Separate audio
/// tracks" puts every stream of a video clip on its own audio track (linked like Extract audio, so Restore audio undoes it).
extension TimelineOps {
    /// Number of audio streams of the clip's media (1 for ordinary files, 0 without sound).
    public static func audioStreamCount(_ c: Clip, in project: Project) -> Int {
        guard let a = c.mediaID.flatMap(project.asset), a.hasAudio else { return 0 }
        return max(1, a.techInfo?.audioTrackCount ?? 1)
    }

    /// Chooses the stream (0-based) the clips play; 0 is stored as nil (the default).
    public static func setAudioStream(_ ids: [ClipID], _ index: Int, in project: inout Project) throws {
        var changed = false
        for id in ids {
            guard let c = project.timeline.clip(id) else { throw EditError.clipNotFound }
            let n = audioStreamCount(c, in: project)
            guard index >= 0, index < n else { continue }
            let v: Int? = index == 0 ? nil : index
            if c.audioStreamIndex != v { project.timeline[clip: id]?.audioStreamIndex = v; changed = true }
        }
        if !changed { throw EditError.nothingToDo }
    }

    /// One audio clip per stream on new audio tracks, the video clip muted. Returns the new clip ids (stream order).
    @discardableResult
    public static func separateAudioStreams(_ id: ClipID, in project: inout Project) throws -> [ClipID] {
        guard let c = project.timeline.clip(id) else { throw EditError.clipNotFound }
        let n = audioStreamCount(c, in: project)
        guard n > 1, !c.audio.isMuted else { throw EditError.nothingToDo }
        var out: [ClipID] = []
        for k in 0..<n {
            var tl = project.timeline
            var src = c; src.audioStreamIndex = k == 0 ? nil : k
            tl[clip: id] = src
            project.timeline = tl
            let x = try extractAudio(id, in: &project)
            out.append(x)
            project.timeline[clip: id]?.audio.isMuted = false   // keep extracting the next stream
        }
        project.timeline[clip: id]?.audioStreamIndex = c.audioStreamIndex
        project.timeline[clip: id]?.audio.isMuted = true
        return out
    }
}
