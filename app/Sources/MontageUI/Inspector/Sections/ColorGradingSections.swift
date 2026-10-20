import SwiftUI
import AppKit
import MontageCore
import MontageEffects
import MontageEngine
import Perception

// Adjust ▸ HSL · Curves · Color wheel sub-tabs (UX.md §5.1 Adjust, [37] [38] [39] [41]) and Adjust ▸ Basic ▸
// ☐ Auto adjust. Each control edits one descriptor instance on the clip (created on the first edit, like Basic):
// `BuiltinColor.hsl` / `.curves` / `.colorWheels`, `AutoColor.descriptor`. Owned by W4 (colour content).

@MainActor
enum ColorGradingInspector {
    /// Descriptors with their own sub-tab (hidden from the generic "other adjustments" blocks).
    static let ownIDs: Set<String> = [BuiltinColor.hsl.id, BuiltinColor.curves.id, BuiltinColor.colorWheels.id, AutoColor.descriptor.id]

    static let subTabs: [InspectorSubTab] = [
        InspectorSubTab(id: "hsl", titleKey: "inspector.sub.hsl", order: 1),
        InspectorSubTab(id: "curves", titleKey: "inspector.sub.curves", order: 2),
        InspectorSubTab(id: "wheels", titleKey: "inspector.sub.wheels", order: 3),
    ]

    static let sections: [InspectorSection] = [
        // Adjust ▸ Basic ▸ Auto adjust is W10's AI colour section (ColorLookUI, "adjust.auto"); `AutoAdjustSection` below is
        // kept for the stand-alone `AutoColor` effect but no longer registered (it duplicated that section).
        InspectorSection(id: "adjust.hsl", tab: "adjust", subTab: "hsl", order: 0, titleKey: "inspector.hsl.section",
                         chrome: { chrome($0, BuiltinColor.hsl) }) { AnyView(HSLSection(ctx: $0)) },
        InspectorSection(id: "adjust.curves", tab: "adjust", subTab: "curves", order: 0, titleKey: "inspector.curves.section",
                         chrome: { chrome($0, BuiltinColor.curves, keyframes: false) }) { AnyView(CurvesSection(ctx: $0)) },
        InspectorSection(id: "adjust.wheels", tab: "adjust", subTab: "wheels", order: 0, titleKey: "adjust.wheels",
                         chrome: { chrome($0, BuiltinColor.colorWheels) }) { AnyView(ColorWheelsSection(ctx: $0)) },
    ]

    static func instance(_ c: Clip?, _ d: EffectDescriptor) -> EffectInstance? { c?.effects.first { $0.typeID == d.id } }

    /// Edits the clip's instance of `d` (added on first edit). Live inside a gesture, else one undo step.
    static func edit(_ ctx: InspectorContext, _ d: EffectDescriptor, _ name: String = "cmd.adjust", _ body: @escaping (inout EffectInstance) -> Void) {
        guard let id = ctx.clip?.id else { return }
        Bind.apply(ctx.store, id, name) { c in
            if !c.effects.contains(where: { $0.typeID == d.id }) { c.effects.append(d.makeInstance()) }
            if let i = c.effects.firstIndex(where: { $0.typeID == d.id }) { body(&c.effects[i]) }
        }
    }

    static func value(_ c: Clip?, _ d: EffectDescriptor, _ key: String, at t: Time = .zero) -> Double {
        if let i = instance(c, d), let v = c?.value(.effect(i.id, key), at: t)?.scalar { return v }
        if case .scalar(_, _, let def)? = d.params.first(where: { $0.key == key })?.kind { return def }
        return 0
    }

