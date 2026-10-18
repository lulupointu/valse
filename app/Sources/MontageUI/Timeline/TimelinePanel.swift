import SwiftUI
import MontageCore

/// Bottom timeline panel: toolbar (UX.md §8.3) over the GPU timeline canvas.
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
    var body: some View {
        let tl = store.project.timeline
        let hasSel = !store.selection.isEmpty
        HStack(spacing: 2) {
            IconButton("arrow.uturn.backward", help: tr("toolbar.undo"), enabled: store.session.canUndo) { store.undo() }
            IconButton("arrow.uturn.forward", help: tr("toolbar.redo"), enabled: store.session.canRedo) { store.redo() }
            Divider().frame(height: 16).padding(.horizontal, 4)
            IconButton("scissors", help: tr("toolbar.split")) { store.splitAtPlayhead() }
            IconButton("arrow.left.to.line", help: tr("toolbar.deleteLeft"), enabled: hasSel) { store.trimSelection(.head) }
            IconButton("arrow.right.to.line", help: tr("toolbar.deleteRight"), enabled: hasSel) { store.trimSelection(.tail) }
            IconButton("trash", help: tr("toolbar.delete"), enabled: hasSel) { store.deleteSelection() }
            Spacer()
            IconButton("magnet", help: tr(tl.mainTrackMagnet ? "toolbar.magnet.off" : "toolbar.magnet.on"), active: tl.mainTrackMagnet) {
                store.setOption(.magnet(!tl.mainTrackMagnet))
            }
            IconButton("arrow.right.and.line.vertical.and.arrow.left", help: tr(tl.snapping ? "toolbar.snapping.off" : "toolbar.snapping.on"), active: tl.snapping) {
                store.setOption(.snapping(!tl.snapping))
            }
            IconButton("link", help: tr(tl.linkage ? "toolbar.linkage.off" : "toolbar.linkage.on"), active: tl.linkage) {
                store.setOption(.linkage(!tl.linkage))
            }
            Divider().frame(height: 16).padding(.horizontal, 4)
            IconButton("arrow.left.and.right.square", help: tr("toolbar.zoomFit")) { store.zoomToFit(width: 1200) }
            IconButton("minus.magnifyingglass", help: tr("toolbar.zoomOut")) { store.zoom(by: 1 / 1.25) }
            Slider(value: Binding(get: { log(store.pixelsPerSecond) }, set: { store.pixelsPerSecond = exp($0) }), in: log(2)...log(1200))
                .controlSize(.mini).frame(width: 90).tint(.white)
            IconButton("plus.magnifyingglass", help: tr("toolbar.zoomIn")) { store.zoom(by: 1.25) }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
    }
}

struct TimelineHost: NSViewRepresentable {
    let store: EditorStore
    func makeNSView(context: Context) -> TimelineView {
        let v = TimelineView(store: store)
        SnapshotRegistry.shared.timeline = v
        return v
    }
    func updateNSView(_ v: TimelineView, context: Context) {}
}
