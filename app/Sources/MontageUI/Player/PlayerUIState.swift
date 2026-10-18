import SwiftUI
import Observation
import AppKit
import UniformTypeIdentifiers
import ImageIO
import MontageCore
import MontageEngine

/// A guide line on the canvas (PB-011), stored as a fraction of the canvas so it survives ratio changes.
public struct CanvasGuide: Hashable, Identifiable, Sendable {
    public enum Axis: Sendable { case horizontal, vertical }
    public let id = UUID()
    public var axis: Axis
    /// 0…1 of canvas height (horizontal) or width (vertical).
    public var position: Double
    public init(axis: Axis, position: Double) { self.axis = axis; self.position = position }
}

/// Player-only UI state (viewport, overlays, modes). Kept out of the project: none of it is undoable or exported.
@Observable
public final class PlayerUIState {
    /// Player zoom (1 = fit) and pan in view points (PB-007).
    public var zoom: Double = 1
    public var pan: CGPoint = .zero
    public var isZoomBarVisible = false
    // Guides & rulers (PB-011)
    public var showRulers = false
    public var showGuides = true
    public var guidesLocked = false
    public var guides: [CanvasGuide] = []
    // Social-media safe zones (PB-010)
    public var safeZone: SafeZone = .none
    /// Preview proxies on/off (mirrors `PlaybackEngine.usesProxies`).
    public var usesProxies = true
    /// Loop playback of the selected clip (or the whole timeline) (PB-009).
    public var loopEnabled = false
    /// Player-only full screen (PB-006).
    public var isFullscreen = false
    /// Clip whose text is being edited in place on the canvas.
    public var editingTextClip: ClipID?
    /// The canvas was the last thing clicked: arrow keys nudge the selected layer instead of stepping frames.
    public var canvasHasFocus = false
    /// Modal canvas tool (AI cutout brush, W10): when set it receives all left-mouse input on the canvas and draws its
    /// own overlay. nil = normal selection/transform behaviour.
    public var canvasTool: (any CanvasTool)?

    public var isZoomed: Bool { abs(zoom - 1) > 0.001 || pan != .zero }
}

/// A modal tool that takes over the canvas (points are in canvas pixels, origin top-left). Implementations are
/// @Observable and bump `revision` when their overlay changes.
@MainActor public protocol CanvasTool: AnyObject {
    var revision: Int { get }
    func mouseDown(at p: Vec2)
    func mouseDragged(at p: Vec2)
    func mouseUp(at p: Vec2)
    /// Draws in view coordinates; `toView` maps canvas pixels to view points, `scale` = view points per canvas pixel.
    func draw(in ctx: CGContext, toView: (Vec2) -> CGPoint, scale: Double)
}

// MARK: Player commands (used by the player panel, canvas overlay, shortcuts and menus)

extension EditorStore {
    /// Applies a ratio from the Ratio menu ("original" = first main-track media's aspect). Content keeps its fit.
    public func setRatio(_ id: String) {
        if id == "original" {
            let first = project.timeline.mainTrack?.clips.first.flatMap { $0.mediaID }.flatMap { project.asset($0) }
            let size = first.map { Self.canvasSize(forMedia: $0.pixelSize) } ?? project.settings.canvasSize
            perform(UpdateSettings { s in s.canvasSize = size; s.aspectPreset = "original" })
        } else if let size = ProjectSettings.presetSize(id) {
            perform(UpdateSettings { s in s.canvasSize = size; s.aspectPreset = id })
        }
        resetPlayerZoom()
    }

    /// "Customized" ratio: any width × height (even, 16…8192 px).
    public func setCustomCanvas(width: Double, height: Double) {
        func even(_ v: Double) -> Double { (min(max(v, 16), 8192) / 2).rounded(.down) * 2 }
        let size = Size2(even(width), even(height))
        perform(UpdateSettings { s in s.canvasSize = size; s.aspectPreset = "custom" })
        resetPlayerZoom()
    }

    /// Canvas for a media size, 1080p class (short side ≤ 1080, even dimensions) like `adoptCanvas`.
    static func canvasSize(forMedia size: Size2) -> Size2 {
        guard size.width > 0, size.height > 0 else { return .hd1080 }
        let short = min(size.width, size.height)
        let k = short > 1080 ? 1080 / short : 1
        return Size2((size.width * k / 2).rounded() * 2, (size.height * k / 2).rounded() * 2)
    }