    /// Header chrome: ☑ enable, ↺ reset to defaults (clears keyframes), ‹◇› over every parameter.
    static func chrome(_ ctx: InspectorContext, _ d: EffectDescriptor, keyframes: Bool = true) -> InspectorSectionChrome {
        let store = ctx.store
        let inst = instance(ctx.clip, d)
        return InspectorSectionChrome(
            isEnabled: Binding.perceived(get: { inst?.isEnabled ?? true }, set: { v in
                guard let id = ctx.clip?.id, inst != nil else { return }
                let tid = d.id   // by type: the same panel on every selected clip (C2)
                store.performInspector(UpdateClip(id, nameKey: "cmd.adjust") { c in
                    if let i = c.effects.firstIndex(where: { $0.typeID == tid }) { c.effects[i].isEnabled = v }
                })
            }),
            reset: {
                guard let id = ctx.clip?.id, inst != nil else { return }
                let tid = d.id
                store.performInspector(UpdateClip(id, nameKey: "cmd.adjust") { c in
                    for e in c.effects where e.typeID == tid { c.clearKeyframes(c.effectParamKeys(e.id)) }
                    c.effects.removeAll { $0.typeID == tid }
                })
            },
            keyframeKeys: keyframes ? inst.map { i in d.params.filter { if case .scalar = $0.kind { return true }; return false }
                .map { ParamKey.effect(i.id, $0.key) } } ?? [] : nil)
    }

    /// One slider row on a scalar param of `d` (keyframeable, display ×100, bipolar when the range is).
    static func row(_ ctx: InspectorContext, _ d: EffectDescriptor, key: String, label: String, gradient: [Color]? = nil) -> ClipParamRow {
        let spec = d.params.first { $0.key == key }!
        guard case .scalar(let lo, let hi, let def) = spec.kind else { fatalError("scalar param expected") }
        let k = spec.displayScale
        let pkey = instance(ctx.clip, d).map { ParamKey.effect($0.id, key) }
        return ClipParamRow(
            ctx: ctx, label: label,
            spec: RowSpec(range: lo * k...hi * k, origin: lo < 0 ? 0 : nil, gradient: gradient, step: 1, format: Fmt.int),
            get: { c, t in
                guard let i = instance(c, d) else { return def * k }
                return (c.value(.effect(i.id, key), at: t)?.scalar ?? def) * k
            },
            set: { c, v, t in
                if instance(c, d) == nil { c.effects.append(d.makeInstance()) }
                guard let i = instance(c, d) else { return }
                c.setValue(.effect(i.id, key), .scalar(v / k), at: t)
            },
            dependsOnTime: { c in pkey.map { c.hasKeyframes($0) } ?? false },
            keyframeKeys: pkey.map { [$0] } ?? [], gestureName: "cmd.adjust")
    }
}

// MARK: - HSL

/// HSL: 8 colour rings (selected = filled), then Hue / Saturation / Lightness for the selected range (−100…100).
struct HSLSection: View {
    let ctx: InspectorContext
    @State private var range = 0
    static let colors: [Color] = [Color(hex: 0xE5352B), Color(hex: 0xF08A24), Color(hex: 0xF2D230), Color(hex: 0x3FBF4A),
                                  Color(hex: 0x35C6D3), Color(hex: 0x2F6BE0), Color(hex: 0x8A4FE0), Color(hex: 0xE04FC4)]

    var body: some View {
        WithPerceptionTracking {
            let d = BuiltinColor.hsl
            let r = BuiltinColor.hslRanges[range]
            let c = Self.colors[range]
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    // eyedropper (UX.md §5.1 HSL): pick a colour on the video → select the nearest colour ring
                    SmallIconButton(symbol: "eyedropper", help: tr("inspector.hsl.pickHelp"), size: 13) {
                        ctx.store.pickCanvasColor(disabling: nil) { c in range = Self.nearestRange(c) }
                    }
                    .testID("hsl.pick")
                    ForEach(0..<8, id: \.self) { i in
                        WithPerceptionTracking {
                            let edited = abs(ColorGradingInspector.value(ctx.clip, d, "\(BuiltinColor.hslRanges[i].key).hue"))
                                + abs(ColorGradingInspector.value(ctx.clip, d, "\(BuiltinColor.hslRanges[i].key).sat"))
                                + abs(ColorGradingInspector.value(ctx.clip, d, "\(BuiltinColor.hslRanges[i].key).light")) > 1e-4
                            Button { range = i } label: {
                                ZStack {
                                    Circle().strokeBorder(Self.colors[i], lineWidth: 3)
                                    if i == range { Circle().fill(Self.colors[i]).padding(5) }
                                    if edited && i != range { Circle().fill(Self.colors[i]).frame(width: 5, height: 5) }
                                }
                                .frame(width: 26, height: 26).contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help(tr("hsl.range.\(BuiltinColor.hslRanges[i].key)"))
                            .testID("hsl.range.\(BuiltinColor.hslRanges[i].key)")
                        }
                    }
                }
                .padding(.vertical, 4)
                ColorGradingInspector.row(ctx, d, key: "\(r.key).hue", label: tr("inspector.hsl.hue"),
                                          gradient: [Self.colors[(range + 7) % 8], c, Self.colors[(range + 1) % 8]])
                ColorGradingInspector.row(ctx, d, key: "\(r.key).sat", label: tr("inspector.hsl.saturation"), gradient: [Color(white: 0.45), c])
                ColorGradingInspector.row(ctx, d, key: "\(r.key).light", label: tr("inspector.hsl.lightness"), gradient: [.black, c, .white])
            }
        }
    }
}

