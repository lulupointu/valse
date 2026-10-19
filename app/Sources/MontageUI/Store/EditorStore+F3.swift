import AppKit
import MontageCore
import MontageEngine

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

    // MARK: MI-006 auto-relink at open

    /// Looks for missing media in the project's folder, previously used relink folders and near their old location;
    /// relinks what it finds (one undo step + toast). Returns the number relinked.
    @discardableResult
    public func autoRelinkMissing() async -> Int {
        let missing = missingMedia
        guard !missing.isEmpty else { return 0 }
        let pkg = packageURL, remembered = MediaAutoRelink.rememberedFolders
        let found = await Task.detached { MediaAutoRelink.search(missing: missing, packageURL: pkg, remembered: remembered) }.value
        guard !found.isEmpty else { return 0 }
        perform(Edit("cmd.autoRelink") { MediaRelinker.apply(found, to: &$0) })
        showToast(tr("toast.autoRelinked", found.count))
        return found.count
    }
}
