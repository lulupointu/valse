import Testing
import AppKit
import ValseCore
@testable import ValseUI

/// AU-FADE-UI: Final Cut Pro–style fade curve art, pin handle and curve menu.
@MainActor @Suite struct FadeArtTests {
    let area = CGRect(x: 100, y: 40, width: 300, height: 40)

    @Test func curveRunsFromTheBottomCornerToTheVolumeLine() {
        for shape in FadeShape.allCases {
            let fin = FadeArt.curve(shape, fadeIn: true, in: area, lineY: 50, samples: 32)
            #expect(fin.first == CGPoint(x: area.minX, y: area.maxY))
            #expect(abs(fin.last!.y - 50) < 0.001 && abs(fin.last!.x - area.maxX) < 0.001)
            // fade-in rises (y decreases) monotonically; fade-out is its mirror
            #expect(zip(fin, fin.dropFirst()).allSatisfy { $1.y <= $0.y + 1e-9 })
            let fout = FadeArt.curve(shape, fadeIn: false, in: area, lineY: 50, samples: 32)
            #expect(abs(fout.first!.y - 50) < 0.001 && fout.last!.y == area.maxY)
        }
        // the shapes differ: at the middle +3 dB is above linear, −3 dB below, S-curve on it
        func mid(_ s: FadeShape) -> CGFloat { FadeArt.curve(s, fadeIn: true, in: area, lineY: area.minY, samples: 2)[1].y }
        #expect(mid(.plus3dB) < mid(.linear) && mid(.minus3dB) > mid(.linear) && abs(mid(.sCurve) - mid(.linear)) < 0.001)
    }

    @Test func overlayAndPinRenderAtTheBackingScaleAndAreCached() {
        let a = FadeArt.overlay(.sCurve, fadeIn: true, size: CGSize(width: 60, height: 30), lineY: 8, scale: 2)
        #expect(a?.width == 120 && a?.height == 60)
        #expect(a === FadeArt.overlay(.sCurve, fadeIn: true, size: CGSize(width: 60, height: 30), lineY: 8, scale: 2))
        #expect(a !== FadeArt.overlay(.linear, fadeIn: true, size: CGSize(width: 60, height: 30), lineY: 8, scale: 2))
        // very long fades are stretched from a capped bitmap
        #expect(FadeArt.overlay(.linear, fadeIn: false, size: CGSize(width: 5000, height: 30), lineY: 8, scale: 2)?.width == FadeArt.maxOverlayPixels)
        for state in [FadeArt.PinState.normal, .hover, .active] {
            let p = FadeArt.pin(state, scale: 2)
            let r = FadeArt.pinRect(x: 0, lineY: 0, area: CGRect(x: 0, y: -100, width: 10, height: 200))
            #expect(p?.width == Int(r.width * 2) && p?.height == Int(r.height * 2))
        }
        #expect(FadeArt.pin(.normal, scale: 2) !== FadeArt.pin(.active, scale: 2))
    }

    @Test func pinSitsOnTheVolumeLineInsideTheArea() {
        let r = FadeArt.pinRect(x: 150, lineY: 55, area: area)
        #expect(abs(r.midX - 150) < 0.001)
        #expect(r.minY < 55 && r.maxY > 55)
        // volume 0: the line is the bottom edge; the pin tip stays inside the area
        let low = FadeArt.pinRect(x: 150, lineY: area.maxY, area: area)
        #expect(low.maxY - FadeArt.pinMargin <= area.maxY + 0.001)
    }

    @Test func lruEvictsTheOldest() {
        var c = LRU<Int, String>(capacity: 2)
        c[1] = "a"; c[2] = "b"; _ = c[1]; c[3] = "c"
        #expect(c[1] == nil && c[2] == "b" && c[3] == "c" && c.count == 2)
    }

    @Test func curveMenuFollowsFinalCutProWithThumbnails() throws {
        ValseBootstrap.registerResources()
        let s = EditorStore(project: try TimelineMediaC3Tests().project())
        s.autosaveEnabled = false
        let id = s.project.timeline.mainTrack!.clips[0].id
        let v = TimelineView(store: s)
        let m = v.fadeShapeMenu(id, fadeIn: false, current: .plus3dB)
        #expect(m.items.map { $0.identifier?.rawValue } == ["fade.shape.linear", "fade.shape.sCurve", "fade.shape.plus3dB", "fade.shape.minus3dB"])
        #expect(m.items.map(\.title) == [tr("fade.shape.linear"), tr("fade.shape.sCurve"), "+3 dB", "−3 dB"])
        #expect(m.items.map(\.state) == [.off, .off, .on, .off])
        #expect(m.items.allSatisfy { ($0.view as? FadeShapeMenuItemView)?.fadeIn == false })
        #expect(m.items.compactMap { ($0.view as? FadeShapeMenuItemView)?.shape } == [.linear, .sCurve, .plus3dB, .minus3dB])
        // the thumbnail row draws (light and dark) without a window
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let view = try #require(m.items[1].view)
            view.appearance = NSAppearance(named: name)
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            #expect(rep.pixelsWide > 0)
        }
        m.performActionForItem(at: 1)
        #expect(s.project.timeline.clip(id)?.audio.fadeOutShape == .sCurve)
        #expect(s.session.undoNameKey == "cmd.fadeShape")
    }
}