extension HSLSection {
    /// Index in `BuiltinColor.hslRanges` of the range whose centre hue is nearest to `c`'s hue.
    nonisolated static func nearestRange(_ c: RGBA) -> Int {
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b), d = mx - mn
        guard d > 1e-6 else { return 0 }
        var h: Double
        if mx == c.r { h = ((c.g - c.b) / d).truncatingRemainder(dividingBy: 6) }
        else if mx == c.g { h = (c.b - c.r) / d + 2 }
        else { h = (c.r - c.g) / d + 4 }
        h = (h * 60 + 360).truncatingRemainder(dividingBy: 360)
        let dist: (Double) -> Double = { let x = abs($0 - h).truncatingRemainder(dividingBy: 360); return min(x, 360 - x) }
        return BuiltinColor.hslRanges.indices.min { dist(BuiltinColor.hslRanges[$0].hue) < dist(BuiltinColor.hslRanges[$1].hue) } ?? 0
    }
}

// MARK: - Curves

/// Curves: four stacked editors (Brightness, R, G, B). Click to add a point, drag to move, double-click to remove.
struct CurvesSection: View {
    let ctx: InspectorContext
    static let channels: [(key: String, color: Color)] = [("luma", .white), ("red", Color(hex: 0xE5484D)),
                                                         ("green", Color(hex: 0x46C35B)), ("blue", Color(hex: 0x4C8DF6))]
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Self.channels, id: \.key) { ch in WithPerceptionTracking { CurveEditor(ctx: ctx, channel: ch.key, color: ch.color).testID("curves.\(ch.key)") } }
                HintText(text: tr("inspector.curves.hint"))
            }
        }
    }
}

struct CurveEditor: View {
    let ctx: InspectorContext
    let channel: String
    let color: Color
    @State private var dragIndex: Int?
    @State private var dragging = false

    /// CapCut starts every curve as the bare diagonal: an untouched (identity) curve shows its two endpoints only.
    static let endpoints: [ColorCurveMath.Point] = [(0, 0), (1, 1)]
    static func isIdentity(_ pts: [ColorCurveMath.Point]) -> Bool { pts.allSatisfy { abs($0.x - $0.y) < 1e-6 } }
    static func displayed(_ pts: [ColorCurveMath.Point]) -> [ColorCurveMath.Point] { isIdentity(pts) ? endpoints : pts }

    var points: [ColorCurveMath.Point] {
        Self.displayed(ColorCurveMath.points(ColorGradingInspector.instance(ctx.clip, BuiltinColor.curves)?.params ?? [:], channel: channel))
    }
    var isIdentity: Bool { Self.isIdentity(points) }

