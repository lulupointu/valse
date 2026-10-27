import Testing
import Foundation
import ValseCore
import ValseEffects
import ValseEngine
@testable import ValseUI
import ValseTestSupport

/// Text finisher: Separate text template (TX-032), template language (TX-033), counter section (TX-039).
@MainActor @Suite(.serialized) struct TextFinishUITests {
    init() { ValseBootstrap.registerResources() }

    func textClips(_ s: EditorStore) -> [Clip] { s.project.timeline.tracks.flatMap(\.clips).filter { if case .text = $0.content { return true }; return false } }

    @Test func separateSplitsATemplateIntoOneClipPerLayerInOneUndoStep() throws {
        let s = EditorStore(project: TestProject().project); s.autosaveEnabled = false
        let d = try #require(Registries.textTemplates["valse.template.lowerThird"])
        s.addTextTemplate(d)
        let id = try #require(s.selection.first)
        let ctx = InspectorContext(store: s)
        #expect(InspectorRegistry.sections(tab: "text", ctx: ctx).map(\.id).contains("text.template.tools"))
        let ids = s.separateTextTemplate(id)
        #expect(ids.count == d.layers.count)
        let clips = textClips(s)
        #expect(clips.count == d.layers.count)
        let layers = clips.compactMap { c -> [Int]? in if case .text(let t) = c.content { return t.template?.layers }; return nil }
        #expect(Set(layers.flatMap { $0 }) == Set(d.layers.indices) && layers.allSatisfy { $0.count == 1 })
        #expect(Set(clips.map(\.start)) == [clips[0].start] && Set(clips.map(\.duration)) == [d.defaultDuration])
        #expect(s.session.undoNameKey == "cmd.separateTemplate")
        // a part can't be separated further
        #expect(s.separateTextTemplate(id).isEmpty)
        s.undo()
        #expect(textClips(s).count == 1)
    }

    @Test func templateLanguageRewritesDefaultTextsButKeepsTypedOnes() throws {
        let s = EditorStore(project: TestProject().project); s.autosaveEnabled = false
        let d = try #require(Registries.textTemplates["valse.template.titleSubtitle"])
        s.addTextTemplate(d)
        let id = try #require(s.selection.first)
        s.updateText(id) { $0.string = "Mon titre" }
        s.setTemplateLanguage(id, "fr")
        guard case .text(let t) = s.project.timeline.clip(id)?.content else { Issue.record("no text"); return }
        let fr = L10n.shared.strings(for: "fr")
        #expect(t.string == "Mon titre")
        #expect(t.template?.texts.first == fr[d.slotKeys[1]] && t.template?.language == "fr")
        s.setTemplateLanguage(id, "en")
        guard case .text(let t2) = s.project.timeline.clip(id)?.content else { return }
        #expect(t2.template?.texts.first == L10n.shared.strings(for: "en")[d.slotKeys[1]])
    }

    @Test func counterTemplatesCarryACounterAndTheSectionToggles() throws {
        let s = EditorStore(project: TestProject().project); s.autosaveEnabled = false
        for name in ["countUp", "countdown", "yearCounter", "dateRoll"] {
            let d = try #require(Registries.textTemplates["valse.template.\(name)"])
            #expect(d.makeContent().counter != nil, "\(name)")
        }
        s.addDefaultText()
        let id = try #require(s.selection.first)
        let ctx = InspectorContext(store: s)
        let chrome = TextCounterSection.chrome(ctx)
        chrome.isEnabled?.wrappedValue = true
        guard case .text(let t) = s.project.timeline.clip(id)?.content else { return }
        #expect(t.counter == TextCounter())
        #expect(s.session.undoNameKey == "cmd.text")
        TextCounterSection(ctx: ctx).set { $0 = TextCounter.defaults(.timer) }
        guard case .text(let t2) = s.project.timeline.clip(id)?.content else { return }
        #expect(t2.counter?.kind == .timer && s.session.undoNameKey == "cmd.textCounter")
    }
}
