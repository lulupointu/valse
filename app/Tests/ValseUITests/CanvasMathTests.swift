import Testing
import Foundation
import CoreGraphics
import ValseCore
import ValseEngine
@testable import ValseUI
import ValseTestSupport

/// Player canvas geometry: viewport mapping, hit-testing, handles, snapping, drags.
struct CanvasMathTests {
    let canvas = Size2(1920, 1080)

    @Test func viewportFitsWithPaddingAndRoundTrips() {
        let vp = PlayerViewport(viewSize: CGSize(width: 1000, height: 600), canvas: canvas)
        #expect(abs(vp.scale - 968.0 / 1920) < 1e-9)
        let r = vp.contentRect
        #expect(abs(r.midX - 500) < 1e-9 && abs(r.midY - 300) < 1e-9)
        let p = Vec2(123, 456)
        let back = vp.toCanvas(vp.toView(p))
        #expect(abs(back.x - p.x) < 1e-9 && abs(back.y - p.y) < 1e-9)
        var z = vp; z.zoom = 2; z.pan = CGPoint(x: 40, y: -10)
        #expect(abs(z.contentRect.width - r.width * 2) < 1e-9)
        #expect(abs(z.toView(Vec2(960, 540)).x - 540) < 1e-9)
        // pan clamp keeps part of the frame visible
        let c = z.clampedPan(CGPoint(x: 1e6, y: -1e6))
        #expect(c.x < 2000 && c.y > -2000)
    }

    func layer(_ id: ClipID = ClipID(), center: Vec2, half: Vec2, rotation: Double = 0, text: Bool = false, locked: Bool = false) -> CanvasLayer {
        var g = LayerGeometry(sourceSize: Size2(2, 2), canvasSize: canvas, transform: Transform(), fitsCanvas: false)
        g.center = center; g.halfSize = half; g.rotation = rotation
        return CanvasLayer(clipID: id, geometry: g, isText: text, isLocked: locked)
    }

    @Test func hitTestPicksTopmostUnlocked() {
        let bottom = layer(center: Vec2(960, 540), half: Vec2(960, 540))
        let top = layer(center: Vec2(500, 500), half: Vec2(100, 100))
        let locked = layer(center: Vec2(500, 500), half: Vec2(50, 50), locked: true)
        #expect(CanvasLayers.hit([bottom, top, locked], at: Vec2(500, 500))?.clipID == top.clipID)
        #expect(CanvasLayers.hit([bottom, top], at: Vec2(1500, 900))?.clipID == bottom.clipID)
        #expect(CanvasLayers.hit([top], at: Vec2(1500, 900)) == nil)
        // rotated 45°: the corner region of the unrotated box is outside
        let r = layer(center: Vec2(500, 500), half: Vec2(100, 100), rotation: .pi / 4)
        #expect(CanvasLayers.hit([r], at: Vec2(590, 590)) == nil)
        #expect(CanvasLayers.hit([r], at: Vec2(500, 630)) != nil)
    }

    @Test func handlesHitTest() {
        let l = layer(center: Vec2(500, 500), half: Vec2(100, 50), text: true)
        let s = 0.5  // view points per canvas px
        #expect(CanvasHandles.hit(l.geometry, isText: false, at: Vec2(600, 550), viewScale: s) == .corner(3))
        #expect(CanvasHandles.hit(l.geometry, isText: true, at: Vec2(400, 450), viewScale: s) == .delete)
        #expect(CanvasHandles.hit(l.geometry, isText: false, at: Vec2(400, 450), viewScale: s) == .corner(0))
        let rp = CanvasHandles.rotatePosition(l.geometry, viewScale: s)
        #expect(abs(rp.x - 500) < 1e-9 && abs(rp.y - (550 + 48)) < 1e-9)
        #expect(CanvasHandles.hit(l.geometry, isText: false, at: rp, viewScale: s) == .rotate)
        #expect(CanvasHandles.hit(l.geometry, isText: false, at: Vec2(500, 500), viewScale: s) == .body)
        #expect(CanvasHandles.hit(l.geometry, isText: false, at: Vec2(900, 900), viewScale: s) == nil)
    }