    var body: some View {
        WithPerceptionTracking {
            let pts = points
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(verbatim: tr("curves.\(channel)")).font(Theme.Fonts.row).foregroundStyle(IStyle.label)
                    Spacer()
                    SmallIconButton(symbol: "eyedropper", help: tr("inspector.curves.pickHelp"), size: 12) { pickColor() }
                        .testID("curves.\(channel).pick")
                    SmallIconButton(symbol: "arrow.counterclockwise", help: tr("inspector.reset"), enabled: !isIdentity, size: 12) { write(Self.endpoints, live: false) }
                }
                GeometryReader { geo in
                    WithPerceptionTracking {
                        let side = geo.size.width
                        ZStack {
                            Canvas { g, size in draw(g, size, pts) }
                                .background(IStyle.graph, in: RoundedRectangle(cornerRadius: 4))
                            ForEach(Array(pts.enumerated()), id: \.offset) { i, p in
                                WithPerceptionTracking {
                                    Circle().fill(dragIndex == i ? color : Color.black).overlay(Circle().stroke(color, lineWidth: 1.5))
                                        .frame(width: 10, height: 10)
                                        .position(x: p.x * side, y: (1 - p.y) * side)
                                        .allowsHitTesting(false)
                                }
                            }
                        }
                        .frame(width: side, height: side)
                        .contentShape(Rectangle())
                        .gesture(drag(side: side))
                        .onTapGesture(count: 2, coordinateSpace: .local) { loc in removePoint(near: loc, side: side) }
                        .onTapGesture(count: 1, coordinateSpace: .local) { loc in addPoint(at: loc, side: side) }
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
            }
        }
    }

