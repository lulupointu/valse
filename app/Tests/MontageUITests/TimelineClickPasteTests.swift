import Testing
import Foundation
import AppKit
import MontageCore
import MontageEngine
@testable import MontageUI
import MontageTestSupport

/// OB-02 / OB-03 click rules (selection vs playhead) and OB-05 "Paste" on empty track space.
@MainActor @Suite(.serialized) struct TimelineClickPasteTests {
    func pasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: .init("montage.test.ob05.\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    @Test func emptyClickSeeksOnlyWithoutSelection() {
        #expect(TimelineClickPolicy.emptyClickSeeks(hadSelection: false, additive: false))
        #expect(!TimelineClickPolicy.emptyClickSeeks(hadSelection: true, additive: false))
        #expect(TimelineClickPolicy.emptyClickSeeks(hadSelection: true, additive: true))   // ⇧/⌘ unchanged
    }

    @Test func clipClickSeeksOnlyOnTheSoleSelection() {
        let a = ClipID(), b = ClipID(), c = ClipID()
        #expect(!TimelineClickPolicy.clipClickSeeks(selectionBefore: [], clickedGroup: [a], additive: false))
        #expect(!TimelineClickPolicy.clipClickSeeks(selectionBefore: [b], clickedGroup: [a], additive: false))
        #expect(!TimelineClickPolicy.clipClickSeeks(selectionBefore: [a, b], clickedGroup: [a], additive: false))
        #expect(TimelineClickPolicy.clipClickSeeks(selectionBefore: [a], clickedGroup: [a], additive: false))
        #expect(TimelineClickPolicy.clipClickSeeks(selectionBefore: [a, c], clickedGroup: [a, c], additive: false))   // a group = one element
        #expect(!TimelineClickPolicy.clipClickSeeks(selectionBefore: [a], clickedGroup: [a], additive: true))
    }

    @Test func pasteContentReadsThePasteboard() throws {
        let pb = pasteboard()
        #expect(TimelinePasteContent.read(pb, hasInternalItems: false) == nil)
        #expect(TimelinePasteContent.read(pb, hasInternalItems: true) == .items)
        pb.setString("   \n", forType: .string)
        #expect(TimelinePasteContent.read(pb, hasInternalItems: false) == nil)
        pb.clearContents(); pb.setString(" Hello ", forType: .string)
        #expect(TimelinePasteContent.read(pb, hasInternalItems: false) == .text("Hello"))
        pb.clearContents(); pb.writeObjects([URL(fileURLWithPath: "/tmp/notes.pdf") as NSURL])
        #expect(TimelinePasteContent.read(pb, hasInternalItems: false) == nil)   // not media: greyed out
        let mov = URL(fileURLWithPath: "/tmp/clip.mov")
        pb.clearContents(); pb.writeObjects([mov as NSURL, URL(fileURLWithPath: "/tmp/notes.pdf") as NSURL])
        #expect(TimelinePasteContent.read(pb, hasInternalItems: false) == .files([mov]))
        let img = NSImage(size: NSSize(width: 4, height: 4)); img.lockFocus(); NSColor.red.set(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); img.unlockFocus()
        pb.clearContents(); pb.writeObjects([img])
        #expect(TimelinePasteContent.read(pb, hasInternalItems: false) == .image)
        pb.clearContents(); pb.setData(Data("{}".utf8), forType: ClipboardPayload.type)
        #expect(TimelinePasteContent.read(pb, hasInternalItems: false) == .items)
    }

    func store() async throws -> (EditorStore, ClipID) {
        var p = TestProject(canvas: Size2(320, 180))
        let a = try await p.addVideo(.solid(.red), seconds: 2)
        p.project.timeline.mainTrackMagnet = false   // the pasted copy keeps the clicked time on the main track
        let s = EditorStore(project: p.project)
        s.autosaveEnabled = false
        return (s, a)
    }

    @Test func pastedTextBecomesATextClipAtTheClickedTime() async throws {
        let (s, _) = try await store()
        s.transport.playhead = Time(0.5)
        let pb = pasteboard()
        pb.setString("Bonjour", forType: .string)
        s.paste(at: Time(4), from: pb)
        let c = try #require(s.selectedClips.first)
        #expect(c.start == Time(4))
        if case .text(let t) = c.content { #expect(t.string == "Bonjour") } else { Issue.record("not a text clip") }
        #expect(s.transport.playhead == Time(0.5))   // the playhead does not move
        #expect(s.session.undoNameKey == "cmd.text")
    }

    @Test func copiedClipsPasteAtTheClickedTime() async throws {
        let (s, a) = try await store()
        s.selection = [a]
        let pb = pasteboard()
        let items = TimelineOps.copyItems([a], from: s.project.timeline)
        let payload = ClipboardPayload(items: items, assets: [])
        pb.setData(try JSONEncoder().encode(payload), forType: ClipboardPayload.type)
        s.paste(at: Time(6), from: pb)
        let c = try #require(s.selectedClips.first)
        #expect(c.start == Time(6) && c.id != a)
        #expect(s.project.timeline.allClips.count == 2)
    }
}