    @Test func snappingToCanvasCentreEdgesAndOtherLayers() {
        let other = layer(center: Vec2(1500, 300), half: Vec2(100, 100))
        let sn = CanvasSnapper(canvas: canvas, others: [other], guidesX: [333], threshold: 10)
        // box centre 4 px right of the canvas centre → snaps back, vertical line at 960
        let s = sn.snapMove(minX: 864, maxX: 1064, minY: 100, maxY: 150)
        #expect(s.delta.x == -4)
        #expect(s.lines.contains(.vertical(960)))
        // top edge 7 px below the other layer's top edge (200) → snaps
        let t = sn.snapMove(minX: 0 + 3, maxX: 50 + 3, minY: 207, maxY: 257)
        #expect(t.delta.y == -7 && t.delta.x == -3)
        // guide
        #expect(sn.snapMove(minX: 330, maxX: 400, minY: 500, maxY: 520).lines.contains(.vertical(333)))
        // nothing near
        #expect(sn.snapMove(minX: 600, maxX: 650, minY: 600, maxY: 650).lines.isEmpty)
    }

    @Test func dragsMoveScaleRotate() {
        #expect(CanvasDrag.moved(.zero, by: Vec2(192, -108), canvas: canvas) == Vec2(0.1, -0.1))
        #expect(CanvasDrag.constrained(Vec2(10, -3)) == Vec2(10, 0))
        #expect(CanvasDrag.constrained(Vec2(2, -3)) == Vec2(0, -3))
        let s = CanvasDrag.scaled(Vec2(0.5, 0.5), center: Vec2(100, 100), start: Vec2(200, 100), current: Vec2(300, 100))
        #expect(s == Vec2(1, 1))
        // quarter turn clockwise (y down)
        let r = CanvasDrag.rotated(0, center: .zero, start: Vec2(10, 0), current: Vec2(0, 10), snapping: false)
        #expect(abs(r - 90) < 1e-9)
        let near = CanvasDrag.rotated(0, center: .zero, start: Vec2(10, 0), current: Vec2(10, 10 * tan(88 * .pi / 180)), snapping: true)
        #expect(near == 90)
        let free = CanvasDrag.rotated(0, center: .zero, start: Vec2(10, 0), current: Vec2(10, 10 * tan(80 * .pi / 180)), snapping: true)
        #expect(abs(free - 80) < 1e-6)
        #expect(CanvasDrag.displayAngle(370) == 10 && CanvasDrag.displayAngle(-190) == 170)
    }

    @Test func alignAndFit() {
        let l = layer(center: Vec2(500, 500), half: Vec2(100, 50))
        #expect(CanvasAlign.left.delta(bounds: l.bounds, canvas: canvas) == Vec2(-400, 0))
        #expect(CanvasAlign.bottom.delta(bounds: l.bounds, canvas: canvas) == Vec2(0, 530))
        #expect(CanvasAlign.centerH.delta(bounds: l.bounds, canvas: canvas) == Vec2(460, 0))
        let portrait = Size2(1080, 1920)
        #expect(CanvasFit.fit.scale(sourceSize: portrait, canvas: canvas, crop: CropRect()) == .one)
        let fill = CanvasFit.fill.scale(sourceSize: portrait, canvas: canvas, crop: CropRect())
        #expect(abs(fill.x - 1920.0 / 607.5) < 1e-9)
        let st = CanvasFit.stretch.scale(sourceSize: portrait, canvas: canvas, crop: CropRect())
        #expect(abs(st.y - 1) < 1e-9 && abs(st.x - 1920.0 / 607.5) < 1e-9)
        #expect(RulerTicks.step(viewScale: 0.5) == 100)
    }

    @Test func canvasLayersSizeTextLikeTheRenderer() {
        var p = Project(settings: ProjectSettings(canvasSize: canvas))
        let c = Clip(content: .text(TextContent(string: "Hello")), start: .zero, duration: Time(3))
        try! TimelineOps.insert(c, into: &p)
        let layers = CanvasLayers.at(Time(1), project: p)
        #expect(layers.count == 1 && layers[0].isText)
        let size = TextMetrics.size(of: TextContent(string: "Hello"), canvasHeight: 1080)
        #expect(abs(layers[0].geometry.halfSize.x * 2 - size.width) < 1e-9)
        #expect(size.width > 100 && size.height > 50)
    }

    @Test func fillScaleTurnsFitIntoFill() {
        #expect(LayerGeometry.fillScale(sourceSize: Size2(100, 100), canvasSize: Size2(200, 100)) == 2)
        #expect(LayerGeometry.fillScale(sourceSize: Size2(200, 100), canvasSize: Size2(200, 100)) == 1)
    }
}

