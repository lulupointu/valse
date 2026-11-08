import Testing
import Foundation
import ValseCore
@testable import ValseUI

/// BUG-COMPOUND-SCROLL: the main timeline and each compound clip keep their own horizontal / vertical scroll.
@MainActor @Suite(.serialized) struct CompoundScrollTests {
    func store() throws -> (EditorStore, outer: ClipID, other: ClipID) {
        var (p, ids) = try TimelineUITests().project(clips: 4)
        let inner = try TimelineOps.createCompound([ids[0]], name: "Inner", in: &p)
        let outer = try TimelineOps.createCompound([inner, ids[1]], name: "Outer", in: &p)
        let other = try TimelineOps.createCompound([ids[2]], name: "Other", in: &p)
        let s = EditorStore(project: p)
        s.autosaveEnabled = false
        return (s, outer, other)
    }

    func compoundClip(_ s: EditorStore) -> ClipID? {
        s.project.timeline.allClips.first { if case .compound = $0.content { return true }; return false }?.id
    }

    func scroll(_ s: EditorStore) -> [Double] { [s.timelineUI.scrollTime, s.timelineUI.scrollY] }
    func set(_ s: EditorStore, _ t: Double, _ y: Double) { s.timelineUI.scrollTime = t; s.timelineUI.scrollY = y }

    @Test func eachLevelKeepsItsOwnScroll() throws {
        let (s, outer, other) = try store()
        set(s, 5, 30)
        s.enterCompound(outer)
        #expect(s.project.isInsideCompound)
        #expect(scroll(s) == [0, 0])                     // first entry: 0, 0
        set(s, 2, 10)
        let inner = try #require(compoundClip(s))
        s.enterCompound(inner)                           // nested
        #expect(scroll(s) == [0, 0])
        set(s, 1, 4)
        s.exitCompound(all: true)                        // breadcrumb jump to the main timeline
        #expect(!s.project.isInsideCompound)
        #expect(scroll(s) == [5, 30])
        s.enterCompound(outer)                           // re-enter: where it was left
        #expect(scroll(s) == [2, 10])
        s.enterCompound(try #require(compoundClip(s)))
        #expect(scroll(s) == [1, 4])
        s.exitCompound()
        #expect(scroll(s) == [2, 10])
        set(s, 3, 0)
        s.exitCompound()
        #expect(scroll(s) == [5, 30])
        s.enterCompound(other)                           // another compound starts at 0, 0
        #expect(scroll(s) == [0, 0])
        set(s, 7, 12)
        s.undo()                                         // undo "enter" = back to the main timeline
        #expect(!s.project.isInsideCompound && scroll(s) == [5, 30])
        s.redo()
        #expect(scroll(s) == [7, 12])
        s.exitCompound()
        s.enterCompound(outer)
        #expect(scroll(s) == [3, 0])
    }

    @Test func editsInsideACompoundDontResetScroll() throws {
        let (s, outer, _) = try store()
        s.enterCompound(outer)
        set(s, 4, 8)
        s.selection = Set(s.project.timeline.allClips.prefix(1).map(\.id))
        s.perform(Edit("cmd.editClip") { p in
            let id = p.timeline.allClips[0].id
            p.timeline[clip: id]?.name = "renamed"
        })
        #expect(scroll(s) == [4, 8])
    }
}