    func draw(_ g: GraphicsContext, _ size: CGSize, _ pts: [ColorCurveMath.Point]) {
        var grid = Path()
        for k in 1..<4 {
            let v = size.width * CGFloat(k) / 4
            grid.move(to: CGPoint(x: v, y: 0)); grid.addLine(to: CGPoint(x: v, y: size.height))
            grid.move(to: CGPoint(x: 0, y: v)); grid.addLine(to: CGPoint(x: size.width, y: v))
        }
        g.stroke(grid, with: .color(Color.white.opacity(0.08)), lineWidth: 1)
        var diag = Path(); diag.move(to: CGPoint(x: 0, y: size.height)); diag.addLine(to: CGPoint(x: size.width, y: 0))
        g.stroke(diag, with: .color(color.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        var curve = Path()
        let n = 96
        for s in 0...n {
            let x = Double(s) / Double(n)
            let pt = CGPoint(x: x * size.width, y: (1 - ColorCurveMath.evaluate(pts, x)) * size.height)
            if s == 0 { curve.move(to: pt) } else { curve.addLine(to: pt) }
        }
        g.stroke(curve, with: .color(color), lineWidth: 1.6)
    }

    func unit(_ loc: CGPoint, _ side: CGFloat) -> ColorCurveMath.Point {
        (min(max(Double(loc.x / side), 0), 1), min(max(1 - Double(loc.y / side), 0), 1))
    }

    func nearest(_ loc: CGPoint, side: CGFloat) -> Int? {
        let pts = points
        let hit = pts.enumerated().map { (i: $0.offset, d: hypot($0.element.x * side - loc.x, (1 - $0.element.y) * side - loc.y)) }
            .min { $0.d < $1.d }
        return hit.flatMap { $0.d <= 10 ? $0.i : nil }
    }

    func addPoint(at loc: CGPoint, side: CGFloat) {
        var pts = points
        guard nearest(loc, side: side) == nil, pts.count < ColorCurveMath.maxPoints else { return }
        let u = unit(loc, side)
        guard !pts.contains(where: { abs($0.x - u.x) < 0.02 }) else { return }
        pts.append(u)
        write(pts, live: false)
    }

    /// Channel level of a sampled colour (Rec.709 luma for the Brightness curve).
    static func level(_ c: RGBA, channel: String) -> Double {
        switch channel {
        case "red": return c.r
        case "green": return c.g
        case "blue": return c.b
        default: return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
        }
    }

    /// Eyedropper: adds a point on the curve at the sampled colour's level (CapCut [38]), ready to drag.
    static func pointAdding(level x: Double, to pts: [ColorCurveMath.Point]) -> [ColorCurveMath.Point]? {
        guard pts.count < ColorCurveMath.maxPoints, x > 0.01, x < 0.99, !pts.contains(where: { abs($0.x - x) < 0.02 }) else { return nil }
        return (pts + [(x, ColorCurveMath.evaluate(pts, x))]).sorted { $0.x < $1.x }
    }

    func pickColor() {
        let ch = channel
        // canvas eyedropper (loupe over the video, CL-024) instead of the screen-wide system sampler
        ctx.store.pickCanvasColor { rgba in
            if let pts = Self.pointAdding(level: Self.level(rgba, channel: ch), to: points) { write(pts, live: false) }
        }
    }

    func removePoint(near loc: CGPoint, side: CGFloat) {
        var pts = points
        guard let i = nearest(loc, side: side), i != 0, i != pts.count - 1, pts.count > 2 else { return }
        pts.remove(at: i)
        write(pts, live: false)
    }

    func drag(side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { v in
                var pts = points
                if !dragging {
                    dragging = true
                    ctx.store.beginGesture("cmd.adjust")
                    if let i = nearest(v.startLocation, side: side) { dragIndex = i }
                    else if pts.count < ColorCurveMath.maxPoints {
                        pts.append(unit(v.startLocation, side)); pts.sort { $0.x < $1.x }
                        dragIndex = pts.firstIndex { abs($0.x - unit(v.startLocation, side).x) < 1e-9 }
                    }
                }
                guard let i = dragIndex, i < pts.count else { return }
                var u = unit(v.location, side)
                let lo = i == 0 ? 0 : pts[i - 1].x + 0.01, hi = i == pts.count - 1 ? 1 : pts[i + 1].x - 0.01
                u.x = min(max(u.x, lo), max(lo, hi))
                pts[i] = u
                write(pts, live: true)
            }
            .onEnded { _ in
                if dragging { ctx.store.endGesture() }
                dragging = false; dragIndex = nil
            }
    }

    func write(_ pts: [ColorCurveMath.Point], live: Bool) {
        let values = ColorCurveMath.params(pts, channel: channel)
        ColorGradingInspector.edit(ctx, BuiltinColor.curves) { inst in
            for (k, v) in values { inst.params[k] = v }
        }
    }
}

// MARK: - Color wheels

/// Color wheel: mode (Primary / Log), Strength, four wheels with a draggable puck (hue + amount), a luma slider,
/// a per-wheel ↺ and the R/G/B offset read-out.
struct ColorWheelsSection: View {
    let ctx: InspectorContext
    var body: some View {
        WithPerceptionTracking {
            let d = BuiltinColor.colorWheels
            let inst = ColorGradingInspector.instance(ctx.clip, d)
            let mode: Int = { if case .choice(let m)? = inst?.params["mode"] { return m }; return 0 }()
            VStack(alignment: .leading, spacing: 10) {
                InlineRow(label: tr("wheels.mode")) {
                    Dropdown(items: [(0, tr("wheels.mode.primary")), (1, tr("wheels.mode.log"))], selection: mode) { m in
                        ColorGradingInspector.edit(ctx, d) { $0.params["mode"] = .choice(m) }
                    }
                }
                ColorGradingInspector.row(ctx, d, key: "strength", label: tr("fx.param.strength"))
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 14) {
                    ForEach(BuiltinColor.wheelNames, id: \.self) { w in
                        WithPerceptionTracking {
                            WheelControl(ctx: ctx, wheel: w, title: tr(mode == 1 ? "wheels.log.\(w)" : "wheels.primary.\(w)")).testID("wheels.\(w)")
                        }
                    }
                }
            }
        }
    }
}

struct WheelControl: View {
    let ctx: InspectorContext
    let wheel: String
    let title: String
    @State private var active = false
    static let size: CGFloat = 88

    func v(_ k: String) -> Double { ColorGradingInspector.value(ctx.clip, BuiltinColor.colorWheels, "\(wheel).\(k)", at: ctx.localTime) }

