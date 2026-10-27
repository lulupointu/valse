import AppKit
import ValseCore

/// SE-017 VoiceOver for the custom-drawn timeline: the view is a labelled group whose children are its visible clips
/// (button role: "Ocean, video, 0:00, 6.0 s, selected"); VO-Space selects a clip. The ruler reports the playhead.
extension TimelineView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { tr("ax.timeline") }
    override func accessibilityValue() -> Any? {
        tr("ax.timeline.value", store.project.timeline.allClips.count, Timecode.display(store.transport.playhead, rate: store.project.settings.frameRate))
    }

    override func accessibilityChildren() -> [Any]? {
        let l = layoutNow
        let tl = store.project.timeline
        var out: [NSAccessibilityElement] = []
        for row in l.rows {
            let track = tl.tracks[row.trackIndex]
            for clip in track.clips {
                let r = l.clipRect(clip, row: row)
                guard r.maxX > TimelineLayout.headerWidth, r.minX < bounds.width, out.count < 300 else { continue }
                let e = TimelineClipAXElement()
                e.view = self; e.clipID = clip.id
                e.setAccessibilityRole(.button)
                e.setAccessibilityParent(self)
                var parts = [clipDisplayName(clip), tr("ax.kind.\(Self.displayKind(clip, track: track).rawValue)"),
                             Timecode.shortDuration(clip.start), Self.durationLabel(clip.duration)]
                if store.selection.contains(clip.id) { parts.append(tr("ax.selected")) }
                if !clip.isEnabled { parts.append(tr("ax.disabled")) }
                e.setAccessibilityLabel(parts.joined(separator: ", "))
                e.setAccessibilityFrameInParentSpace(r.intersection(bounds))
                out.append(e)
            }
        }
        return out
    }
}

nonisolated final class TimelineClipAXElement: NSAccessibilityElement {
    nonisolated(unsafe) weak var view: TimelineView?
    nonisolated(unsafe) var clipID: ClipID?
    override func accessibilityPerformPress() -> Bool {
        guard let id = clipID, let v = view else { return false }
        let box = UncheckedSendableBox(v)
        return MainActor.assumeIsolated {
            box.value.store.select([id])
            return true
        }
    }
}
