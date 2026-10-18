import Testing
import Foundation
import SwiftUI
import AppKit
import MontageCore
import MontageEngine
@testable import MontageUI
import MontageTestSupport

/// Render-feature inspector sections (W6): store wiring + an offscreen PNG of the sections for visual review
/// (build/screenshots/w6-sections.png).
@MainActor @Suite(.serialized) struct RenderFeatureInspectorTests {
    @Test func sectionsApplyAndEditTheClip() async throws {
        var p = TestProject(canvas: Size2(320, 180))
        let id = try await p.addVideo(.solid(.green), seconds: 2)
        try TimelineOps.setSpeed(id, .constant(0.5), in: &p.project.timeline)
        let s = EditorStore(project: p.project)
        s.autosaveEnabled = false
        s.selection = [id]
        let ctx = InspectorContext(store: s)
        let ids = InspectorRegistry.sections(tab: "video", ctx: ctx).map(\.id)
        #expect(ids.contains("video.chroma") && ids.contains("video.stabilize") && ids.contains("video.motionBlur"))
        #expect(InspectorRegistry.sections(tab: "speed", ctx: ctx).map(\.id).contains("speed.smoothSlowMo"))

        Bind.apply(s, id, "cmd.chroma") { $0.chromaKey = ChromaKey() }
        Bind.apply(s, id, "cmd.motionBlur") { $0.motionBlur = MotionBlur() }
        Bind.apply(s, id, "cmd.slowmo") { $0.smoothSlowMo = .frameBlending }
        #expect(s.project.timeline.clip(id)?.chromaKey != nil)
        // chroma strength is keyframeable
        var c = s.project.timeline.clip(id)!
        c.setBaseValue(.chromaIntensity, .scalar(0.6))
        #expect(c.chromaKey?.intensity == 0.6)
        s.undo()
        #expect(s.project.timeline.clip(id)?.smoothSlowMo == nil)

        Bind.apply(s, id, "cmd.stabilize") { $0.stabilization = Stabilization() }
        let view = VStack(alignment: .leading, spacing: 18) {
            ChromaKeySection(ctx: ctx); StabilizeSection(ctx: ctx); MotionBlurSection(ctx: ctx); SmoothSlowMoSection(ctx: ctx)
        }
        .padding(16).frame(width: 340).background(Theme.panel)
        let r = ImageRenderer(content: view)
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            let dir = TestMedia.repoRoot().appendingPathComponent("build/screenshots")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: dir.appendingPathComponent("w6-sections.png"))
        }
    }
}
