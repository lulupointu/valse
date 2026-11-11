import Testing
import Foundation
import ValseCore
import ValseEffects
@testable import ValseUI

/// BUG-PANEL-SELECT: a blank-space click in an asset-panel tab clears only that tab's panel selection (and the preview
/// it drives), never the timeline selection.
@MainActor @Suite(.serialized) struct PanelSelectionTests {
    @Test func deselectClearsOnlyThatTabAndItsSubsections() {
        let st = AssetPanelState()
        st.cursor = ["media": "m1", "media.folder": "f", "media.subprojects": "sub.x", "effects": "e", "mediaX": "keep"]
        st.mediaSelection = [MediaID(), MediaID()]
        #expect(st.deselect("media", store: nil))
        #expect(st.cursor == ["effects": "e", "mediaX": "keep"])
        #expect(st.mediaSelection.isEmpty)
        #expect(!st.deselect("media", store: nil))          // nothing left: a second blank click is a no-op
        st.mediaSelection = [MediaID()]
        #expect(st.deselect("effects", store: nil))
        #expect(st.cursor == ["mediaX": "keep"] && st.mediaSelection.count == 1)   // the Media bin keeps its selection
    }

    @Test func deselectEndsTheCanvasPreviewButKeepsTheTimelineSelection() throws {
        let s = EditorStore()
        s.autosaveEnabled = false
        s.load(project: Project())
        let picked = ClipID()
        s.selection = [picked]
        let st = AssetPanelState()
        let fx = try #require(Registries.effects(in: .effect).first)
        st.cursor["effects"] = fx.id
        s.previewEffect(fx)
        #expect(s.isPreviewing)
        #expect(st.deselect("effects", store: s))
        #expect(!s.isPreviewing && st.cursor["effects"] == nil)
        #expect(s.selection == [picked])
        // nothing selected in the tab: a blank click leaves a running preview alone
        s.previewEffect(fx)
        #expect(!st.deselect("stickers", store: s) && s.isPreviewing)
        s.exitPreview()
    }
}
