import Testing
import Foundation
import AppKit
import SwiftUI
import MontageCore
import MontageEffects
import MontageEngine
@testable import MontageUI
import MontageTestSupport

/// Text engine UI (W7): inspector tabs, store commands behind every text control, caption editing flows, import/export,
/// and (with MONTAGE_SNAPSHOT_DIR) offscreen PNGs of the text inspector and the Text asset tab.
@MainActor @Suite(.serialized) struct TextUITests {
    func store(_ build: (inout Project) -> Void = { _ in }) -> EditorStore {
        var p = Project(name: "t", settings: ProjectSettings(canvasSize: Size2(640, 360), frameRate: .fps30, backgroundColor: .black))
        build(&p)
        let s = EditorStore(project: p)
        s.autosaveEnabled = false
        return s
    }

    func captionStore() -> (EditorStore, [ClipID]) {
        let s = store { p in
            CaptionOps.addCaptionTrack([CaptionSegment(text: "Hello big world", start: 0, end: 2, words: [("Hello", 0, 0.5), ("big", 0.6, 1), ("world", 1.2, 2)]),
                                        CaptionSegment(text: "Second line", start: 2.5, end: 4)], to: &p)
        }
        let ids = s.project.timeline.tracks[CaptionOps.captionTracks(s.project.timeline)[0]].clips.map(\.id)
        return (s, ids)
    }

    func tabs(_ s: EditorStore) -> [String] { InspectorRegistry.tabs(for: InspectorContext(store: s)).map(\.id) }

    @Test func textAndCaptionTabs() {
        let s = store()
        s.addDefaultText()
        #expect(tabs(s) == ["text", "animation", "tts", "tracking"])   // + W10 Text to speech, Tracking
        let ctx = InspectorContext(store: s)
        let textTab = InspectorRegistry.allTabs.first { $0.id == "text" }!
        #expect(InspectorRegistry.subTabs(of: textTab, ctx: ctx).map(\.id) == ["basic", "templates", "bubble"])   // OB-10: Effects → Templates, Bubble rightmost
        let basic = InspectorRegistry.sections(tab: textTab, subTab: "basic", ctx: ctx).map(\.id)
        #expect(basic == ["text.content", "text.counter", "text.transform", "text.opacity", "text.stroke", "text.background", "text.glow", "text.shadow", "text.curve"])
        let (c, ids) = captionStore()
        c.selection = [ids[0]]
        #expect(tabs(c) == ["captions", "text", "animation", "tts"])   // C4: Captions first, like CapCut
        // C4 / OB-10: captions get Text ▸ Basic | Templates (caption templates first) | Spoken word | Bubble, and the
        // "Apply to all main captions" row
        let cctx = InspectorContext(store: c)
        #expect(InspectorRegistry.subTabs(of: textTab, ctx: cctx).map(\.id) == ["basic", "templates", "spokenWord", "bubble"])
        #expect(InspectorRegistry.sections(tab: textTab, subTab: "templates", ctx: cctx).map(\.id) == ["text.templates"])
        #expect(InspectorRegistry.sections(tab: textTab, subTab: "spokenWord", ctx: cctx).map(\.id) == ["captions.spokenWord"])
        #expect(InspectorRegistry.sections(tab: textTab, subTab: "basic", ctx: cctx).first?.id == "text.applyAllCaptions")
    }

    @Test func addTextAndStyles() throws {
        let s = store()
        s.addDefaultText()
        let id = try #require(s.singleSelectedClip?.id)
        #expect(s.selectedTextClip?.text.string == tr("text.default") && s.inspectorTab == "text")
        let neon = Registries.textStyles.all.first { $0.groupKey == "textStyle.group.neon" }!
        s.applyTextStyle(neon)
        #expect(s.selectedTextClip?.text.glow != nil && s.selectedTextClip?.text.styleID == neon.id)
        #expect(s.selectedTextClip?.text.string == tr("text.default"))
        s.undo()
        #expect(s.selectedTextClip?.text.glow == nil)
        // rich range styling goes to the selected range only
        TextUIState.shared.selection[id] = TextSpan(0, 3)
        s.applyTextRunStyle(id, TextRunStyle(color: .red))
        #expect(s.selectedTextClip?.text.runs.first?.range == TextSpan(0, 3))
        TextUIState.shared.selection[id] = nil
        s.applyTextRunStyle(id, TextRunStyle(bold: false))
        #expect(s.selectedTextClip?.text.bold == false)
        // bubble
        s.applyBubble(Registries.textBubbles["montage.bubble.speechYellow"])
        #expect(s.selectedTextClip?.text.bubbleID == "montage.bubble.speechYellow")
        s.applyBubble(nil)
        #expect(s.selectedTextClip?.text.bubbleID == nil)
    }