    var body: some View {
        WithPerceptionTracking {
            let hue = v("hue"), amount = v("amount"), luma = v("luma")
            let rgb = Self.offset(hue: hue, amount: amount, luma: luma)
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    Text(verbatim: title).font(.system(size: 11, weight: .medium)).foregroundStyle(IStyle.label).lineLimit(1)
                    Spacer(minLength: 0)
                    SmallIconButton(symbol: "arrow.counterclockwise", help: tr("inspector.reset"),
                                    enabled: amount > 1e-4 || abs(luma) > 1e-4, size: 11) { reset() }
                }
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(AngularGradient(colors: (0...12).map { Color(hue: Double($0) / 12, saturation: 0.85, brightness: 0.85) },
                                                      center: .center, startAngle: .degrees(0), endAngle: .degrees(360)))
                        Circle().fill(RadialGradient(colors: [Color(white: 0.55), Color(white: 0.55).opacity(0)], center: .center,
                                                     startRadius: 0, endRadius: Self.size / 2))
                        Circle().strokeBorder(Color.black.opacity(0.5), lineWidth: 1)
                        Path { p in
                            p.move(to: CGPoint(x: Self.size / 2 - 4, y: Self.size / 2)); p.addLine(to: CGPoint(x: Self.size / 2 + 4, y: Self.size / 2))
                            p.move(to: CGPoint(x: Self.size / 2, y: Self.size / 2 - 4)); p.addLine(to: CGPoint(x: Self.size / 2, y: Self.size / 2 + 4))
                        }
                        .stroke(Color.white.opacity(0.5), lineWidth: 1)
                        Circle().fill(Color.white).frame(width: 10, height: 10).shadow(radius: 1)
                            .offset(x: cos(hue * .pi / 180) * amount * Self.size / 2, y: sin(hue * .pi / 180) * amount * Self.size / 2)
                    }
                    .frame(width: Self.size, height: Self.size)
                    .contentShape(Circle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { g in puck(g.location) }.onEnded { _ in end() })
                    .onTapGesture(count: 2) { reset() }
                    LumaBar(value: luma, height: Self.size) { set(["luma": $0], live: true) } onEnd: { end() }
                }
                Text(verbatim: String(format: "%.2f  %.2f  %.2f", rgb.0, rgb.1, rgb.2))
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(IStyle.caption)
            }
        }
    }

    /// Mirror of the shader's `wheel()` (chroma tint + luma offset).
    static func offset(hue: Double, amount: Double, luma: Double) -> (Double, Double, Double) {
        let h = (hue / 360).truncatingRemainder(dividingBy: 1)
        let c = Color(hue: h, saturation: 1, brightness: 1)
        let ns = NSColor(c).usingColorSpace(.deviceRGB) ?? .white
        let r = Double(ns.redComponent), g = Double(ns.greenComponent), b = Double(ns.blueComponent)
        let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return ((r - l) * amount * 0.5 + luma * 0.5, (g - l) * amount * 0.5 + luma * 0.5, (b - l) * amount * 0.5 + luma * 0.5)
    }

    func puck(_ loc: CGPoint) {
        let dx = Double(loc.x - Self.size / 2), dy = Double(loc.y - Self.size / 2)
        let r = min(hypot(dx, dy) / Double(Self.size / 2), 1)
        var deg = atan2(dy, dx) * 180 / .pi
        if deg < 0 { deg += 360 }
        set(["hue": deg, "amount": r], live: true)
    }

    func set(_ values: [String: Double], live: Bool) {
        if live && !active { active = true; ctx.store.beginGesture("cmd.adjust") }
        guard let clip = ctx.clip else { return }
        let d = BuiltinColor.colorWheels, w = wheel
        let t = Bind.local(ctx.store, clip)
        Bind.apply(ctx.store, clip.id, "cmd.adjust") { c in
            if !c.effects.contains(where: { $0.typeID == d.id }) { c.effects.append(d.makeInstance()) }
            guard let i = c.effects.firstIndex(where: { $0.typeID == d.id }) else { return }
            let iid = c.effects[i].id
            for (k, v) in values { c.setValue(.effect(iid, "\(w).\(k)"), .scalar(v), at: t) }
        }
    }

    func end() { if active { ctx.store.endGesture() }; active = false }

    func reset() {
        guard let clip = ctx.clip, let inst = ColorGradingInspector.instance(clip, BuiltinColor.colorWheels) else { return }
        let iid = inst.id, w = wheel
        ctx.store.performInspector(UpdateClip(clip.id, nameKey: "cmd.adjust") { c in
            let keys = ["hue", "amount", "luma"].map { ParamKey.effect(iid, "\(w).\($0)") }
            c.clearKeyframes(keys)
            if let i = c.effects.firstIndex(where: { $0.id == iid }) {
                c.effects[i].params["\(w).hue"] = .scalar(0); c.effects[i].params["\(w).amount"] = .scalar(0); c.effects[i].params["\(w).luma"] = .scalar(0)
            }
        })
    }
}

