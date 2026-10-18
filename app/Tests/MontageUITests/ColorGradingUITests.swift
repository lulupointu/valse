import Testing
import Foundation
import AppKit
import SwiftUI
import MontageCore
import MontageEffects
import MontageEngine
@testable import MontageUI
import MontageTestSupport

/// Adjust ▸ HSL · Curves · Color wheel sub-tabs and ☐ Auto adjust: wiring, store edits (one undo step each), and
/// MONTAGE_SNAPSHOT_DIR offscreen PNGs.
@MainActor @Suite(.serialized) struct ColorGradingUITests {
    init() { MontageBootstrap.registerResources() }

    func store() async throws -> (EditorStore, ClipID) {
        var p = TestProject()
        let v = try await p.addVideo(.movingBox(RGBA(hex: 0x1C5D8A), RGBA(hex: 0xF5F1E3)), seconds: 4)
        let s = EditorStore(project: p.project); s.autosaveEnabled = false
        s.selection = [v]
        return (s, v)
    }

    @Test func adjustTabHasColourSubTabs() async throws {
        let (s, _) = try await store()
        let ctx = InspectorContext(store: s)
        let tab = InspectorRegistry.allTabs.first { $0.id == "adjust" }!
        #expect(InspectorRegistry.subTabs(of: tab, ctx: ctx).map(\.id) == ["basic", "hsl", "curves", "wheels"])
        #expect(InspectorRegistry.sections(tab: tab, subTab: "basic", ctx: ctx).map(\.id).contains("adjust.auto"))
    }

    @Test func editsCreateOneInstanceAndUndoInOneStep() async throws {
        let (s, v) = try await store()
        let ctx = InspectorContext(store: s)
        ColorGradingInspector.edit(ctx, BuiltinColor.hsl) { $0.params["red.sat"] = .scalar(-0.5) }
        ColorGradingInspector.edit(ctx, BuiltinColor.hsl) { $0.params["blue.hue"] = .scalar(0.3) }
        let hsl = s.project.timeline.clip(v)!.effects.filter { $0.typeID == BuiltinColor.hsl.id }
        #expect(hsl.count == 1 && hsl[0].params["red.sat"]?.scalar == -0.5 && hsl[0].params["blue.hue"]?.scalar == 0.3)
        // curve point drag = one gesture = one undo step
        s.beginGesture("cmd.adjust")
        for y in stride(from: 0.5, through: 0.8, by: 0.1) {
            let pts: [ColorCurveMath.Point] = [(0, 0), (0.5, y), (1, 1)]
            let values = ColorCurveMath.params(pts, channel: "luma")
            ColorGradingInspector.edit(ctx, BuiltinColor.curves) { inst in for (k, val) in values { inst.params[k] = val } }
        }
        s.endGesture()
        let curves = s.project.timeline.clip(v)!.effects.first { $0.typeID == BuiltinColor.curves.id }!
        let pts = ColorCurveMath.points(curves.params, channel: "luma")
        #expect(pts.count == 3 && abs(pts[1].y - 0.8) < 1e-9)
        s.undo()
        #expect(s.project.timeline.clip(v)!.effects.contains { $0.typeID == BuiltinColor.curves.id } == false)
        #expect(s.project.timeline.clip(v)!.effects.contains { $0.typeID == BuiltinColor.hsl.id })
        // HSL/Curves/Wheels are not duplicated as generic "other adjustment" blocks
        #expect(!OtherAdjustmentBlocks.listed(hsl[0]))
    }

    @Test func autoAdjustAnalysesTheFrameUnderThePlayhead() async throws {
        let (s, v) = try await store()
        let ctx = InspectorContext(store: s)
        s.transport.playhead = Time(1)
        AutoAdjustSection.run(ctx, s.project.timeline.clip(v)!)
        for _ in 0..<100 where !(s.project.timeline.clip(v)!.effects.contains { $0.typeID == AutoColor.descriptor.id }) {
            try await Task.sleep(for: .milliseconds(30))
        }
        let inst = try #require(s.project.timeline.clip(v)!.effects.first { $0.typeID == AutoColor.descriptor.id })
        #expect(inst.isEnabled && inst.params["exposure"]?.scalar != nil)
        #expect(AutoAdjustSection.chrome(ctx).isEnabled?.wrappedValue == true)
    }

    @Test func renderSnapshots() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MONTAGE_SNAPSHOT_DIR"] else { return }
        let lang = ProcessInfo.processInfo.environment["MONTAGE_SNAPSHOT_LANG"] ?? "en"
        L10n.shared.setLanguageForSession(lang)
        defer { L10n.shared.setLanguageForSession("en") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let (s, _) = try await store()
        let ctx = InspectorContext(store: s)
        ColorGradingInspector.edit(ctx, BuiltinColor.hsl) { $0.params["red.sat"] = .scalar(-0.4); $0.params["red.hue"] = .scalar(0.2) }
        ColorGradingInspector.edit(ctx, BuiltinColor.curves) { inst in
            for (k, v) in ColorCurveMath.params([(0, 0.05), (0.3, 0.22), (0.7, 0.8), (1, 0.97)], channel: "luma") { inst.params[k] = v }
            for (k, v) in ColorCurveMath.params([(0, 0), (0.5, 0.58), (1, 1)], channel: "red") { inst.params[k] = v }
        }
        ColorGradingInspector.edit(ctx, BuiltinColor.colorWheels) {
            $0.params["lift.hue"] = .scalar(210); $0.params["lift.amount"] = .scalar(0.5)
            $0.params["gain.hue"] = .scalar(35); $0.params["gain.amount"] = .scalar(0.4); $0.params["gain.luma"] = .scalar(0.3)
        }
        s.inspectorTab = "adjust"
        for sub in ["basic", "hsl", "curves", "wheels"] {
            InspectorUIState.shared.subTab["adjust"] = sub
            try snapshot(InspectorPanel(store: s), to: URL(fileURLWithPath: dir).appendingPathComponent("inspector-adjust-\(sub)-\(lang).png"))
        }
    }

    func snapshot<V: View>(_ view: V, to url: URL, size: CGSize = CGSize(width: 523, height: 1100)) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).preferredColorScheme(.dark))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
