import Testing
import Foundation
import SwiftUI
import AppKit
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

        // Visual review: Video ▸ Basic with Stabilize + Motion blur on, Speed ▸ Normal with Smooth slow-mo on.
        MotionBlurSection.chrome(ctx).isEnabled?.wrappedValue = true
        Bind.apply(s, id, "cmd.slowmo") { $0.smoothSlowMo = .frameBlending }
        let dir = TestMedia.repoRoot().appendingPathComponent("build/screenshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (tab, sub) in [("video", "basic"), ("speed", "normal")] {
            s.inspectorTab = tab
            InspectorUIState.shared.subTab[tab] = sub
            try snapshot(InspectorPanel(store: s), to: dir.appendingPathComponent("w6-inspector-\(tab).png"))
        }
    }

    func snapshot<V: View>(_ view: V, to url: URL, size: CGSize = CGSize(width: 523, height: 2200)) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).preferredColorScheme(.dark))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
