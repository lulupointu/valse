import SwiftUI
import MontageCore

/// Bottom timeline panel: toolbar (UX.md §6.1 / §8.3) over the GPU timeline canvas.
public struct TimelinePanel: View {
    @Bindable var store: EditorStore
    public init(store: EditorStore) { self.store = store }

    public var body: some View {
        VStack(spacing: 0) {
            TimelineToolbar(store: store)
            Rectangle().fill(Theme.headerSeparator).frame(height: 0.5)
            TimelineHost(store: store)
        }
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.panelRadius))
    }
}

struct TimelineToolbar: View {
    @Bindable var store: EditorStore
    @State private var showLinkage = false

    var body: some View {
        let tl = store.project.timeline
        let ui = store.timelineUI
        let sel = store.selectedClips
        let hasSel = !sel.isEmpty
        let single = store.singleSelectedClip
        let kind = single.flatMap { store.trackKind(of: $0) }
        let visualSel = sel.contains { store.trackKind(of: $0)?.isVisual == true }
        let isVideo = single?.mediaID.flatMap(store.project.asset)?.kind == .video && kind != .audio
        HStack(spacing: 2) {
            Menu {
                Button(tr("toolbar.mode.select") + "  A") { store.toggleTool(.select) }
                Button(tr("toolbar.mode.split") + "  B") { store.toggleTool(.split) }
            } label: {
                Image(systemName: ui.tool == .split ? "scissors" : "cursorarrow")
                    .font(.system(size: 14)).foregroundStyle(Theme.textPrimary.opacity(0.85))
            }
            .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
            .help(tr("toolbar.mode"))
            divider
            IconButton("arrow.uturn.backward", help: tr("toolbar.undo"), enabled: store.session.canUndo) { store.undo() }.testID("toolbar.undo")
            IconButton("arrow.uturn.forward", help: tr("toolbar.redo"), enabled: store.session.canRedo) { store.redo() }.testID("toolbar.redo")
            divider
            IconButton("square.split.2x1", help: tr("toolbar.split")) { store.split() }.testID("toolbar.split")
            IconButton("arrow.left.to.line", help: tr("toolbar.deleteLeft"), enabled: hasSel || store.targetClip != nil) { store.deleteLeftRight(.head) }.testID("toolbar.deleteLeft")
            IconButton("arrow.right.to.line", help: tr("toolbar.deleteRight"), enabled: hasSel || store.targetClip != nil) { store.deleteLeftRight(.tail) }.testID("toolbar.deleteRight")
            IconButton("trash", help: tr("toolbar.delete"), enabled: hasSel || ui.selectedTransition != nil || ui.selectedMarker != nil) { store.deleteSmart() }.testID("toolbar.delete")
            IconButton("bookmark", help: tr("toolbar.marker")) { store.addMarker() }
            if kind == .audio {
                BeatsMenu(store: store)
            } else if hasSel {
                IconButton("snowflake", help: tr("toolbar.freeze"), enabled: isVideo) { store.freezeFrame() }
                IconButton("arrow.counterclockwise", help: tr("toolbar.reverse"), active: single?.reversed ?? false, enabled: single?.mediaID != nil) { store.reverseSelection() }
                IconButton("arrow.left.and.right.righttriangle.left.righttriangle.right", help: tr("toolbar.mirror"), enabled: visualSel) { store.mirrorSelection() }
                IconButton("rotate.right", help: tr("toolbar.rotate"), enabled: visualSel) { store.rotateSelection() }
                IconButton("crop", help: tr("toolbar.crop"), enabled: visualSel && single != nil) { store.inspectorTab = "video" }
            }
            Spacer()
            VoiceoverButton(store: store)
            divider
            IconButton("magnet", help: tr(tl.mainTrackMagnet ? "toolbar.magnet.off" : "toolbar.magnet.on"), active: tl.mainTrackMagnet) {
                store.setOption(.magnet(!tl.mainTrackMagnet))
            }.testID("toolbar.magnet")
            IconButton("arrow.right.and.line.vertical.and.arrow.left", help: tr(tl.snapping ? "toolbar.snapping.off" : "toolbar.snapping.on"), active: tl.snapping) {
                store.setOption(.snapping(!tl.snapping))
            }.testID("toolbar.snapping")
            IconButton("link", help: tr(tl.linkage ? "toolbar.linkage.off" : "toolbar.linkage.on"), active: tl.linkage) {
                store.setOption(.linkage(!tl.linkage))
            }.testID("toolbar.linkage")
            Button { showLinkage.toggle() } label: {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.textSecondary).frame(width: 12, height: 26)
            }
            .buttonStyle(.plain).help(tr("linkage.title"))
            .popover(isPresented: $showLinkage, arrowEdge: .bottom) { LinkageSettingsView(store: store) }
            IconButton("rectangle.and.hand.point.up.left", help: tr(ui.previewAxis ? "toolbar.previewAxis.off" : "toolbar.previewAxis.on"), active: ui.previewAxis) {
                ui.previewAxis.toggle()
            }
            divider
            IconButton("arrow.left.and.right.square", help: tr("toolbar.zoomFit")) { store.zoomTimelineToFit() }.testID("toolbar.zoomFit")
            IconButton("minus.magnifyingglass", help: tr("toolbar.zoomOut")) { store.zoomTimeline(by: 1 / 1.25) }.testID("toolbar.zoomOut")
            Slider(value: Binding(get: { log(store.pixelsPerSecond) }, set: { v in store.zoomTimeline(by: exp(v) / store.pixelsPerSecond) }),
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
}
