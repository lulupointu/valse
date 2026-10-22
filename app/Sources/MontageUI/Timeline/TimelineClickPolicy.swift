import MontageCore

/// OB-02 / OB-03: what a plain click (no ⇧/⌘, no drag) in the timeline does with the playhead.
///
/// - Something selected (clip, transition, marker, keyframe) + click on empty track space or the grey header column:
///   deselect only, the playhead stays.
/// - Click on an unselected clip, or on any clip while several are selected: it becomes the only selection, the playhead
///   stays.
/// - Click on the clip that already is the only selection (its group counts as one element): the playhead moves to
///   the clicked time.
/// - Nothing selected + click on empty space: the playhead moves there (the grey header column = time 0).
/// ⇧/⌘ clicks keep their behaviour (they extend the selection and do not deselect; on empty space they still seek).
enum TimelineClickPolicy {
    static func emptyClickSeeks(hadSelection: Bool, additive: Bool) -> Bool { additive || !hadSelection }

    static func clipClickSeeks(selectionBefore: Set<ClipID>, clickedGroup: Set<ClipID>, additive: Bool) -> Bool {
        !additive && !selectionBefore.isEmpty && selectionBefore == clickedGroup
    }
}

extension EditorStore {
    /// Anything selected in the timeline (clips, a transition, a marker or a keyframe).
    var hasTimelineSelection: Bool {
        !selection.isEmpty || ui.selectedTransition != nil || ui.selectedMarker != nil || ui.selectedKeyframe != nil
    }
}