    @Test func templatesAddAndSwitchKeepingText() throws {
        let s = store()
        let d = Registries.textTemplates["montage.template.titleSubtitle"]!
        s.addTextTemplate(d)
        let id = try #require(s.singleSelectedClip?.id)
        #expect(s.singleSelectedClip?.duration == d.defaultDuration)
        s.updateText(id) { $0.string = "Mine"; $0.template?.texts = ["Sub"] }
        s.changeTemplate(id, to: Registries.textTemplates["montage.template.lowerThird"]!)
        let t = try #require(s.selectedTextClip?.text)
        #expect(t.template?.templateID == "montage.template.lowerThird" && t.string == "Mine" && t.template?.texts.first == "Sub")
        // drop payloads
        s.addTextPayload("template:montage.template.subscribe")
        #expect(s.selectedTextClip?.text.template?.templateID == "montage.template.subscribe")
        s.addTextPayload("montage.text.yellow")
        #expect(s.selectedTextClip?.text.styleID == "montage.text.yellow")
    }

    @Test func savedPresetsRoundTrip() {
        let s = store()
        s.addDefaultText()
        s.applyTextStyle(Registries.textStyles["montage.text.retro"]!)
        let before = TextPresetStore.shared.presets.count
        s.saveTextPreset()
        #expect(TextPresetStore.shared.presets.count == before + 1)
        let p = TextPresetStore.shared.presets[0]
        s.selection = []
        s.applySavedPreset(p)
        #expect(s.selectedTextClip?.text.shadow.extrude == true)
        TextPresetStore.shared.remove(p.id)
    }

    @Test func captionEditingFlows() throws {
        let (s, ids) = captionStore()
        s.selection = [ids[0]]
        s.splitCaption(ids[0], at: 9)
        let ti = try #require(s.activeCaptionTrackIndex)
        #expect(s.project.timeline.tracks[ti].clips.count == 3)
        s.mergeCaptionWithNext(ids[0])
        #expect(s.project.timeline.tracks[ti].clips.count == 2)
        #expect(CaptionOps.text(s.project.timeline.clip(ids[0])!)?.string == "Hello big world")
        s.setCaptionText(ids[1], "Second sentence")
        #expect(CaptionOps.text(s.project.timeline.clip(ids[1])!)?.string == "Second sentence")
        s.nudgeCaption(ids[1], start: Time(-0.1))
        #expect(s.project.timeline.clip(ids[1])!.start == Time(2.4))
        s.replaceAllInCaptions("second", with: "Last", caseSensitive: false)
        #expect(CaptionOps.text(s.project.timeline.clip(ids[1])!)?.string == "Last sentence")
        // template + apply to all
        s.applyCaptionTemplate(Registries.captionTemplates["montage.captionTemplate.boxPurple"]!)
        #expect(s.project.timeline.tracks[ti].clips.allSatisfy { CaptionOps.text($0)?.karaoke?.boxColor != nil })
        s.updateText(ids[0]) { $0.color = .red }
        s.selection = [ids[0]]
        s.applyCaptionLookToAll()
        #expect(CaptionOps.text(s.project.timeline.clip(ids[1])!)?.color == .red)
        s.highlightCaptionKeywords()
        s.wrapCaptions(maxChars: 8, maxLines: 1)
        #expect(s.project.timeline.tracks[ti].clips.count > 2)
        #expect(TimelineOps.validate(s.project.timeline).isEmpty)
    }

