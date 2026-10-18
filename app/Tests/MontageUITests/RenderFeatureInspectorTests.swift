import Testing
import Foundation
import MontageCore
import MontageEngine
@testable import MontageUI
import MontageTestSupport

/// Render-feature inspector sections (W6): registration and model wiring.
@MainActor @Suite(.serialized) struct RenderFeatureInspectorTests {
    @Test func sectionsApplyAndEditTheClip() async throws {
        var p = TestProject(canvas: Size2(320, 180))
        let id = try await p.addVideo(.solid(.green), seconds: 2)
        try TimelineOps.setSpeed(id, .constant(0.5), in: &p.project.timeline)
        let s = EditorStore(project: p.project)
        s.autosaveEnabled = false
        s.selection = [id]
        let ctx = InspectorContext(store: s)
        let ids = InspectorRegistry.sections.filter { $0.tabID == "video" }.map(\.id)
        #expect(ids.contains("video.stabilize") && ids.contains("video.motionBlur"))
        #expect(SmoothSlowMoRow.applies(s.project.timeline.clip(id)))

        StabilizeSection.chrome(ctx).isEnabled?.wrappedValue = true
        #expect(s.project.timeline.clip(id)?.stabilization != nil)
        MotionBlurSection.chrome(ctx).isEnabled?.wrappedValue = true
        #expect(s.project.timeline.clip(id)?.motionBlur != nil)
        s.undo()
        #expect(s.project.timeline.clip(id)?.motionBlur == nil)
        #expect(s.project.timeline.clip(id)?.stabilization != nil)
    }
}
