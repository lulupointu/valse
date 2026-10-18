import SwiftUI
import MontageCore

/// Bottom timeline panel: toolbar (UX.md §6.1 / §8.3) over the GPU timeline canvas.
public struct TimelinePanel: View {
    @Bindable var store: EditorStore
    public init(store: EditorStore) { self.store = store }

    public var body: some View {
        VStack(spacing: 0) {
            if (store.project.timelines?.count ?? 0) > 1 {
                TimelineTabs(store: store)
                Rectangle().fill(Theme.headerSeparator).frame(height: 0.5)
            }
            TimelineToolbar(store: store)
            Rectangle().fill(Theme.headerSeparator).frame(height: 0.5)
            TimelineHost(store: store)
        }
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.panelRadius))
    }
}

/// Timeline toolbar. Perf (W14): the outer view reads the store (re-evaluated on every edit, cheap) and reduces it to
/// an Equatable `Model`; the bar itself (≈20 buttons with tooltips) re-renders only when the model changes, not on
/// every slider/drag tick. Actions read the store at tap time.
struct TimelineToolbar: View {
    @Bindable var store: EditorStore

    struct Model: Equatable {
        var tool: TimelineUIState.Tool
        var canUndo = false, canRedo = false
        var hasSel = false, hasTarget = false, canDelete = false
        var audioSel = false, isVideo = false, reversed = false, hasMedia = false, visualSel = false, single = false
        var mediaSel = false
        var transcriptOpen = false
        var magnet = false, snapping = false, linkage = false, previewAxis = false
        var pixelsPerSecond: Double = 0
    }

    var body: some View {
        let tl = store.project.timeline
        let ui = store.timelineUI
        let sel = store.selectedClips
        let single = store.singleSelectedClip
        let kind = single.flatMap { store.trackKind(of: $0) }
        var m = Model(tool: ui.tool)
        m.canUndo = store.canUndo; m.canRedo = store.canRedo
        m.hasSel = !sel.isEmpty
        m.hasTarget = m.hasSel || store.targetClip != nil
        m.canDelete = m.hasSel || ui.selectedTransition != nil || ui.selectedMarker != nil
        m.audioSel = kind == .audio
        m.visualSel = sel.contains { store.trackKind(of: $0)?.isVisual == true }
        m.isVideo = single?.mediaID.flatMap(store.project.asset)?.kind == .video && kind != .audio
        m.reversed = single?.reversed ?? false
        m.hasMedia = single?.mediaID != nil
        m.single = single != nil
        // UX.md §8.3 (W1): clip-type tools are hidden (not dimmed) unless a video / image clip is selected.
        m.mediaSel = sel.contains { c in
            switch c.content {
            case .media, .solid, .compound: return store.trackKind(of: c)?.isVisual == true
            default: return false
            }
        }
        m.transcriptOpen = store.ai.transcriptOpen
        m.magnet = tl.mainTrackMagnet; m.snapping = tl.snapping; m.linkage = tl.linkage
        m.previewAxis = ui.previewAxis
        m.pixelsPerSecond = store.pixelsPerSecond
        return TimelineToolbarBar(store: store, m: m).equatable()
    }
}

struct TimelineToolbarBar: View, Equatable {
    let store: EditorStore
    let m: TimelineToolbar.Model
    @State private var showLinkage = false

    nonisolated static func == (a: Self, b: Self) -> Bool { MainActor.assumeIsolated { a.m == b.m && a.store === b.store } }

