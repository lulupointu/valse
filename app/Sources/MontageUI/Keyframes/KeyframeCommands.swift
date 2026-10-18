import AppKit
import SwiftUI
import MontageCore

/// Keyframe tools state (W5): keyframe clipboard, keyframe panel visibility, graph mode. Owned by `store.keyframeUI`.
@Observable
public final class KeyframeUIState {
    /// Last keyframes copied (⌘C on a selected keyframe); ⌘V pastes them while `clipboardActive`.
    public var clipboard: KeyframeClipboard?
    /// True when the most recent copy was keyframes (a clip copy clears it, so ⌘V pastes the clips again).
    public var clipboardActive = false
    /// Keyframe panel (dope sheet + curve editor), ⌥K.
    public var showsPanel = false
    public enum GraphMode: String, CaseIterable { case value, speed }
    public var graphMode: GraphMode = .value
    public init() {}
}

/// Matching tolerance for keyframe refs (the timeline uses the same).
nonisolated let keyframeRefTolerance = Time(ticks: 1000)

extension EditorStore {
    /// Clip owning the keyframe UI focus: the selected keyframe's clip, else the single selected clip.
    public var keyframeClip: Clip? {
        if let k = timelineUI.selectedKeyframe, let c = project.timeline.clip(k.clip) { return c }
        return singleSelectedClip
    }

    /// Copies every keyframe of the clip at the selected keyframe's time (CapCut keyframe ▸ Copy).
    public func copyKeyframes(_ ref: KeyframeRef? = nil) {
        guard let ref = ref ?? timelineUI.selectedKeyframe, let c = project.timeline.clip(ref.clip) else { return }
        let cb = c.copyKeyframes(at: ref.time, tolerance: keyframeRefTolerance)
        guard !cb.entries.isEmpty else { return }
        keyframeUI.clipboard = cb
        keyframeUI.clipboardActive = true
        showToast(tr("toast.keyframesCopied"))
    }

    /// Pastes copied keyframes at the playhead on the selected clip(s). Returns false when nothing could be pasted.
    @discardableResult
    public func pasteKeyframes() -> Bool {
        guard let cb = keyframeUI.clipboard else { return false }
        let targets = selection.isEmpty ? (timelineUI.selectedKeyframe.map { [$0.clip] } ?? []) : Array(selection)
        guard !targets.isEmpty else { return false }
        let t = transport.playhead
        let box = ResultBox(0)
        edit("cmd.pasteKeyframes") { p in
            for id in targets {
                guard var c = p.timeline.clip(id), t >= c.start, t <= c.end else { continue }
                box.value += c.pasteKeyframes(cb, at: t - c.start)
                p.timeline[clip: id] = c
            }
            if box.value == 0 { throw EditError.nothingToDo }
        }
        return box.value > 0
    }

    /// "Reset keyframes" (KF-008): removes every keyframe of the selected clips, keeping the values shown now.
    public func resetKeyframes() {
        let ids = selection.isEmpty ? (keyframeClip.map { [$0.id] } ?? []) : Array(selection)
        guard ids.contains(where: { !(project.timeline.clip($0)?.keyframes.isEmpty ?? true) }) else { return }
        let t = transport.playhead
        timelineUI.selectedKeyframe = nil
        edit("cmd.resetKeyframes") { p in
            for id in ids { guard var c = p.timeline.clip(id) else { continue }; c.resetKeyframes(keepingValuesAt: t - c.start); p.timeline[clip: id] = c }
        }
    }

    /// ⇧⌥K "Add keyframe": a keyframe at the playhead for every already-keyframed property of the selected clip, or for
    /// Position & Size (position, scale, rotation) when it has none yet.
    public func addKeyframeAtPlayhead() {
        guard let c = keyframeClip, transport.playhead >= c.start, transport.playhead <= c.end else { return }
        let keys = c.keyframes.isEmpty ? ParamKey.transformGroup : c.keyframes.keys.sorted().map { ParamKey($0) }
        let local = transport.playhead - c.start, id = c.id
        edit("cmd.keyframe") { p in
            guard var clip = p.timeline.clip(id) else { return }
            for k in keys { clip.addKeyframe(k, at: local, tolerance: keyframeRefTolerance) }
            p.timeline[clip: id] = clip
        }
    }

    /// Sets the curve of the segment starting at keyframe `ref` (or of all its property's segments).
    public func setKeyframeEasing(_ e: Easing, _ ref: KeyframeRef, allSegments: Bool = false) {
        edit("cmd.keyframeCurve") { p in
            guard var c = p.timeline.clip(ref.clip) else { throw EditError.clipNotFound }
            c.setEasing(e, key: ref.key, at: ref.time, tolerance: keyframeRefTolerance, allSegments: allSegments)
            p.timeline[clip: ref.clip] = c
        }
    }

    public func toggleKeyframePanel() {
        keyframeUI.showsPanel.toggle()
        KeyframePanelController.shared.sync(self)
    }
}

/// Keyframe shortcuts (UX.md §8.2: Show/Hide keyframe panel ⌥K, Add keyframe ⇧⌥K), appended to the registry.
@MainActor
enum KeyframeShortcuts {
    static let all: [Shortcut] = [
        Shortcut("keyframePanel", "shortcut.keyframePanel", .char("k"), .option) { $0.toggleKeyframePanel() },
        Shortcut("addKeyframe", "shortcut.addKeyframe", .char("k"), [.option, .shift]) { $0.addKeyframeAtPlayhead() },
    ]
}

/// Floating "Keyframes" panel window hosting `KeyframePanel` (utility panel, follows `keyframeUI.showsPanel`).
@MainActor
final class KeyframePanelController: NSObject, NSWindowDelegate {
    static let shared = KeyframePanelController()
    private var panel: NSPanel?
    private weak var store: EditorStore?

    func sync(_ store: EditorStore) {
        self.store = store
        // UI tests: no real window may appear on screen; EditorView hosts the panel inside the offscreen test window.
        if TestAnchors.isEnabled { return }
        if store.keyframeUI.showsPanel {
            let p = panel ?? make(store)
            panel = p
            p.orderFront(nil)
        } else {
            panel?.orderOut(nil)
        }
    }

    private func make(_ store: EditorStore) -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: true)
        p.title = tr("keyframes.panel.title")
        p.isFloatingPanel = true
        p.hidesOnDeactivate = true
        p.becomesKeyOnlyIfNeeded = true
        p.delegate = self
        p.contentView = NSHostingView(rootView: KeyframePanel(store: store).environment(\.colorScheme, .dark))
        if let w = NSApp.mainWindow { p.setFrameTopLeftPoint(NSPoint(x: w.frame.midX - 280, y: w.frame.midY + 120)) }
        return p
    }

    func windowWillClose(_ notification: Notification) { store?.keyframeUI.showsPanel = false }
}
