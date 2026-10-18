import SwiftUI
import AppKit
import MontageCore
import MontageEngine

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
        if perform(Edit("cmd.newTimeline") { p in try MultiTimelineOps.newTimeline(&p, name: name, firstName: first, clips: clips) }) {
            selection = []
            showToast(tr("timelines.created", name))
        }
    }

    public func switchTimeline(_ id: TimelineSlotID) {
        guard id != project.activeTimelineID else { return }
        engine.pause()
        if perform(Edit("cmd.switchTimeline") { p in try MultiTimelineOps.switchTo(&p, id) }) {
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
        if perform(Edit("cmd.duplicateTimeline") { p in try MultiTimelineOps.duplicate(&p, id, name: name) }) { selection = [] }
    }

    public func deleteTimeline(_ id: TimelineSlotID) {
        if perform(Edit("cmd.deleteTimeline") { p in try MultiTimelineOps.delete(&p, id) }) { selection = [] }
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

    /// Effective "Import material" for this project (project setting, else Settings ▸ Project), SE-010.
    public var copiesMediaOnImport: Bool {
        project.settings.copyMediaOnImport ?? AppPreferences.shared.settings.copyMediaOnImport
    }
}

/// Timeline tab strip (TL-023) above the timeline toolbar, shown when the project has several timelines: click =
/// switch, double-click = rename, right-click = Rename / Duplicate / Delete, "+" = new timeline.
struct TimelineTabs: View {
    @Bindable var store: EditorStore
    @State private var renaming: TimelineSlotID?
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let slots = store.timelineSlots
        let active = store.project.activeTimelineID
        HStack(spacing: 2) {
            ForEach(Array(slots.enumerated()), id: \.element.id) { i, s in
                tab(s, index: i, active: s.id == active, canDelete: slots.count > 1)
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
