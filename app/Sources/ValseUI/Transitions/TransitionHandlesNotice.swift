import ValseCore

extension EditorStore {
    /// CapCut's "Create duplicate frames for transition" notice (TR-MODEL-CAPCUT): after a transition is added or
    /// lengthened at the cut after `id`, when an overlap transition finds less media than half its duration past one of
    /// the clips' edges (the edge frame is then held). Informational only: the transition is applied either way.
    /// "Don't remind me again" silences it until the editor is closed (CapCut: "before exiting editing").
    public func noteTransitionHandles(after id: ClipID) {
        guard !duplicateFramesNoticeOff, TimelineOps.transitionNeedsDuplicateFrames(after: id, in: project) else { return }
        showToast(tr("transition.duplicateFrames"), actionTitle: tr("transition.duplicateFrames.dontRemind")) { [weak self] in
            self?.duplicateFramesNoticeOff = true
            self?.toast = nil
        }
    }
}
