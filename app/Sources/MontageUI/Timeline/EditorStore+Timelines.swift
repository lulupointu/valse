import SwiftUI
import AppKit
import MontageCore
import MontageEngine
import Perception

/// Multi-timeline (TL-023): new / switch / rename / duplicate / delete timelines. Each is one undo step; the active
/// timeline lives in `project.timeline`, so the rest of the editor is unaware of the others.
extension EditorStore {
    /// Tabs (nil / empty = single timeline, no tab strip).
    public var timelineSlots: [TimelineSlot] { project.timelines ?? [] }
    var otherTimelineCount: Int { max(timelineSlots.count - 1, 0) }

    func nextTimelineName() -> String {
        let used = Set(timelineSlots.map(\.name))
        var n = max(timelineSlots.count, 1) + 1
        while used.contains(tr("timelines.nameN", n)) { n += 1 }
        return tr("timelines.nameN", n)
    }

    /// "New timeline" (empty, same sequence settings) or "New timeline with selected items".
    public func newTimeline(withSelection: Bool = false) {
        let clips = withSelection ? selection : []
        if withSelection && clips.isEmpty { return }
        let name = nextTimelineName(), first = tr("timelines.nameN", 1)
        if perform(Edit("cmd.newTimeline") { p in CompoundEditing.exitAll(&p); try MultiTimelineOps.newTimeline(&p, name: name, firstName: first, clips: clips) }) {
            selection = []
            showToast(tr("timelines.created", name))
        }
    }

    public func switchTimeline(_ id: TimelineSlotID) {
        guard id != project.activeTimelineID else { return }
        engine.pause()
        if perform(Edit("cmd.switchTimeline") { p in CompoundEditing.exitAll(&p); try MultiTimelineOps.switchTo(&p, id) }) {
            selection = []
            seek(to: .zero)
        }
    }

    public func renameTimeline(_ id: TimelineSlotID, to name: String) {
        perform(Edit("cmd.renameTimeline") { p in try MultiTimelineOps.rename(&p, id, to: name) })
    }

    public func duplicateTimeline(_ id: TimelineSlotID) {
        let base = timelineSlots.first { $0.id == id }?.name ?? ""
        let name = tr("timelines.copyOf", base)
        if perform(Edit("cmd.duplicateTimeline") { p in CompoundEditing.exitAll(&p); try MultiTimelineOps.duplicate(&p, id, name: name) }) { selection = [] }
    }

    public func deleteTimeline(_ id: TimelineSlotID) {
        if perform(Edit("cmd.deleteTimeline") { p in CompoundEditing.exitAll(&p); try MultiTimelineOps.delete(&p, id) }) { selection = [] }
    }

    // MARK: Edit inside compound clips (TL-021) / groups (TL-020)

    /// The project as exported / seen from outside every compound being edited.
    public var rootProject: Project {
        var p = project
        CompoundEditing.exitAll(&p)
        return p
    }

    /// Double-click a compound clip: its nested timeline opens in the timeline and the player.
    public func enterCompound(_ id: ClipID) {
        engine.pause()
        if perform(Edit("cmd.enterCompound") { p in try CompoundEditing.enter(id, in: &p) }) {
            selection = []
            seek(to: .zero)
        }
    }

    /// Breadcrumb "‹" / Esc: back to the parent timeline (the compound clip shows the edits).
    public func exitCompound(all: Bool = false) {
        guard project.isInsideCompound else { return }
        engine.pause()
        let id = project.compoundEdit?.first?.clipID, inner = project.compoundEdit?.last?.clipID
        if perform(Edit("cmd.exitCompound") { p in if all { CompoundEditing.exitAll(&p) } else { try CompoundEditing.exit(&p) } }) {
            if let c = (all ? id : inner).flatMap({ project.timeline.clip($0) }) { selection = [c.id]; seek(to: c.start) }
        }
    }

    /// Double-click a grouped clip: select only it, to edit it on its own (CapCut "enter the group").
    public func enterGroup(_ id: ClipID) {
        guard project.timeline.clip(id)?.groupID != nil else { return }
        selection = [id]
        ui.selectedTransition = nil; ui.selectedMarker = nil
        showToast(tr("group.entered"))
    }

    /// ⌃⇥ / ⌃⇧⇥: next / previous timeline tab.
    public func cycleTimeline(_ delta: Int) {
        let s = timelineSlots
        guard s.count > 1, let i = s.firstIndex(where: { $0.id == project.activeTimelineID }) else { return }
        switchTimeline(s[(i + delta + s.count) % s.count].id)
    }

    /// "Play audio while scrubbing" (TL-032 / AU-023): a short grain of the audio under the dragged playhead.
    func scrubAudio(at t: Time) {
        guard AppPreferences.shared.settings.scrubAudio, !isPreviewing else { return }
        ScrubAudio.shared.scrub(project, at: t.clamped(.zero, project.duration))
    }

    /// Preview axis in "Video + audio" mode (TL-031): an audio grain of what the hovered time sounds like.
    func previewAxisAudio(at t: Time) {
        guard !isPreviewing else { return }
        ScrubAudio.shared.scrub(project, at: t.clamped(.zero, project.duration))
    }

    // MARK: Frame rate (SP-009)

    /// First video differs from the project rate → offer "Change frame rate for this project?".
    func offerFrameRate(of asset: MediaAsset) {
        guard asset.kind == .video, let f = asset.frameRate else { return }
        let r = FrameRate.nearest(to: f.fps)
        timelineUI.frameRatePrompt = abs(r.fps - project.settings.frameRate.fps) > 0.01 ? r : nil
    }

