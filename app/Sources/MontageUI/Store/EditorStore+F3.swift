import AppKit
import MontageCore

/// Finisher F3 editor actions (media / canvas / text / audio rows).
extension EditorStore {
    // MARK: MI-014 audio streams

    public func setAudioStream(_ index: Int) {
        let ids = selectedClips.map(\.id)
        edit("cmd.audioStream") { p in try TimelineOps.setAudioStream(ids, index, in: &p) }
    }

    public func separateAudioStreams() {
        guard let c = singleSelectedClip else { return }
        edit("cmd.separateStreams") { p in try TimelineOps.separateAudioStreams(c.id, in: &p) }
    }
}
