import Testing
import Foundation
import CoreGraphics
import MontageCore
import MontageEffects
import MontageEngine
import MontageAI
@testable import MontageUI
import MontageTestSupport

@MainActor @Suite(.serialized) struct StoreTests {
    func store() async throws -> (EditorStore, [ClipID]) {
        var p = TestProject(canvas: Size2(320, 180))
        let a = try await p.addVideo(.solid(.red), seconds: 2)
        let b = try await p.addVideo(.solid(.blue), seconds: 2, at: 10)
        let s = EditorStore(project: p.project)
        s.autosaveEnabled = false
        return (s, [a, b])
    }

    @Test func splitUndoRedoThroughStore() async throws {
        let (s, ids) = try await store()
        s.selection = [ids[0]]
        s.transport.playhead = Time(1)
        s.splitAtPlayhead()
        #expect(s.project.timeline.mainTrack!.clips.count == 3)
        s.undo()
        #expect(s.project.timeline.mainTrack!.clips.count == 2)
        s.redo()
        #expect(s.project.timeline.mainTrack!.clips.count == 3)
    }

    @Test func deleteRipplesAndClearsSelection() async throws {
        let (s, ids) = try await store()
        s.selection = [ids[0]]
        s.deleteSelection()
        #expect(s.selection.isEmpty)
        #expect(s.project.timeline.mainTrack!.clips.first?.start == .zero)
    }

    @Test func sliderGestureIsOneUndoStep() async throws {
        let (s, ids) = try await store()
        s.selection = [ids[0]]
        s.beginGesture("cmd.opacity")
        for v in [0.9, 0.5, 0.2] { s.updateSelectedClips { $0.opacity = v } }
        s.endGesture()
        #expect(s.project.timeline.clip(ids[0])!.opacity == 0.2)
        s.undo()
        #expect(s.project.timeline.clip(ids[0])!.opacity == 1)
    }

    @Test func applyFilterToSelectionAndAdjustmentClipOtherwise() async throws {
        let (s, ids) = try await store()
        let mono = Registries.effects["montage.filter.mono"]!
        s.selection = [ids[0]]
        s.applyEffect(mono)
        #expect(s.project.timeline.clip(ids[0])!.effects.map(\.typeID) == [mono.id])
        s.selection = []
        s.applyEffect(mono)
        #expect(s.project.timeline.allClips.contains { if case .adjustment = $0.content { return true }; return false })
    }

    @Test func saveAndReopen() async throws {
        let (s, ids) = try await store()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ui-\(UUID()).montage")
        s.saveAs(url)
        #expect(!s.session.isDirty)
        let s2 = EditorStore()
        try s2.open(url)
        #expect(s2.project.timeline.clip(ids[1]) != nil)
        s.close(); s2.close()
    }

    @Test func inspectorTabsFollowSelection() async throws {
        let (s, ids) = try await store()
        #expect(InspectorRegistry.tabs(for: InspectorContext(store: s)).map(\.id) == ["details"])
        s.selection = [ids[0]]
        let tabs = InspectorRegistry.tabs(for: InspectorContext(store: s)).map(\.id)
        #expect(tabs.prefix(2) == ["video", "speed"] || tabs.contains("video"))
        #expect(tabs.contains("adjust") && tabs.contains("animation"))
    }
}

@MainActor @Suite struct TimelineLayoutTests {
    @Test func rowsOrderAndHitTesting() throws {
        var p = Project()
        let a = MediaAsset(name: "v", kind: .video, url: URL(fileURLWithPath: "/tmp/v.mp4"), duration: 10, pixelSize: .hd1080,
                           frameRate: .fps30, hasVideo: true, hasAudio: true, contentHash: "h")
        p.media = [a]
        let main = TimelineOps.makeClip(for: a)
        try TimelineOps.insert(main, into: &p)
        try TimelineOps.insert(Clip(content: .text(TextContent(string: "t")), start: 1, duration: 2), into: &p)
        let l = TimelineLayout(timeline: p.timeline, pixelsPerSecond: 50, scrollTime: 0, scrollY: 0, viewSize: CGSize(width: 1000, height: 400))
        #expect(l.rows.map(\.kind) == [.text, .video])
        #expect(l.rows[1].isMain)
        let mainRow = l.rows[1]
        let mid = CGPoint(x: l.x(Time(5)), y: mainRow.y + 10)
        #expect(l.hitTest(mid, timeline: p.timeline) == .clip(main.id, region: .body, row: 1))
        let edge = CGPoint(x: l.x(Time(10)) - 2, y: mainRow.y + 10)
        #expect(l.hitTest(edge, timeline: p.timeline) == .clip(main.id, region: .trailingEdge, row: 1))
        #expect(l.hitTest(CGPoint(x: 300, y: 5), timeline: p.timeline) == .ruler)
        #expect(abs(l.time(atX: l.x(Time(3.5))).seconds - 3.5) < 1e-6)
        let snap = l.snap(Time(9.9), timeline: p.timeline, playhead: .zero)
        #expect(snap.snapped && snap.0 == Time(10))
    }
}

@MainActor @Suite struct LocalizationCoverageTests {
    /// Dynamic keys (registries, enums) can't be checked by scripts/l10n_check.py: verify them here in both languages.
    @Test func everyRegistryAndEnumKeyIsTranslated() {
        MontageBootstrap.registerResources()
        var keys: [String] = []
        keys += Registries.effects.all.filter { $0.id.hasPrefix("montage.") }.flatMap { [$0.nameKey, $0.groupKey] + $0.params.map(\.nameKey) }
        keys += Registries.transitions.all.flatMap { [$0.nameKey, $0.groupKey] + $0.params.map(\.nameKey) }
        keys += Registries.animations.all.map(\.nameKey)
        keys += Registries.stickers.all.flatMap { [$0.nameKey, $0.groupKey] }
        keys += Registries.textStyles.all.map(\.nameKey)
        keys += AIRegistry.tools.all.flatMap { [$0.nameKey, $0.descriptionKey] }
        keys += AssetTabRegistry.tabs.map(\.titleKey)
        keys += InspectorRegistry.allTabs.map(\.titleKey)
        keys += InspectorRegistry.sections.compactMap(\.titleKey)
        keys += ShortcutRegistry.all.map(\.titleKey)
        keys += BlendMode.allCases.map(\.nameKey) + MaskShape.allCases.map(\.nameKey)
        keys += ExportSettings.Codec.allCases.map(\.nameKey) + ExportSettings.BitrateMode.allCases.map(\.nameKey)
        keys += PreviewQuality.allCases.map(\.nameKey)
        keys += AnimatableProperties.all.map(\.nameKey)
        keys += ["system", "en", "fr"].map { "settings.language.\($0)" }
        keys += ProxyManager.Policy.allCases.map { "details.proxy.\($0.rawValue)" }
        let en = L10n.shared.keys(for: "en"), fr = L10n.shared.keys(for: "fr")
        let missing = Set(keys).filter { !en.contains($0) || !fr.contains($0) }.sorted()
        #expect(missing.isEmpty, "missing: \(missing)")
    }

    // Runtime switching is tested once, in MontageCoreTests (the active language is process-global).
    @Test func uiStringsResolveInFrench() {
        MontageBootstrap.registerResources()
        #expect(L10n.load("fr", from: [UIResources.bundle])["tab.media"] == "Médias")
    }
}