    var body: some View {
        let ui = store.timelineUI
        HStack(spacing: 2) {
            Menu {
                Button(tr("toolbar.mode.select") + "  A") { store.toggleTool(.select) }
                Button(tr("toolbar.mode.split") + "  B") { store.toggleTool(.split) }
            } label: {
                Image(systemName: m.tool == .split ? "scissors" : "cursorarrow")
                    .font(.system(size: 14)).foregroundStyle(Theme.textPrimary.opacity(0.85))
            }
            .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
            .help(tr("toolbar.mode"))
            divider
            IconButton("arrow.uturn.backward", help: tr("toolbar.undo"), enabled: m.canUndo) { store.undo() }.testID("toolbar.undo")
            IconButton("arrow.uturn.forward", help: tr("toolbar.redo"), enabled: m.canRedo) { store.redo() }.testID("toolbar.redo")
            divider
            IconButton("square.split.2x1", help: tr("toolbar.split")) { store.split() }.testID("toolbar.split")
            IconButton("arrow.left.to.line", help: tr("toolbar.deleteLeft"), enabled: m.hasTarget) { store.deleteLeftRight(.head) }.testID("toolbar.deleteLeft")
            IconButton("arrow.right.to.line", help: tr("toolbar.deleteRight"), enabled: m.hasTarget) { store.deleteLeftRight(.tail) }.testID("toolbar.deleteRight")
            IconButton("trash", help: tr("toolbar.delete"), enabled: m.canDelete) { store.deleteSmart() }.testID("toolbar.delete")
            IconButton("bookmark", help: tr("toolbar.marker")) { store.addMarker() }
            if m.audioSel {
                BeatsMenu(store: store)
            } else if m.mediaSel {
                IconButton("snowflake", help: tr("toolbar.freeze"), enabled: m.isVideo) { store.freezeFrame() }
                IconButton("arrow.counterclockwise", help: tr("toolbar.reverse"), active: m.reversed, enabled: m.hasMedia) { store.reverseSelection() }
                IconButton("arrow.left.and.right.righttriangle.left.righttriangle.right", help: tr("toolbar.mirror"), enabled: m.visualSel) { store.mirrorSelection() }
                IconButton("rotate.right", help: tr("toolbar.rotate"), enabled: m.visualSel) { store.rotateSelection() }
                IconButton("crop", help: tr("toolbar.crop"), enabled: m.visualSel && m.single) { store.inspectorTab = "video" }
                // W10: Transcript-based editing (opens the transcript panel in place of the asset panel)
                IconButton("text.word.spacing", help: tr("toolbar.transcript"), active: m.transcriptOpen) { store.ai.transcriptOpen.toggle() }.testID("toolbar.transcript")
            }
            Spacer()
            VoiceoverButton(store: store)
            divider
            IconButton("magnet", help: tr(m.magnet ? "toolbar.magnet.off" : "toolbar.magnet.on"), active: m.magnet) {
                store.setOption(.magnet(!store.project.timeline.mainTrackMagnet))
            }.testID("toolbar.magnet")
            IconButton("arrow.right.and.line.vertical.and.arrow.left", help: tr(m.snapping ? "toolbar.snapping.off" : "toolbar.snapping.on"), active: m.snapping) {
                store.setOption(.snapping(!store.project.timeline.snapping))
            }.testID("toolbar.snapping")
            IconButton("link", help: tr(m.linkage ? "toolbar.linkage.off" : "toolbar.linkage.on"), active: m.linkage) {
                store.setOption(.linkage(!store.project.timeline.linkage))
            }.testID("toolbar.linkage")
            Button { showLinkage.toggle() } label: {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.textSecondary).frame(width: 12, height: 26)
            }
            .buttonStyle(.plain).help(tr("linkage.title"))
            .popover(isPresented: $showLinkage, arrowEdge: .bottom) { LinkageSettingsView(store: store) }
            IconButton("rectangle.and.hand.point.up.left", help: tr(m.previewAxis ? "toolbar.previewAxis.off" : "toolbar.previewAxis.on"), active: m.previewAxis) {
                ui.previewAxis.toggle()
            }
            divider
            IconButton("arrow.left.and.right.square", help: tr("toolbar.zoomFit")) { store.zoomTimelineToFit() }.testID("toolbar.zoomFit")
            IconButton("minus.magnifyingglass", help: tr("toolbar.zoomOut")) { store.zoomTimeline(by: 1 / 1.25) }.testID("toolbar.zoomOut")
            Slider(value: Binding(get: { log(m.pixelsPerSecond) }, set: { v in store.zoomTimeline(by: exp(v) / store.pixelsPerSecond) }),
                   in: log(2)...log(1200))
                .controlSize(.mini).frame(width: 90).tint(.white).testID("toolbar.zoomSlider")
            IconButton("plus.magnifyingglass", help: tr("toolbar.zoomIn")) { store.zoomTimeline(by: 1.25) }.testID("toolbar.zoomIn")
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
    }

    private var divider: some View { Divider().frame(height: 16).padding(.horizontal, 4) }
}

/// "Linkage settings" popover (UX.md §6.6, [94]): which item types follow the main track.
struct LinkageSettingsView: View {
    @Bindable var store: EditorStore
    var body: some View {
        let excluded = Set(store.project.timeline.linkageExcluded ?? [])
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: tr("linkage.title")).font(Theme.Fonts.sectionTitle)
            Text(verbatim: tr("linkage.message")).font(Theme.Fonts.hint).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(LinkageCategory.allCases, id: \.self) { c in
                Toggle(isOn: Binding(get: { !excluded.contains(c) }, set: { store.setLinkage(c, enabled: $0) })) {
                    Text(verbatim: tr(c.nameKey)).font(Theme.Fonts.row)
                }
                .toggleStyle(.checkbox)
            }
        }
        .padding(14)
        .frame(width: 240)
    }
}

struct TimelineHost: NSViewRepresentable {
    let store: EditorStore
    func makeNSView(context: Context) -> TimelineView {
        let v = TimelineView(store: store)
        v.setAccessibilityIdentifier("timeline")
        SnapshotRegistry.shared.timeline = v
        return v
    }
    func updateNSView(_ v: TimelineView, context: Context) {}
    /// Fills the proposal (perf: without this SwiftUI measures the AppKit view with Auto Layout `fittingSize` on every pass).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TimelineView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 10, height: 10))
    }
}
