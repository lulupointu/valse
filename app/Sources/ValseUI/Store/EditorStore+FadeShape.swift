import ValseCore

extension EditorStore {
    /// Sets the fade-in (or fade-out) curve of a clip: one undo step.
    public func setFadeShape(_ id: ClipID, fadeIn: Bool, _ shape: FadeShape) {
        edit("cmd.fadeShape") { p in
            if fadeIn { p.timeline[clip: id]?.audio.fadeInShape = shape } else { p.timeline[clip: id]?.audio.fadeOutShape = shape }
        }
    }
}
