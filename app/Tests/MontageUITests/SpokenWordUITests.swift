import Testing
import Foundation
import MontageCore
import MontageEffects
@testable import MontageUI

/// OB-10: Text ▸ Templates (caption templates as the first "Caption" category) and Text ▸ Spoken word (manual controls
/// for every word-state effect a caption template applies).
@MainActor @Suite(.serialized) struct SpokenWordUITests {
    func captionStore() -> (EditorStore, [ClipID]) {
        var p = Project(name: "t", settings: ProjectSettings(canvasSize: Size2(640, 360), frameRate: .fps30, backgroundColor: .black))
        CaptionOps.addCaptionTrack([CaptionSegment(text: "Hello big world", start: 0, end: 2, words: [("Hello", 0, 0.5), ("big", 0.6, 1), ("world", 1.2, 2)]),
                                    CaptionSegment(text: "Second line", start: 2.5, end: 4)], to: &p)
        let s = EditorStore(project: p)
        s.autosaveEnabled = false
        let ids = s.project.timeline.tracks[CaptionOps.captionTracks(s.project.timeline)[0]].clips.map(\.id)
        return (s, ids)
    }

    func karaoke(_ s: EditorStore, _ id: ClipID) -> KaraokeStyle? {
        if case .text(let t) = s.project.timeline.clip(id)?.content { return t.karaoke }
        return nil
    }

    /// Every `KaraokeStyle` field (what caption templates set on the spoken word) has a control in the tab.
    @Test func everyTemplateFieldHasAControl() {
        let fields = Set(Mirror(reflecting: KaraokeStyle()).children.compactMap(\.label))
        #expect(fields == CaptionSpokenWordSection.exposedFields)
        // and templates only vary karaoke fields that exist (sanity: some template sets each optional one)
        let looks = Registries.captionTemplates.all.compactMap { d -> KaraokeStyle? in
            var t = CaptionOps.defaultStyle(); d.apply(&t); return t.karaoke
        }
        #expect(looks.contains { $0.highlightStroke != nil } && looks.contains { $0.boxColor != nil } && looks.contains { $0.bounce > 0 })
    }

    /// Picking a template shows its values in Spoken word; setting the same values by hand gives the same look, on every
    /// caption of the track ("Apply to all main captions" on), in one undo step per edit.
    @Test func templateLooksAreReproducibleByHand() throws {
        let (s, ids) = captionStore()
        TextUIState.shared.applyToAllCaptions = true
        s.selection = [ids[0]]
        let ctx = InspectorContext(store: s)
        for d in Registries.captionTemplates.all {
            var look = CaptionOps.defaultStyle(); d.apply(&look)
            guard let want = look.karaoke else { continue }
            // by hand: switch off, then rebuild the template's values field by field
            CaptionSpokenWordSection.chrome(ctx).isEnabled?.wrappedValue = false
            #expect(karaoke(s, ids[0]) == nil && karaoke(s, ids[1]) == nil)
            CaptionSpokenWordSection.set(ctx) { k in
                k.mode = want.mode; k.highlightColor = want.highlightColor; k.highlightStroke = want.highlightStroke
                k.highlightScale = want.highlightScale; k.boxColor = want.boxColor; k.unspokenOpacity = want.unspokenOpacity
                k.bounce = want.bounce
            }
            #expect(karaoke(s, ids[0]) == want, "\(d.id)")
            #expect(karaoke(s, ids[1]) == want, "\(d.id): Apply to all main captions")
            #expect(s.session.undoNameKey == "cmd.spokenWord")
            // by template: the Spoken word tab reads the template's values
            CaptionSpokenWordSection.chrome(ctx).isEnabled?.wrappedValue = false
            s.applyCaptionTemplate(d)
            #expect(karaoke(s, ids[0]) == want, "\(d.id) template")
        }
        // FB-04: the tab's toggle keeps the last style while off and restores it when turned back on
        let last = karaoke(s, ids[0])
        #expect(last != nil && last != KaraokeStyle())
        CaptionSpokenWordSection.chrome(ctx).isEnabled?.wrappedValue = false
        #expect(karaoke(s, ids[0]) == nil && karaoke(s, ids[1]) == nil)
        CaptionSpokenWordSection.chrome(ctx).isEnabled?.wrappedValue = true
        #expect(karaoke(s, ids[0]) == last)
        #expect(karaoke(s, ids[1]) == last, "Apply to all main captions")
    }

    /// FB-04: turning Spoken word off then on restores the previous values, also after saving / reopening the project
    /// and through undo; the first time on gives the defaults.
    @Test func turningSpokenWordOffKeepsItsValues() throws {
        let (s, ids) = captionStore()
        TextUIState.shared.applyToAllCaptions = false
        s.selection = [ids[0]]
        let ctx = InspectorContext(store: s)
        let toggle = { (on: Bool) in CaptionSpokenWordSection.chrome(ctx).isEnabled?.wrappedValue = on }
        toggle(true)
        #expect(karaoke(s, ids[0]) == KaraokeStyle())
        CaptionSpokenWordSection.set(ctx) { $0.mode = .reveal; $0.highlightScale = 1.5; $0.boxColor = RGBA(1, 0, 0) }
        let custom = try #require(karaoke(s, ids[0]))
        toggle(false)
        #expect(karaoke(s, ids[0]) == nil)
        // stored but inactive, and saved with the project
        let text = { () -> TextContent? in if case .text(let t) = s.project.timeline.clip(ids[0])?.content { return t }; return nil }
        #expect(text()?.inactiveKaraoke == custom)
        let saved = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(s.project))
        if case .text(let t) = saved.timeline.clip(ids[0])?.content { #expect(t.inactiveKaraoke == custom && t.karaoke == nil) }
        else { Issue.record("caption missing after round trip") }
        toggle(true)
        #expect(karaoke(s, ids[0]) == custom)
        #expect(text()?.inactiveKaraoke == nil)
        s.undo()
        #expect(karaoke(s, ids[0]) == nil && text()?.inactiveKaraoke == custom)
        // a template applied while off replaces the remembered look
        s.applyCaptionTemplate(Registries.captionTemplates["montage.captionTemplate.boxPurple"]!)
        #expect(text()?.inactiveKaraoke == nil && karaoke(s, ids[0])?.boxColor != nil)
    }
}
