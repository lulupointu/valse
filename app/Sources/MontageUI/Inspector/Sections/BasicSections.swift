import SwiftUI
import MontageCore
import MontageEffects
import MontageEngine
import Perception

// MARK: - Blend

/// Video ▸ Basic ▸ ☑ Blend: Mode dropdown + Opacity ‹◇› (UX.md §5.1).
struct BlendSection: View {
    let ctx: InspectorContext

    static func chrome(_ ctx: InspectorContext) -> InspectorSectionChrome {
        InspectorSectionChrome(
            isEnabled: Binding.perceived(get: { !(ctx.clip.map { InspectorUIState.shared.blendOff.contains($0.id) } ?? false) },
                               set: { on in
                                   guard let id = ctx.clip?.id else { return }
                                   if on { InspectorUIState.shared.blendOff.remove(id) } else {
                                       InspectorUIState.shared.blendOff.insert(id)
                                       ctx.store.performInspector(UpdateClip(id, nameKey: "cmd.blend") { c in
                                           c.blendMode = .normal; c.opacity = 1; c.clearKeyframes([.opacity])
                                       })
                                   }
                               }),
            reset: {
                guard let id = ctx.clip?.id else { return }
                ctx.store.performInspector(UpdateClip(id, nameKey: "cmd.blend") { c in c.blendMode = .normal; c.opacity = 1; c.clearKeyframes([.opacity]) })
            },
            keyframeKeys: [.opacity])
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 6) {
                InlineRow(label: tr("inspector.blendMode")) {
                    Dropdown(items: BlendMode.allCases.map { ($0, tr($0.nameKey)) }, selection: ctx.clip?.blendMode ?? .normal) { m in
                        guard let id = ctx.clip?.id else { return }
                        ctx.store.performInspector(UpdateClip(id, nameKey: "cmd.blend") { $0.blendMode = m })
                    }
                }
                OpacityRow(ctx: ctx)
            }
        }
    }
}

struct OpacityRow: View {
    let ctx: InspectorContext
    var body: some View {
        WithPerceptionTracking {
            Bind.row(ctx, tr("prop.opacity"), key: .opacity, spec: RowSpec(range: 0...100, step: 1, format: Fmt.percentValue),
                     toUI: { $0 * 100 }, fromUI: { $0 / 100 }, gestureName: "cmd.opacity")
        }
    }
}

// MARK: - Crop

/// Video ▸ Basic ▸ Crop: ratio presets + per-edge insets, keyframeable as a group (FEATURES CV-006).
struct CropSection: View {
    let ctx: InspectorContext

    static let ratios: [(id: String, w: Double, h: Double)] = [
        ("free", 0, 0), ("original", -1, -1), ("16:9", 16, 9), ("9:16", 9, 16), ("1:1", 1, 1), ("4:3", 4, 3), ("3:4", 3, 4),
        ("2.35:1", 2.35, 1), ("4:5", 4, 5),
    ]

    static func chrome(_ ctx: InspectorContext) -> InspectorSectionChrome {
        InspectorSectionChrome(reset: {
            guard let id = ctx.clip?.id else { return }
            InspectorUIState.shared.cropRatio[id] = nil
            ctx.store.performInspector(UpdateClip(id, nameKey: "cmd.crop") { c in c.crop = CropRect(); c.clearKeyframes(ParamKey.cropGroup) })
        }, keyframeKeys: ParamKey.cropGroup, startsCollapsed: true)
    }

    var body: some View {
        WithPerceptionTracking {
            let sel = ctx.clip.flatMap { InspectorUIState.shared.cropRatio[$0.id] } ?? "free"
            VStack(alignment: .leading, spacing: 6) {
                InlineRow(label: tr("inspector.crop.ratio")) {
                    Dropdown(items: Self.ratios.map { ($0.id, $0.id == "free" ? tr("inspector.crop.free") : ($0.id == "original" ? tr("player.ratio.original") : $0.id)) },
                             selection: sel) { applyRatio($0) }
                }
                edge(.cropLeft, "prop.cropLeft", other: \.right)
                edge(.cropRight, "prop.cropRight", other: \.left)
                edge(.cropTop, "prop.cropTop", other: \.bottom)
                edge(.cropBottom, "prop.cropBottom", other: \.top)
            }
        }
    }

    func edge(_ key: ParamKey, _ label: String, other: KeyPath<CropRect, Double>) -> some View {
        Bind.row(ctx, tr(label), key: key, spec: RowSpec(range: 0...90, step: 1, format: Fmt.percentValue),
                 toUI: { $0 * 100 }, fromUI: { $0 / 100 }, gestureName: "cmd.crop")
    }

