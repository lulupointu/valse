import Testing
import Foundation
import AppKit
import SwiftUI
import ValseCore
import ValseEffects
import ValseEngine
@testable import ValseUI
import ValseTestSupport

/// W5 store flows: applying / replacing transitions, validation toasts, overlay cuts, parameter rows, tab snapshot.
@MainActor @Suite(.serialized) struct TransitionStoreTests {
    func store(gap: Bool = false) async throws -> (EditorStore, [ClipID]) {
        var p = TestProject(canvas: Size2(320, 180))
        let a = try await p.addVideo(.solid(.red), seconds: 2)
        let b = try await p.addVideo(.solid(.blue), seconds: 2, at: 10)
        var ids = [a, b]
        if gap {
            p.project.timeline.mainTrackMagnet = false
            let o = try await p.addVideo(.solid(.green), seconds: 2, target: .newTrack)
            let tid = p.project.timeline.tracks[p.project.timeline.locate(o)!.track].id
            ids.append(o)
            ids.append(try await p.addVideo(.solid(.white), seconds: 2, at: 5, target: .track(tid)))
        }
        let s = EditorStore(project: p.project)
        s.autosaveEnabled = false
        return (s, ids)
    }

    @Test func applyAtPlayheadSelectsAndReplaceKeepsDuration() async throws {
        let (s, ids) = try await store()
        s.applyTransition(Registries.transitions["valse.transition.cubeLeft"]!)
        #expect(s.selectedTransition == ids[0])
        #expect(s.project.timeline.clip(ids[0])?.transitionOut?.typeID == "valse.transition.cubeLeft")
        // change duration, then replace with another preset: the duration stays
        s.perform(SetTransition(ids[0], TransitionInstance(typeID: "valse.transition.cubeLeft", duration: Time(0.8))))
        s.applyTransition(Registries.transitions["valse.transition.heart"]!)
        let t = s.project.timeline.clip(ids[0])?.transitionOut
        #expect(t?.typeID == "valse.transition.heart" && t?.duration == Time(0.8))
        #expect(t?.params["softness"] != nil)   // defaults filled
        s.undo()
        #expect(s.project.timeline.clip(ids[0])?.transitionOut?.typeID == "valse.transition.cubeLeft")
    }

    @Test func refusesWithToastWhenThereIsNoContinuousClip() async throws {
        let (s, ids) = try await store(gap: true)
        s.selection = [ids[2]]               // overlay clip followed by a 3 s gap
        s.applyTransition(Registries.transitions["valse.transition.dissolve"]!)
        #expect(s.project.timeline.clip(ids[2])?.transitionOut == nil)
        #expect(s.toast?.isError == true)
        #expect(s.toast?.message == tr("transition.issue.noContinuousClips"))
    }

    @Test func overlayCutTakesTransitions() async throws {
        let (s, ids) = try await store(gap: true)
        // close the gap, then apply on the overlay clip
        s.perform(Edit("cmd.move") { p in
            let ti = p.timeline.locate(ids[3])!.track
            p.timeline.tracks[ti].clips[1].start = Time(2)
        })
        s.selection = [ids[2]]
        s.applyTransition(Registries.transitions["valse.transition.slideLeft"]!)
        #expect(s.project.timeline.clip(ids[2])?.transitionOut?.typeID == "valse.transition.slideLeft")
        #expect(s.project.timeline.clip(ids[3])?.start == Time(1.5))
        #expect(TimelineOps.validate(s.project.timeline).isEmpty)
    }

    /// Visual check of the tab and of the transition inspector rows (VALSE_SNAPSHOT_DIR=… to write PNGs).
    @Test func transitionsTabAndParamsRender() async throws {
        let (s, ids) = try await store()
        s.applyTransition(Registries.transitions["valse.transition.wipeLeft"]!)
        // let a few thumbnails land
        for d in Registries.transitions.all.prefix(12) { _ = TransitionThumbnails.shared.still(d) }
        await TransitionThumbnails.shared.idle()   // awaited (B1): a 12 s poll budget ran out under full-suite load
        #expect(TransitionThumbnails.shared.still(Registries.transitions.all[0]) != nil)
        let tab = TransitionsTab(store: s).frame(width: 520, height: 420).background(Theme.panel)
        let img = Self.snapshot(tab, size: CGSize(width: 520, height: 420))
        #expect(img != nil)
        let ctx = InspectorContext(store: s)
        #expect(ctx.transitionClip?.id == ids[0])
        let rows = TransitionSection(ctx: ctx).padding(12).frame(width: 320, height: 200).background(Theme.panel)
        #expect(Self.snapshot(rows, size: CGSize(width: 320, height: 200)) != nil)
    }

    static func snapshot<V: View>(_ v: V, size: CGSize) -> NSImage? {
        let host = NSHostingView(rootView: v.environment(\.colorScheme, .dark))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["VALSE_SNAPSHOT_DIR"], let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("w5-\(size.width)x\(size.height).png"))
        }
        let img = NSImage(size: size); img.addRepresentation(rep)
        return img
    }
}
