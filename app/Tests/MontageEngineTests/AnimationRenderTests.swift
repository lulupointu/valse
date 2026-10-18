import CoreGraphics
import Foundation
import Testing
import MontageCore
import MontageEffects
import MontageEngine
import MontageTestSupport

/// W5 animation presets, rendered through the real compositor: In ends at the clip's rest state, Out starts at it,
/// Loops are seamless, Combos rest mid-clip, and every preset visibly moves the layer somewhere.
@Suite(.serialized) struct AnimationRenderTests {
    static let canvas = Size2(96, 54)

    /// A white, half-size solid layer (with a red stripe so rotations/flips show) on black.
    static func frame(_ anim: AnimationDescriptor?, progress: Double) -> FrameDescription {
        var l = LayerDescription(clipID: ClipID(), trackID: TrackID(), source: .solid(.white), sourceSize: canvas,
                                 transform: Transform(scale: Vec2(0.5, 0.5)), opacity: 1, blendMode: .normal, crop: CropRect(),
                                 mask: nil, effects: [], animations: [], localTime: .zero)
        if let anim {
            let phase: ActiveAnimation.Phase = anim.phase == .in ? .in : anim.phase == .out ? .out : .combo
            l.animations = [ActiveAnimation(typeID: anim.id, phase: phase, progress: progress)]
        }
        var stripe = l
        stripe.source = .solid(.red)
        stripe.transform.scale = Vec2(0.5, 0.1)
        stripe.transform.position = Vec2(0, -0.1)
        return FrameDescription(time: .zero, canvasSize: canvas, background: .black, items: [.layer(l), .layer(stripe)])
    }

    static func render(_ anim: AnimationDescriptor?, _ p: Double) -> Bitmap? {
        PresetPreviewRenderer.render(frame(anim, progress: p), width: Int(canvas.width), height: Int(canvas.height)).map(Bitmap.init)
    }

    static func diff(_ a: Bitmap, _ b: Bitmap) -> Double {
        var s = 0.0
        for i in stride(from: 0, to: a.pixels.count, by: 4) { for c in 0..<3 { s += abs(Double(a.pixels[i + c]) - Double(b.pixels[i + c])) } }
        return s / Double(a.width * a.height * 3) / 255
    }

    @Test func libraryCoversEveryPhaseAndTarget() {
        let all = BuiltinAnimations.all
        #expect(all.count >= 60)
        #expect(Registries.animations(.in, for: .video).count >= 20)
        #expect(Registries.animations(.out, for: .video).count >= 20)
        #expect(Registries.animations(.combo, for: .video).count >= 10)
        #expect(Registries.animations(.combo, for: .sticker).count >= 10)
        #expect(Registries.animations(.in, for: .sticker).count >= 20)
        #expect(Set(all.map(\.id)).count == all.count)
        for id in ["in.fade", "in.slideUp", "in.slideRight", "in.zoom", "in.spin", "out.fade", "out.slideDown", "out.zoom",
                   "combo.pulse", "combo.swing"] {
            #expect(Registries.animations["montage.anim.\(id)"] != nil, "persisted id \(id)")
        }
    }