    // MARK: Zoom (⌥⇧+ / ⌥⇧− / ⌥⇧Z)

    public func zoomPlayer(by factor: Double) {
        playerUI.zoom = min(max(playerUI.zoom * factor, PlayerViewport.zoomRange.lowerBound), PlayerViewport.zoomRange.upperBound)
        if playerUI.zoom <= 1 { playerUI.pan = .zero }
    }

    public func resetPlayerZoom() { playerUI.zoom = 1; playerUI.pan = .zero }

    // MARK: Preview quality & proxies (PB-002)

    /// Proxy toggle: preview decodes proxies when ready (on) or always the originals (off). Export is unaffected.
    public func setUsesProxies(_ on: Bool) {
        playerUI.usesProxies = on
        engine.usesProxies = on
    }

    // MARK: Loop (PB-009)

    public func toggleLoop() {
        playerUI.loopEnabled.toggle()
        updateLoopRange()
    }

    /// Loop range = selected clip(s) span, else the whole timeline.
    func updateLoopRange() {
        guard playerUI.loopEnabled else { engine.loopRange = nil; return }
        let sel = selectedClips
        if let s = sel.map(\.start).min(), let e = sel.map(\.end).max(), e > s {
            engine.loopRange = TimeRange(start: s, end: e)
        } else if project.duration > .zero {
            engine.loopRange = TimeRange(start: .zero, end: project.duration)
        } else {
            engine.loopRange = nil
        }
    }

    // MARK: Full screen (PB-006: ⇧⌘F, esc exits)

    public func togglePlayerFullscreen() { setPlayerFullscreen(!playerUI.isFullscreen) }

    public func setPlayerFullscreen(_ on: Bool) {
        guard playerUI.isFullscreen != on else { return }
        playerUI.isFullscreen = on
        if let w = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }),
           w.styleMask.contains(.fullScreen) != on, w.isVisible, NSApp.activationPolicy() == .regular {
            w.toggleFullScreen(nil)
        }
    }

    // MARK: Canvas nudge (CV-011: arrows, ⇧ = 10 px)

    /// Moves the selected visual clips by `dx, dy` canvas pixels (one undo step per key press).
    public func nudgeSelection(dx: Double, dy: Double) {
        let ids = selection
        let canvas = project.settings.canvasSize
        let t = transport.playhead
        perform(Edit("cmd.transform") { p in
            for id in ids {
                guard var c = p.timeline.clip(id), c.content != .adjustment else { continue }
                let local = (t - c.start).clamped(.zero, c.duration)
                let pos = c.value(.position, at: local)?.vec2 ?? .zero
                c.setValue(.position, .vec2(CanvasDrag.moved(pos, by: Vec2(dx, dy), canvas: canvas)), at: local)
                p.timeline[clip: id] = c
            }
        })
    }

    /// Arrow keys nudge the selection (instead of stepping frames) after a click on the canvas.
    var canvasNudgeEnabled: Bool { playerUI.canvasHasFocus && !selection.isEmpty }

    /// Arrow keys: nudge when the canvas has focus and something is selected, else step frames.
    func arrow(dx: Int, dy: Int, big: Bool) {
        if canvasNudgeEnabled {
            let k = big ? 10.0 : 1.0
            nudgeSelection(dx: Double(dx) * k, dy: Double(dy) * k)
        } else if dx != 0 {
            step(frames: dx * (big ? 10 : 1))
        }
    }

    // MARK: Hover preview (timeline preview axis)

    /// Shows the frame at `t` in the player without moving the playhead (nil = back to the playhead).
    public func hoverPreview(_ t: Time?) { engine.previewHover(t) }

    // MARK: Export still frame (player ☰ menu)

    public func exportStillFrame() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]   // EX-012: PNG or JPEG (by extension)
        panel.nameFieldStringValue = "\(projectName) \(Timecode.string(transport.playhead, rate: project.settings.frameRate, showFrames: true).replacingOccurrences(of: ":", with: "-")).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let project = self.project, t = transport.playhead
        Task {
            do {
                try await StillFrameExporter.export(project: project, at: t, to: url)
                showToast(tr("player.stillSaved"))
            } catch {
                showToast(tr("player.stillFailed"), error: true)
            }
        }
    }
}
