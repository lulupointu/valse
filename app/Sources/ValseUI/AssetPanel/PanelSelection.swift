import SwiftUI
import ValseCore
import Perception

// BUG-PANEL-SELECT: one selection model for every asset-panel tab. A click on a card (picture or name) selects it;
// a click on blank panel space (gaps between cards, below the last card, section captions) clears the tab's panel
// selection, ends the canvas preview it was driving and stops a library audio preview. The timeline selection and the
// inspector are never touched.

extension AssetPanelState {
    /// Clears the panel selection of `tab` (cursor, media multi-selection, sub-section cursors `"<tab>.<x>"`).
    /// Returns true when something was selected or playing.
    @discardableResult
    func deselect(_ tab: String, store: EditorStore?) -> Bool {
        let keys = cursor.keys.filter { $0 == tab || $0.hasPrefix(tab + ".") }
        var had = !keys.isEmpty
        for k in keys { cursor[k] = nil }
        if tab == "media", !mediaSelection.isEmpty { mediaSelection = []; had = true }
        if LibraryAudioPreview.shared.playingID != nil { LibraryAudioPreview.shared.stop(); had = true }
        if had, let s = store ?? AssetPanelFocus.store, s.isPreviewing { s.exitPreview() }
        return had
    }
}

/// Vertical scroll area of an asset-panel tab: its content fills at least the visible height, and a click on blank
/// space in it (not on a card) deselects `tab` (`AssetPanelState.deselect`). Cards' own gestures and buttons win.
struct PanelScrollView<Content: View>: View {
    let tab: String
    var store: EditorStore? = nil
    @ViewBuilder let content: () -> Content
    @State private var viewport: CGFloat = 0

    var body: some View {
        WithPerceptionTracking {
            ScrollView {
                content()
                    .frame(maxWidth: .infinity, minHeight: viewport, alignment: .top)
                    .deselectsPanel(tab, store: store)
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { viewport = $0 }
        }
    }
}

extension View {
    /// Blank-space click on this view (and its non-interactive children) deselects the panel `tab`.
    func deselectsPanel(_ tab: String, store: EditorStore? = nil) -> some View {
        contentShape(Rectangle())
            .onTapGesture { AssetPanelState.shared.deselect(tab, store: store) }
    }
}