    /// Pure state check, every preset: In ends / Out starts exactly at rest; loops close.
    @Test func restStatesAreExact() {
        let rest = AnimatedLayerState(transform: Transform(position: Vec2(0.1, -0.2), scale: Vec2(0.8, 0.8), rotation: 10), opacity: 0.9)
        func state(_ d: AnimationDescriptor, _ p: Double) -> AnimatedLayerState { var s = rest; d.apply(p, &s); return s }
        func same(_ a: AnimatedLayerState, _ b: AnimatedLayerState) -> Bool {
            abs(a.opacity - b.opacity) < 1e-6 && abs(a.transform.position.x - b.transform.position.x) < 1e-6
                && abs(a.transform.position.y - b.transform.position.y) < 1e-6 && abs(a.transform.scale.x - b.transform.scale.x) < 1e-6
                && abs(a.transform.scale.y - b.transform.scale.y) < 1e-6 && abs(a.blur - b.blur) < 1e-6 && a.reveal == b.reveal
                && { let r = abs(a.transform.rotation - b.transform.rotation).truncatingRemainder(dividingBy: 360); return min(r, 360 - r) < 1e-6 }()
        }
        for d in BuiltinAnimations.all {
            switch d.phase {
            case .in: #expect(same(state(d, 1), rest), "\(d.id) ends at rest")
            case .out: #expect(same(state(d, 0), rest), "\(d.id) starts at rest")
            case .combo:
                if d.targets.contains(.video) { #expect(same(state(d, 0.5), rest) || d.id.contains("kenBurns") || d.id.contains("push") || d.id.contains("pull") || d.id.contains("rock"), "\(d.id) rests mid-clip") }
                else { #expect(same(state(d, 0), rest) && same(state(d, 1), state(d, 0)), "\(d.id) loops seamlessly") }
            }
        }
    }

    @Test func everyPresetRendersItsMotion() throws {
        let rest = try #require(Self.render(nil, 0))
        var problems: [String] = []
        for d in BuiltinAnimations.all {
            let probes: [Double] = d.phase == .in ? [0, 0.3, 1] : d.phase == .out ? [0, 0.7, 0.999] : [0, 0.15, 0.4, 0.5, 0.65]
            let frames = PresetPreviewRenderer.render(probes.map { Self.frame(d, progress: $0) }, width: Int(Self.canvas.width),
                                                      height: Int(Self.canvas.height)).compactMap { $0.map(Bitmap.init) }
            guard frames.count == probes.count else { problems.append("\(d.id): no render"); continue }
            let diffs = frames.map { Self.diff($0, rest) }
            switch d.phase {
            case .in:
                if diffs[2] > 0.002 { problems.append("\(d.id): 100% ≠ rest (\(diffs[2]))") }
                if diffs[0] < 0.01 { problems.append("\(d.id): 0% looks like rest (\(diffs[0]))") }
            case .out:
                if diffs[0] > 0.002 { problems.append("\(d.id): 0% ≠ rest (\(diffs[0]))") }
                if diffs[2] < 0.01 { problems.append("\(d.id): 100% looks like rest (\(diffs[2]))") }
            case .combo:
                if (diffs.max() ?? 0) < 0.005 { problems.append("\(d.id): never moves (\(diffs))") }
            }
        }
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test func blurAndRevealReachThePixels() async throws {
        // blur: a white|black split image gets a soft centre edge
        let asset = try await MediaProbe.probe(try TestMedia.image(.split(.white, .black), size: CGSize(width: 160, height: 90)))
        let blurIn = try #require(Registries.animations["montage.anim.in.blur"])
        func splitFrame(_ anim: AnimationDescriptor?, _ p: Double) -> Bitmap? {
            var l = LayerDescription(clipID: ClipID(), trackID: TrackID(), source: .image(asset.id), sourceSize: asset.pixelSize,
                                     transform: Transform(), opacity: 1, blendMode: .normal, crop: CropRect(), mask: nil,
                                     effects: [], animations: [], localTime: .zero)
            if let anim { l.animations = [ActiveAnimation(typeID: anim.id, phase: .in, progress: p)] }
            let f = FrameDescription(time: .zero, canvasSize: Self.canvas, background: .black, items: [.layer(l)])
            return PresetPreviewRenderer.render(f, media: [asset.id: asset], width: 160, height: 90).map(Bitmap.init)
        }
        let sharp = try #require(splitFrame(nil, 0)), soft = try #require(splitFrame(blurIn, 0.1))
        #expect(sharp.pixel(77, 45).luma > 0.95 && sharp.pixel(82, 45).luma < 0.02)
        #expect(soft.pixel(82, 45).luma > 0.03, "light spills across the edge")
        #expect(soft.pixel(77, 45).luma < soft.pixel(30, 45).luma - 0.03, "the white side darkens near the edge")
        // wipe right at 50 % hides the right part of the square, keeps the left part in place
        let wipe = try #require(Registries.animations["montage.anim.in.wipeRight"])
        let half = try #require(Self.render(wipe, 0.5))
        #expect(half[0.3, 0.75].luma > 0.6)
        #expect(half[0.7, 0.75].luma < 0.05)
    }

    /// Through AVFoundation + the compositor on a video clip: fade in starts dark, ends at full brightness.
    @Test func fullPipelineInAndOut() async throws {
        var p = TestProject()
        let id = try await p.addVideo(.solid(.white), seconds: 3)
        p[id].animations.inAnim = AnimationInstance(typeID: "montage.anim.in.fade", duration: 1)
        p[id].animations.outAnim = AnimationInstance(typeID: "montage.anim.out.wipeLeft", duration: 1)
        #expect(try await p.render(at: 0.02)[0.5, 0.5].luma < 0.15)
        #expect(try await p.render(at: 1.5)[0.5, 0.5].luma > 0.9)
        let late = try await p.render(at: 2.6)
        #expect(late[0.1, 0.5].luma > 0.9)
        #expect(late[0.9, 0.5].luma < 0.1)
    }
}