/// Thin vertical luminance slider next to a wheel (−1 bottom … +1 top, 0 in the middle).
struct LumaBar: View {
    let value: Double
    let height: CGFloat
    let onChange: (Double) -> Void
    let onEnd: () -> Void
    var body: some View {
        WithPerceptionTracking {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 3).fill(LinearGradient(colors: [.white, Color(white: 0.35), .black], startPoint: .top, endPoint: .bottom))
                    .frame(width: 6)
                Capsule().fill(Color.white).frame(width: 12, height: 5).shadow(radius: 1)
                    .offset(y: CGFloat(1 - (value + 1) / 2) * (height - 5))
            }
            .frame(width: 14, height: height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                onChange(min(max(1 - Double(g.location.y / height) * 2, -1), 1))
            }.onEnded { _ in onEnd() })
        }
    }
}

// MARK: - Auto adjust

/// ☐ Auto adjust: checking it analyses the frame under the playhead (off-main) and adds the correction; Strength mixes it.
struct AutoAdjustSection: View {
    let ctx: InspectorContext

    static func chrome(_ ctx: InspectorContext) -> InspectorSectionChrome {
        let inst = ColorGradingInspector.instance(ctx.clip, AutoColor.descriptor)
        return InspectorSectionChrome(
            isEnabled: Binding.perceived(get: { inst?.isEnabled ?? false }, set: { on in
                guard let clip = ctx.clip else { return }
                if on && inst == nil { run(ctx, clip) }
                else if let iid = inst?.id {
                    ctx.store.performInspector(UpdateClip(clip.id, nameKey: "cmd.autoAdjust") { c in
                        if let i = c.effects.firstIndex(where: { $0.id == iid }) { c.effects[i].isEnabled = on }
                    })
                }
            }),
            reset: inst == nil ? nil : {
                guard let clip = ctx.clip else { return }
                run(ctx, clip)
            })
    }

    /// Analyses the clip's source frame at the playhead and stores the result (one undo step). Returns the task
    /// (tests await it).
    @discardableResult
    static func run(_ ctx: InspectorContext, _ clip: Clip) -> Task<Void, Never>? {
        guard let asset = ctx.asset else { return nil }
        let store = ctx.store, t = store.transport.playhead, id = clip.id
        return Task {
            guard let img = try? await AutoAdjustAnalyzer.frame(of: clip, asset: asset, at: t) else {
                store.showToast(tr("autoAdjust.failed"), error: true); return
            }
            let values = await AutoAdjustAnalyzer.analyze(img)
            store.performInspector(UpdateClip(id, nameKey: "cmd.autoAdjust") { c in
                let d = AutoColor.descriptor
                var inst = c.effects.first { $0.typeID == d.id } ?? d.makeInstance()
                for (k, v) in values { inst.params[k] = .scalar(v) }
                inst.isEnabled = true
                if let i = c.effects.firstIndex(where: { $0.typeID == d.id }) { c.effects[i] = inst }
                else { c.effects.insert(inst, at: 0) }
            })
        }
    }

    var body: some View {
        WithPerceptionTracking {
            if ColorGradingInspector.instance(ctx.clip, AutoColor.descriptor)?.isEnabled == true {
                ColorGradingInspector.row(ctx, AutoColor.descriptor, key: "strength", label: tr("fx.param.strength"))
            } else {
                HintText(text: tr("autoAdjust.hint"))
            }
        }
    }
}
