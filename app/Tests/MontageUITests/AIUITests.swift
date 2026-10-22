import Testing
import Foundation
import AppKit
import SwiftUI
import MontageCore
import MontageEngine
import MontageAI
@testable import MontageUI
import MontageTestSupport

/// W10 AI UI: store flows for captions editing and cutout jobs, inspector tabs, and (MONTAGE_SNAPSHOT_DIR) snapshots.
@MainActor @Suite(.serialized) struct AIUITests {
    static let words: [TranscriptWord] = [
        ("Bonjour", 0.0, 0.4), ("et", 0.45, 0.55), ("bienvenue.", 0.6, 1.1), ("Aujourd'hui", 1.6, 2.0), ("nous", 2.05, 2.2),
        ("allons", 2.25, 2.5), ("couper", 2.55, 2.9), ("une", 2.95, 3.05), ("séquence.", 3.1, 3.6),
    ].map { TranscriptWord(text: $0.0, start: $0.1, end: $0.2) }

    func captionStore() async throws -> (EditorStore, ClipID) {
        var p = TestProject(canvas: Size2(640, 360))
        let v = try await p.addVideo(.movingBox(RGBA(0.5, 0.5, 0.5), RGBA(0.9, 0.1, 0.1)), seconds: 4, size: CGSize(width: 640, height: 360))
        let segs = SpeechCaptions.segments(Transcript(engine: "test", language: "fr", words: Self.words), for: p[v])
        let tid = try #require(CaptionOps.addCaptionTrack(segs, to: &p.project, origin: .auto, replacing: true))
        SpeechCaptions.finish(trackID: tid, in: &p.project)
        let s = EditorStore(project: p.project); s.autosaveEnabled = false
        return (s, v)
    }

    @Test func captionsTabAppearsForCaptionClips() async throws {
        let (s, _) = try await captionStore()
        let first = SpeechCaptions.captions(in: s.project.timeline)[0]
        s.selection = [first.id]
        let tabs = InspectorRegistry.tabs(for: InspectorContext(store: s)).map(\.id)
        #expect(tabs.contains("captions") && tabs.contains("text"))
    }

    @Test func translationsApplyAsOneUndoStep() async throws {
        let (s, _) = try await captionStore()
        let caps = SpeechCaptions.captions(in: s.project.timeline)
        #expect(s.hasAutoCaptions)
        s.applyTranslations([caps[0].id: "Hello and welcome."], display: .both)
        #expect(CaptionOps.text(s.project.timeline.clip(caps[0].id)!)?.caption?.translation == "Hello and welcome.")
        s.undo()
        #expect(CaptionOps.text(s.project.timeline.clip(caps[0].id)!)?.caption?.translation == nil)
        #expect(s.captionLanguage == "fr")
    }

    @Test func cutoutToggleRunsJobAndComposites() async throws {
        // Vision job: inside the heavy-work gate (the store's job is re-entrant through it) and awaited, no poll budget
        try await HeavyWorkGate.run {
            var p = TestProject(canvas: Size2(320, 180))
            _ = try await p.addVideo(.solid(RGBA(0.1, 0.2, 0.9)), seconds: 1)
            let url = try await TestMedia.video(.movingBox(RGBA(0.55, 0.55, 0.55), RGBA(0.9, 0.1, 0.1)), seconds: 1)
            let top = try await p.addMedia(url, at: .zero, target: .newTrack)
            let s = EditorStore(project: p.project); s.autosaveEnabled = false
            let asset = s.project.asset(s.project.timeline.clip(top)!.mediaID!)!
            try? FileManager.default.removeItem(at: MatteStore.shared.matteVideoURL(media: asset, kind: "subject"))
            let job = s.setCutout(top, mode: .subject)
            #expect(job != nil)
            #expect(s.project.timeline.clip(top)?.matte?.kind == "subject")
            await job?.value
            #expect(MatteGenerator.isReady(asset, .subject))
            s.undo()
            #expect(s.project.timeline.clip(top)?.matte == nil)
            s.redo()
            #expect(s.project.timeline.clip(top)?.matte?.kind == "subject")
        }
    }