    /// Centred crop of the source to the ratio (in display pixels).
    func applyRatio(_ id: String) {
        guard let clip = ctx.clip else { return }
        InspectorUIState.shared.cropRatio[clip.id] = id
        guard let r = Self.ratios.first(where: { $0.id == id }), r.w != 0 else { return }
        let src = ctx.asset?.pixelSize ?? ctx.store.project.settings.canvasSize
        guard src.width > 0, src.height > 0 else { return }
        let target = r.w < 0 ? 0 : r.w / r.h
        let local = ctx.localTime
        ctx.store.performInspector(UpdateClip(clip.id, nameKey: "cmd.crop") { c in
            var crop = CropRect()
            if target > 0 {
                let a = src.width / src.height
                if a > target { let keep = target / a; crop.left = (1 - keep) / 2; crop.right = crop.left }
                else { let keep = a / target; crop.top = (1 - keep) / 2; crop.bottom = crop.top }
            }
            c.setValue(.cropLeft, .scalar(crop.left), at: local)
            c.setValue(.cropRight, .scalar(crop.right), at: local)
            c.setValue(.cropTop, .scalar(crop.top), at: local)
            c.setValue(.cropBottom, .scalar(crop.bottom), at: local)
        })
    }
}

// MARK: - Canvas

/// Video ▸ Basic ▸ ☑ Canvas: None / Blur / Color / Style + [Apply to all] (main-track clips, UX.md §5.1, CV-002).
struct CanvasSection: View {
    let ctx: InspectorContext

    static let palette: [UInt32] = [0x000000, 0xFFFFFF, 0x7F7F7F, 0xE53935, 0xFB8C00, 0xFDD835, 0x43A047, 0x00ACC1,
                                    0x1E88E5, 0x3949AB, 0x8E24AA, 0xD81B60, 0x6D4C41, 0xF8BBD0, 0xB2EBF2, 0xC5E1A5]

    static func chrome(_ ctx: InspectorContext) -> InspectorSectionChrome {
        InspectorSectionChrome(
            isEnabled: Binding.perceived(get: { !(ctx.clip.map { InspectorUIState.shared.canvasOff.contains($0.id) } ?? false) },
                               set: { on in
                                   guard let id = ctx.clip?.id else { return }
                                   if on { InspectorUIState.shared.canvasOff.remove(id) } else {
                                       InspectorUIState.shared.canvasOff.insert(id)
                                       ctx.store.performInspector(UpdateClip(id, nameKey: "cmd.canvas") { $0.canvas = nil })
                                   }
                               }),
            accessory: AnyView(PillButton(title: tr("inspector.applyToAll")) { applyToAll(ctx) }))
    }

    static func applyToAll(_ ctx: InspectorContext) {
        let canvas = ctx.clip?.canvas
        ctx.store.perform(Edit("cmd.canvas.applyAll") { p in
            guard let mi = p.timeline.mainTrackIndex else { return }
            for i in p.timeline.tracks[mi].clips.indices { p.timeline.tracks[mi].clips[i].canvas = canvas }
        })
        ctx.store.showToast(tr("toast.appliedToAll"))
    }

    var body: some View {
        WithPerceptionTracking {
            let canvas = ctx.clip?.canvas
            let kind = canvas?.kindID ?? "none"
            VStack(alignment: .leading, spacing: 12) {
                Dropdown(items: [("none", tr("canvas.none")), ("blur", tr("canvas.blur")), ("color", tr("canvas.color")), ("style", tr("canvas.style"))],
                         selection: kind) { k in
                    switch k {
                    case "blur": set(.blur(level: 2))
                    case "color": set(.color(.black))
                    case "style": set(.style(id: Registries.effects(in: .canvas).first { $0.groupKey != "library.group.generator" }?.id ?? ""))
                    default: set(nil)
                    }
                }
                switch canvas {
                case .blur(let level): blurSwatches(level)
                case .color(let c): colorGrid(c)
                case .style(let id): styleGrid(id)
                case nil: EmptyView()
                }
            }
        }
    }

    func set(_ c: CanvasBackground?) {
        guard let id = ctx.clip?.id else { return }
        ctx.store.performInspector(UpdateClip(id, nameKey: "cmd.canvas") { $0.canvas = c })
    }