    @Test func importAndExportCaptionFiles() throws {
        let s = store()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("montage-captions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let srt = dir.appendingPathComponent("in.srt")
        try "1\n00:00:01,000 --> 00:00:02,000\nBonjour\n\n2\n00:00:02,500 --> 00:00:04,000\nle monde\n".write(to: srt, atomically: true, encoding: .utf8)
        s.importCaptions(from: srt)
        let ti = try #require(s.activeCaptionTrackIndex)
        #expect(s.project.timeline.tracks[ti].clips.count == 2)
        #expect(CaptionOps.text(s.project.timeline.tracks[ti].clips[0])?.caption?.origin == .imported)
        for f in CaptionFormat.allCases {
            let out = dir.appendingPathComponent("out.\(f.fileExtension)")
            s.exportCaptions(format: f, to: out)
            let text = try String(contentsOf: out, encoding: .utf8)
            #expect(text.contains("Bonjour"), "\(f)")
            if f != .txt { #expect(try CaptionFiles.parse(text, format: f).count == 2, "\(f)") }
        }
        // too large
        let big = dir.appendingPathComponent("big.srt")
        try Data(count: CaptionFiles.maxImportBytes + 1).write(to: big)
        s.importCaptions(from: big)
        #expect(CaptionOps.captionTracks(s.project.timeline).count == 1)
        // script → captions
        s.addScriptCaptions("One. Two three.", split: true)
        #expect(CaptionOps.captionTracks(s.project.timeline).count == 2)
    }

    @Test func inlineEditingState() throws {
        let s = store()
        s.addDefaultText()
        let id = try #require(s.singleSelectedClip?.id)
        s.selection = []
        s.beginInlineTextEdit(id)
        #expect(s.playerUI.editingTextClip == id && s.selection == [id])
        s.endInlineTextEdit()
        #expect(s.playerUI.editingTextClip == nil)
    }

    @Test func renderSnapshots() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MONTAGE_SNAPSHOT_DIR"] else { return }
        let lang = ProcessInfo.processInfo.environment["MONTAGE_SNAPSHOT_LANG"] ?? "en"
        L10n.shared.setLanguagePreference(lang)
        defer { L10n.shared.setLanguagePreference("system") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let s = store()
        s.addDefaultText()
        let id = try #require(s.singleSelectedClip?.id)
        s.updateText(id) { $0.strokeWidth = 0.08; $0.shadowColor = RGBA(0, 0, 0, 0.8) }
        let ui = InspectorUIState.shared
        for sub in ["basic", "bubble", "templates"] {
            s.inspectorTab = "text"; ui.subTab["text"] = sub
            try snapshot(InspectorPanel(store: s), "inspector-text-\(sub)-\(lang).png", dir)
        }
        // scroll-free view of the optional sections
        ui.expanded["text.stroke"] = true
        try snapshot(ScrollView { VStack(spacing: 0) {
            ForEach(InspectorRegistry.sections.filter { ["text.stroke", "text.background", "text.glow", "text.shadow", "text.curve"].contains($0.id) }) {
                InspectorSectionView(section: $0, ctx: InspectorContext(store: s), ui: ui)
            }
        } }.background(Theme.panel), "inspector-text-sections-\(lang).png", dir)
        let (c, ids) = captionStore()
        c.selection = [ids[0]]; c.inspectorTab = "captions"
        try snapshot(InspectorPanel(store: c), "inspector-captions-\(lang).png", dir)
        for nav in ["add", "effects", "templates", "local"] {
            try snapshot(TextAssetTabPreview(store: s, nav: nav), "assets-text-\(nav)-\(lang).png", dir, size: CGSize(width: 560, height: 620))
        }
        try snapshot(FontPickerList(selected: "") { _ in }, "font-picker-\(lang).png", dir, size: CGSize(width: 280, height: 420))
    }

    func snapshot<V: View>(_ view: V, _ name: String, _ dir: String, size: CGSize = CGSize(width: 523, height: 980)) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).preferredColorScheme(.dark))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // let the async tile previews render
        for _ in 0..<12 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }
}

/// The Text asset tab opened on a given sub-nav item (snapshots).
struct TextAssetTabPreview: View {
    let store: EditorStore
    let nav: String
    var body: some View { TextAssetTab(store: store, initialNav: nav).background(Theme.panel) }
}