    @Test func brushToolMapsCanvasToSource() async throws {
        var p = TestProject(canvas: Size2(640, 360))
        let v = try await p.addVideo(.solid(.red), seconds: 1, size: CGSize(width: 640, height: 360))
        p[v].transform.flipH = true
        let s = EditorStore(project: p.project); s.autosaveEnabled = false
        let tool = CutoutBrushTool(clipID: v, store: s)
        let q = try #require(tool.toSource(Vec2(160, 90)))   // top-left quarter of the canvas, flipped → top-right of the source
        #expect(abs(q.x - 0.75) < 0.01 && abs(q.y - 0.25) < 0.01)
        tool.mouseDown(at: Vec2(160, 90)); tool.mouseUp(at: Vec2(160, 90))
        #expect(tool.strokes.count == 1)
    }

    func waitIdle(_ s: EditorStore, _ until: () -> Bool) async throws {
        for _ in 0..<1200 where !until() { try await Task.sleep(nanoseconds: 50_000_000) }   // ≥ 60 s hang bound (load)
    }

    @Test func splitScenesAndAutoReframeFlows() async throws {
        try await HeavyWorkGate.run {
            var src = TestProject()
            _ = try await src.addVideo(.solid(RGBA(0.9, 0.1, 0.1)), seconds: 1, at: 0)
            _ = try await src.addVideo(.solid(RGBA(0.1, 0.8, 0.2)), seconds: 1, at: 10)
            let file = try await src.export().url
            var p = TestProject(canvas: Size2(640, 360))
            let id = try await p.addMedia(file)
            let s = EditorStore(project: p.project); s.autosaveEnabled = false
            s.splitScenes(id)
            try await waitIdle(s) { s.project.timeline.mainTrack!.clips.count == 2 }
            #expect(s.project.timeline.mainTrack!.clips.count == 2)
            s.undo()
            #expect(s.project.timeline.mainTrack!.clips.count == 1)

            s.autoReframe(id, options: ReframeOptions(ratio: "9:16"))
            try await waitIdle(s) { s.project.timeline.clip(id)?.reframe != nil }
            #expect(s.project.timeline.clip(id)?.reframe?.ratio == "9:16")
            #expect(s.project.settings.canvasSize.width < s.project.settings.canvasSize.height)
            s.removeReframe(id)
            #expect(s.project.timeline.clip(id)?.reframe == nil && s.project.timeline.clip(id)?.transform.scale == .one)
        }
    }

    // MARK: Snapshots (opt-in)

    @Test func renderAISnapshots() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MONTAGE_SNAPSHOT_DIR"] else { return }
        let lang = ProcessInfo.processInfo.environment["MONTAGE_SNAPSHOT_LANG"] ?? "en"
        L10n.shared.setLanguagePreference(lang)
        defer { L10n.shared.setLanguagePreference("system") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let (s, v) = try await captionStore()
        let d = URL(fileURLWithPath: dir)
        try ProjectPackage.save(s.project, to: d.appendingPathComponent("ai-demo.montage"))   // for scripts/screenshot.sh --open
        try snapshot(AutoCaptionsPanel(store: s), to: d.appendingPathComponent("ai-autocaptions-\(lang).png"), size: CGSize(width: 520, height: 560))
        let caps = SpeechCaptions.captions(in: s.project.timeline)
        s.applyTranslations([caps[0].id: "Hello and welcome."], display: .both)
        s.selection = [caps[0].id]; s.inspectorTab = "captions"
        try snapshot(InspectorPanel(store: s), to: d.appendingPathComponent("ai-captions-inspector-\(lang).png"))
        s.inspectorTab = "tts"
        try snapshot(InspectorPanel(store: s), to: d.appendingPathComponent("ai-tts-\(lang).png"))
        s.selection = [v]; s.inspectorTab = "video"; InspectorUIState.shared.subTab["video"] = "cutout"
        s.perform(UpdateClip(v) { $0.matte = ClipMatte(kind: "person", feather: 0.2) })
        try snapshot(InspectorPanel(store: s), to: d.appendingPathComponent("ai-cutout-\(lang).png"))
        s.beginCutoutBrush(v)
        try snapshot(InspectorPanel(store: s), to: d.appendingPathComponent("ai-cutout-brush-\(lang).png"))
        s.endCutoutBrush()
        try snapshot(ModelManagerSheet {}, to: d.appendingPathComponent("ai-models-\(lang).png"), size: CGSize(width: 460, height: 420))
    }

    func snapshot<V: View>(_ view: V, to url: URL, size: CGSize = CGSize(width: 523, height: 980)) throws {
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