/// W3's canvas fill (blur copy / style pattern) renders below the main clip but must never grab canvas clicks.
@MainActor @Suite(.serialized) struct CanvasFillHitTests {
    @Test func canvasFillLayersAreNotHitTestable() async throws {
        var p = TestProject(canvas: Size2(320, 180))
        let id = try await p.addVideo(.solid(.red), size: CGSize(width: 90, height: 160))
        for bg in [CanvasBackground.blur(level: 2), .style(id: "valse.canvas.dots")] {
            p[id].canvas = bg
            let frame = FrameEvaluator.evaluate(p.project, at: Time(0.5))
            let fills = frame.items.compactMap { if case .layer(let l) = $0, l.isCanvasBackground { return l }; return nil }
            #expect(fills.count == 1)
            // a click in the filled letterbox area hits nothing; a click on the clip selects it
            let layers = CanvasLayers.at(Time(0.5), project: p.project)
            #expect(layers.map(\.clipID) == [id])
            #expect(CanvasLayers.hit(layers, at: Vec2(10, 90)) == nil)
            #expect(CanvasLayers.hit(layers, at: Vec2(160, 90))?.clipID == id)
        }
    }
}

@MainActor @Suite(.serialized) struct PlayerStoreTests {
    func store() async throws -> (EditorStore, ClipID) {
        var p = TestProject(canvas: Size2(320, 180))
        let a = try await p.addVideo(.solid(.red), seconds: 2)
        let s = EditorStore(project: p.project)
        s.autosaveEnabled = false
        return (s, a)
    }

    @Test func nudgeMovesSelectionOnlyWithCanvasFocus() async throws {
        let (s, id) = try await store()
        s.selection = [id]
        s.arrow(dx: 1, dy: 0, big: false)       // no focus → frame step, no edit
        #expect(s.project.timeline.clip(id)!.transform.position == .zero)
        s.playerUI.canvasHasFocus = true
        s.arrow(dx: 1, dy: 0, big: true)
        s.arrow(dx: 0, dy: -1, big: false)
        let pos = s.project.timeline.clip(id)!.transform.position
        #expect(abs(pos.x - 10.0 / 320) < 1e-9 && abs(pos.y + 1.0 / 180) < 1e-9)
        s.undo()
        #expect(abs(s.project.timeline.clip(id)!.transform.position.y) < 1e-12)
    }

    @Test func ratioMenuChangesCanvasAndOriginalRestoresMediaAspect() async throws {
        let (s, _) = try await store()
        s.setRatio("9:16")
        #expect(s.project.settings.canvasSize == Size2(1080, 1920) && s.project.settings.aspectPreset == "9:16")
        s.setRatio("original")
        #expect(s.project.settings.canvasSize == Size2(320, 180))
        s.setCustomCanvas(width: 1001, height: 500)
        #expect(s.project.settings.canvasSize == Size2(1000, 500) && s.project.settings.aspectPreset == "custom")
    }

    @Test func loopRangeFollowsSelection() async throws {
        let (s, id) = try await store()
        s.toggleLoop()
        #expect(s.engine.loopRange == TimeRange(start: .zero, end: s.project.duration))
        s.selection = [id]
        #expect(s.engine.loopRange == s.project.timeline.clip(id)!.range)
        s.toggleLoop()
        #expect(s.engine.loopRange == nil)
    }

    @Test func playerZoomClampsAndResets() async throws {
        let (s, _) = try await store()
        for _ in 0..<40 { s.zoomPlayer(by: 1.25) }
        #expect(s.playerUI.zoom == PlayerViewport.zoomRange.upperBound)
        s.playerUI.pan = CGPoint(x: 10, y: 10)
        s.resetPlayerZoom()
        #expect(!s.playerUI.isZoomed)
    }

    @Test func playerShortcutsAreRegistered() {
        let ids = Set(ShortcutRegistry.all.map(\.id))
        for id in ["playerFullscreen", "playerZoomIn", "playerZoomOut", "playerZoomFit", "rulers", "guides", "nudgeUp"] {
            #expect(ids.contains(id))
        }
    }

    @Test func dynamicPlayerKeysAreLocalized() {
        ValseBootstrap.registerResources()
        var keys: [String] = []
        keys += PlayerMenus.qualities.flatMap { ["player.quality.\($0.rawValue).title", "player.quality.\($0.rawValue).detail", PlayerMenus.qualityShortKey($0)] }
        keys += ProjectSettings.aspectPresets.map { "player.ratio.\($0.id)" }
        keys += SafeZone.allCases.map(\.titleKey) + CanvasAlign.allCases.map(\.titleKey) + CanvasFit.allCases.map(\.titleKey)
        for lang in ["en", "fr"] {
            L10n.shared.setLanguageForSession(lang)
            for k in keys { #expect(tr(k) != k, "\(lang): \(k)") }
        }
        L10n.shared.setLanguageForSession("en")
    }
}