    func blurSwatches(_ level: Int) -> some View {
        let thumb = ctx.asset.flatMap { ThumbnailCache.shared.cached($0, at: ctx.clip?.sourceStart ?? .zero, height: 96) }
        return HStack(spacing: 10) {
            ForEach(Array(CanvasBackground.blurLevels), id: \.self) { l in
                WithPerceptionTracking {
                    Tile(title: tr("canvas.blur.level", l), selected: l == level) { set(.blur(level: l)) } content: {
                        ZStack {
                            if let thumb {
                                Image(decorative: thumb, scale: 1).resizable().aspectRatio(contentMode: .fill)
                                    .blur(radius: Double(l) * 2.2)
                            } else {
                                LinearGradient(colors: [Color(hex: 0x57BECB), Color(hex: 0x8E44AD)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                    .blur(radius: Double(l) * 2.2)
                            }
                        }
                        .frame(width: 62, height: 62).clipped()
                    }
                }
            }
        }
    }

    func colorGrid(_ current: RGBA) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 8), count: 8), alignment: .leading, spacing: 8) {
                ForEach(Self.palette, id: \.self) { hex in
                    WithPerceptionTracking {
                        let c = RGBA(hex: hex)
                        let selected = abs(c.r - current.r) + abs(c.g - current.g) + abs(c.b - current.b) < 0.01
                        RoundedRectangle(cornerRadius: 4).fill(Color(c))
                            .frame(width: 26, height: 26)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? Theme.accent : Color.white.opacity(0.12), lineWidth: selected ? 2 : 1))
                            .contentShape(Rectangle())
                            .onTapGesture { set(.color(c)) }
                    }
                }
            }
            HStack(spacing: 8) {
                Text(loc: "canvas.color.custom").font(Theme.Fonts.row).foregroundStyle(IStyle.label)
                ColorSwatchButton(color: current, eyedropper: ctx.store, testID: "canvas.color") { set(.color($0)) }
            }
        }
    }

    func styleGrid(_ selected: String) -> some View {
        TileGrid {
            ForEach(Registries.effects(in: .canvas).filter { $0.groupKey != "library.group.generator" }) { d in   // W13 library generators hidden
                WithPerceptionTracking {
                    Tile(title: tr(d.nameKey), selected: d.id == selected) { set(.style(id: d.id)) } content: {
                        CanvasStylePreview(id: d.id).frame(width: 62, height: 62)
                    }
                }
            }
        }
    }
}

/// SwiftUI approximations of the canvas style shaders for the tiles (the canvas itself is rendered by Metal).
struct CanvasStylePreview: View {
    let id: String
    var body: some View {
        WithPerceptionTracking {
            switch id.replacingOccurrences(of: "montage.canvas.", with: "") {
            case "sunset": LinearGradient(colors: [Color(hex: 0xFA9E5C), Color(hex: 0x8C3885)], startPoint: .top, endPoint: .bottom)
            case "ocean": LinearGradient(colors: [Color(hex: 0x33BFCC), Color(hex: 0x122B6B)], startPoint: .top, endPoint: .bottom)
            case "mint": RadialGradient(colors: [Color(hex: 0xCCF5DB), Color(hex: 0x6BC7A8)], center: .center, startRadius: 2, endRadius: 50)
            case "stripes":
                Canvas { g, size in
                    g.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0xFAEDB3)))
                    for i in stride(from: -size.height, to: size.width + size.height, by: 7) {
                        var p = Path(); p.move(to: CGPoint(x: i, y: 0)); p.addLine(to: CGPoint(x: i + size.height, y: size.height))
                        g.stroke(p, with: .color(Color(hex: 0xF5D966)), lineWidth: 3.5)
                    }
                }
            case "dots":
                Canvas { g, size in
                    g.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0xFACCD6)))
                    for x in stride(from: 4.0, to: size.width, by: 8) { for y in stride(from: 4.0, to: size.height, by: 8) {
                        g.fill(Path(ellipseIn: CGRect(x: x - 1.6, y: y - 1.6, width: 3.2, height: 3.2)), with: .color(.white))
                    } }
                }
            case "grid":
                Canvas { g, size in
                    g.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0x293352)))
                    for x in stride(from: 0.0, to: size.width, by: 9) { for y in stride(from: 0.0, to: size.height, by: 9) {
                        g.fill(Path(CGRect(x: x + 0.6, y: y + 0.6, width: 7.8, height: 7.8)), with: .color(Color(hex: 0xD9E3F7)))
                    } }
                }
            case "checker":
                Canvas { g, size in
                    for x in 0..<8 { for y in 0..<8 {
                        g.fill(Path(CGRect(x: Double(x) * size.width / 8, y: Double(y) * size.height / 8, width: size.width / 8, height: size.height / 8)),
                               with: .color((x + y) % 2 == 0 ? Color(white: 0.93) : Color(white: 0.8)))
                    } }
                }
            case "waves":
                Canvas { g, size in
                    g.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0x6B5CD6)))
                    for row in stride(from: 4.0, to: size.height, by: 10) {
                        var p = Path(); p.move(to: CGPoint(x: 0, y: row))
                        for x in stride(from: 0.0, through: size.width, by: 2) { p.addLine(to: CGPoint(x: x, y: row + sin(x / 5) * 2.5)) }
                        g.stroke(p, with: .color(Color(hex: 0xB385F2)), lineWidth: 3)
                    }
                }
            default: Color.gray
            }
        }
    }
}