    /// Accepts the prompt (one undo step; all timelines keep their own rate).
    public func changeProjectFrameRate(_ r: FrameRate) {
        timelineUI.frameRatePrompt = nil
        if perform(Edit("cmd.projectFrameRate") { p in p.settings.frameRate = r }) {
            showToast(tr("framerate.changed", HomeFormat.fps(r)))
        }
    }

    /// "Make video playback smoother": optical-flow interpolation on every video clip slower than the project rate.
    @discardableResult
    public func smoothPlayback(_ on: Bool) -> Int {
        let ids = Set(FrameUpconversion.candidates(project))
        guard !ids.isEmpty else { return 0 }
        perform(Edit("cmd.smoothPlayback") { p in
            for ti in p.timeline.tracks.indices {
                for ci in p.timeline.tracks[ti].clips.indices where ids.contains(p.timeline.tracks[ti].clips[ci].id) {
                    p.timeline.tracks[ti].clips[ci].smoothSlowMo = on ? .opticalFlow : nil
                }
            }
        })
        return ids.count
    }

    /// Effective "Import material" for this project (project setting, else Settings ▸ Project), SE-010.
    public var copiesMediaOnImport: Bool {
        project.settings.copyMediaOnImport ?? AppPreferences.shared.settings.copyMediaOnImport
    }
}

/// Timeline tab strip (TL-023) above the timeline toolbar, shown when the project has several timelines: click =
/// switch, double-click = rename, right-click = Rename / Duplicate / Delete, "+" = new timeline.
struct TimelineTabs: View {
    @Perception.Bindable var store: EditorStore
    @State private var renaming: TimelineSlotID?
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        WithPerceptionTracking {
            let slots = store.timelineSlots
            let active = store.project.activeTimelineID
            HStack(spacing: 2) {
                ForEach(Array(slots.enumerated()), id: \.element.id) { i, s in
                    WithPerceptionTracking {
                        tab(s, index: i, active: s.id == active, canDelete: slots.count > 1)
                    }
                }
                Button { store.newTimeline() } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(tr("timelines.new")).testID("timelines.new")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Theme.panel)
            .testID("timelines.tabs")
        }
    }

    @ViewBuilder
    func tab(_ s: TimelineSlot, index: Int, active: Bool, canDelete: Bool) -> some View {
        Group {
            if renaming == s.id {
                TextField("", text: $draft)
                    .textFieldStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Theme.textPrimary)
                    .frame(width: 120)
                    .focused($focused)
                    .onSubmit { store.renameTimeline(s.id, to: draft); renaming = nil }
                    .onExitCommand { renaming = nil }
                    .onAppear { focused = true }
                    .testID("timelines.renameField")
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "film").font(.system(size: 10))
                    Text(verbatim: s.name).font(.system(size: 11.5, weight: active ? .semibold : .regular)).lineLimit(1)
                }
                .foregroundStyle(active ? Theme.accent : Theme.textSecondary)
            }
        }
        .padding(.horizontal, 10).frame(height: 22)
        .background(active ? Theme.accent.opacity(0.14) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { store.switchTimeline(s.id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { draft = s.name; renaming = s.id })
        .contextMenu {
            Button(tr("timelines.rename")) { draft = s.name; renaming = s.id }
            Button(tr("timelines.duplicate")) { store.duplicateTimeline(s.id) }
            Divider()
            Button(tr("timelines.delete")) { store.deleteTimeline(s.id) }.disabled(!canDelete)
        }
        .testID("timelines.tab.\(index)")
    }
}

/// "Change frame rate for this project?" (SP-009, CapCut prompt after adding the first video).
struct FrameRatePrompt: View {
    let store: EditorStore
    let rate: FrameRate
    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 10) {
                Image(systemName: "speedometer").foregroundStyle(Theme.accent)
                Text(verbatim: tr("framerate.prompt", HomeFormat.fps(rate), HomeFormat.fps(store.project.settings.frameRate)))
                    .font(.system(size: 12)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer()
                Button(tr("framerate.change", HomeFormat.fps(rate))) { store.changeProjectFrameRate(rate) }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small).testID("framerate.change")
                Button(tr("framerate.keep")) { store.timelineUI.frameRatePrompt = nil }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small).testID("framerate.keep")
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(Theme.accent.opacity(0.12))
            .testID("framerate.prompt")
        }
    }
}

/// Breadcrumb above the timeline while editing inside a compound clip (TL-021): "‹ Main timeline › Compound 1".
struct CompoundBreadcrumb: View {
    let store: EditorStore
    let path: [String]
    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 6) {
                Button { store.exitCompound() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                        Text(loc: "compound.back")
                    }
                }
                .buttonStyle(SecondaryButtonStyle()).controlSize(.small).testID("compound.back")
                Button { store.exitCompound(all: true) } label: { Text(loc: "compound.root") }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).testID("compound.root")
                ForEach(Array(path.enumerated()), id: \.offset) { i, name in
                    WithPerceptionTracking {
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
                        Text(verbatim: name).font(.system(size: 12, weight: i == path.count - 1 ? .semibold : .regular))
                            .foregroundStyle(i == path.count - 1 ? Theme.textPrimary : Theme.textSecondary)
                    }
                }
                Spacer()
                Text(loc: "compound.editingHint").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(Theme.accent.opacity(0.1))
            .testID("compound.breadcrumb")
        }
    }
}
