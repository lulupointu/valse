import AppKit
import MontageCore

/// AU-004 "Volume +0.1 dB / −0.1 dB" (CapCut ⌘. / ⌘,) on the selected clips that carry sound. With volume keyframes the
/// step edits (or adds) the keyframe at the playhead, like the inspector does. One undo step per press.
extension EditorStore {
    var canNudgeVolume: Bool { !audioClips.isEmpty }

    public func nudgeVolume(by stepDB: Double) {
        let clips = audioClips
        guard !clips.isEmpty else { return }
        let t = playhead
        var shown = 0.0
        let changes: [(ClipID, Double, Time)] = clips.map { c in
            let local = min(max(t - c.start, .zero), c.duration)
            let cur = c.value(.volume, at: local)?.scalar ?? c.audio.volume
            let next = VolumeNudge.nudged(cur, by: stepDB)
            return (c.id, next, local)
        }
        shown = changes.first?.1 ?? 0
        perform(Edit("cmd.volume") { p in
            for (id, v, local) in changes { p.timeline[clip: id]?.setValue(.volume, .scalar(v), at: local) }
        })
        showToast(tr("audio.volume.toast", TrackVolumeMath.label(VolumeNudge.db(shown))))
    }
}

/// Finisher F3 shortcuts (appended to `ShortcutRegistry.builtins`).
enum F3Shortcuts {
    static let all: [Shortcut] = [
        Shortcut("volumeUp", "shortcut.volumeUp", .char("."), .command, isEnabled: { $0.canNudgeVolume }) { $0.nudgeVolume(by: 0.1) },
        // ⌘, is also Settings…: it only adjusts the volume while a clip with sound is selected (else the menu gets it).
        Shortcut("volumeDown", "shortcut.volumeDown", .char(","), .command, isEnabled: { $0.canNudgeVolume }) { $0.nudgeVolume(by: -0.1) },
    ]
}
