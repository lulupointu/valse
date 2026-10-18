import SwiftUI
import MontageCore
import MontageEffects
import MontageEngine

/// Built-in inspector tabs & sections. A feature adds its UI with one `InspectorSection` (here or via
/// `InspectorRegistry.register`) — the panel, tabs and layout pick it up automatically.
@MainActor
enum BuiltinInspector {
    static let tabs: [InspectorTab] = [
        InspectorTab(id: "details", titleKey: "inspector.tab.details", order: -1) { !$0.hasSelection },
        InspectorTab(id: "text", titleKey: "inspector.tab.text", order: 0) { $0.isText },
        InspectorTab(id: "video", titleKey: "inspector.tab.video", order: 1) { $0.isVisualClip && !$0.isText && !$0.isAdjustment },
        InspectorTab(id: "audio", titleKey: "inspector.tab.audio", order: 2) { $0.hasAudio },
        InspectorTab(id: "speed", titleKey: "inspector.tab.speed", order: 3) { $0.asset.map { $0.kind != .image } ?? false },
        InspectorTab(id: "animation", titleKey: "inspector.tab.animation", order: 4) { $0.isVisualClip && !$0.isAdjustment },
        InspectorTab(id: "adjust", titleKey: "inspector.tab.adjust", order: 5) { $0.isVisualClip },
    ]

    static let sections: [InspectorSection] = [
        InspectorSection(id: "details.project", tab: "details", order: 0, titleKey: nil) { AnyView(DetailsSection(store: $0.store)) },

        InspectorSection(id: "text.content", tab: "text", order: 0, titleKey: "inspector.text.basic") { AnyView(TextSection(ctx: $0)) },
        InspectorSection(id: "text.transform", tab: "text", order: 1, titleKey: "inspector.transform") { AnyView(TransformSection(ctx: $0)) },

        InspectorSection(id: "video.transform", tab: "video", order: 0, titleKey: "inspector.transform") { AnyView(TransformSection(ctx: $0)) },
        InspectorSection(id: "video.blend", tab: "video", order: 1, titleKey: "inspector.blend") { AnyView(BlendSection(ctx: $0)) },
        InspectorSection(id: "video.mask", tab: "video", order: 2, titleKey: "inspector.mask") { AnyView(MaskSection(ctx: $0)) },

        InspectorSection(id: "audio.basic", tab: "audio", order: 0, titleKey: "inspector.audio.basic") { AnyView(AudioSection(ctx: $0)) },
        InspectorSection(id: "speed.normal", tab: "speed", order: 0, titleKey: "inspector.speed.normal") { AnyView(SpeedSection(ctx: $0)) },
        InspectorSection(id: "animation.pick", tab: "animation", order: 0, titleKey: nil) { AnyView(AnimationSection(ctx: $0)) },
        InspectorSection(id: "adjust.lut", tab: "adjust", order: -1, titleKey: "inspector.lut") { AnyView(LUTSection(ctx: $0)) },
        InspectorSection(id: "adjust.stack", tab: "adjust", order: 0, titleKey: nil) { AnyView(EffectStackSection(ctx: $0)) },
    ]
}

// MARK: Sections

struct TransformSection: View {
    let ctx: InspectorContext
    var body: some View {
        let canvas = ctx.store.project.settings.canvasSize
        VStack(alignment: .leading, spacing: Theme.Metrics.rowSpacing) {
            Bind.value(ctx, tr("prop.scale"), range: 0.01...4, display: Fmt.percent, gestureName: "cmd.transform",
                       get: { c in c.value(.scale, at: ctx.localTime)?.vec2?.x ?? 1 },
                       set: { c, v in
                           let local = (ctx.store.transport.playhead - c.start).clamped(.zero, c.duration)
                           c.setValue(.scale, .vec2(Vec2(v, v)), at: local)
                       })
            HStack(spacing: 10) {
                Bind.value(ctx, tr("prop.positionX"), range: -canvas.width...canvas.width, display: Fmt.int, gestureName: "cmd.transform",
                           get: { c in (c.value(.position, at: ctx.localTime)?.vec2?.x ?? 0) * canvas.width },
                           set: { c, v in
                               let local = (ctx.store.transport.playhead - c.start).clamped(.zero, c.duration)
                               var p = c.value(.position, at: local)?.vec2 ?? .zero; p.x = v / canvas.width
                               c.setValue(.position, .vec2(p), at: local)
                           })
                Bind.value(ctx, tr("prop.positionY"), range: -canvas.height...canvas.height, display: Fmt.int, gestureName: "cmd.transform",
                           get: { c in -(c.value(.position, at: ctx.localTime)?.vec2?.y ?? 0) * canvas.height },
                           set: { c, v in
                               let local = (ctx.store.transport.playhead - c.start).clamped(.zero, c.duration)
                               var p = c.value(.position, at: local)?.vec2 ?? .zero; p.y = -v / canvas.height
                               c.setValue(.position, .vec2(p), at: local)
                           })
            }
            Bind.slider(ctx, tr("prop.rotation"), key: .rotation, range: -360...360, display: Fmt.degrees, gestureName: "cmd.transform")
            HStack(spacing: 8) {
                if let k = Bind.keyframeState(ctx, .position) { Text(loc: "inspector.keyframePosition").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary); KeyframeButton(state: k) }
                Spacer()
                Button { Bind.apply(ctx.store, ctx.clip!.id, "cmd.transform") { $0.transform.flipH.toggle() } } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    .buttonStyle(.plain).help(tr("inspector.flipH"))
                Button { Bind.apply(ctx.store, ctx.clip!.id, "cmd.transform") { $0.transform.flipV.toggle() } } label: { Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
                    .buttonStyle(.plain).help(tr("inspector.flipV"))
                Button(tr("inspector.reset")) {
                    Bind.apply(ctx.store, ctx.clip!.id, "cmd.transform") { c in
                        c.transform = Transform()
                        for k in [ParamKey.position, .scale, .rotation] { c.keyframes[k.raw] = nil }
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .foregroundStyle(Theme.textSecondary)
        }
    }
}

struct BlendSection: View {
    let ctx: InspectorContext
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.rowSpacing) {
            HStack {
                Text(loc: "inspector.blendMode").font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary)
                Spacer()
                Picker("", selection: Binding(get: { ctx.clip?.blendMode ?? .normal },
                                              set: { m in Bind.apply(ctx.store, ctx.clip!.id, "cmd.blend") { $0.blendMode = m } })) {
                    ForEach(BlendMode.allCases, id: \.self) { Text(loc: $0.nameKey).tag($0) }
                }
                .labelsHidden().frame(width: 150)
            }
            Bind.slider(ctx, tr("prop.opacity"), key: .opacity, range: 0...1, display: Fmt.percent, gestureName: "cmd.opacity")
        }
    }
}

struct MaskSection: View {
    let ctx: InspectorContext
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.rowSpacing) {
            HStack(spacing: 8) {
                maskTile(nil, "nosign", tr("inspector.mask.none"))
                ForEach(MaskShape.allCases, id: \.self) { s in
                    maskTile(s, ["linear": "line.diagonal", "mirror": "rectangle.split.1x2", "circle": "circle", "rectangle": "rectangle"][s.rawValue]!, tr(s.nameKey))
                }
            }
            if ctx.clip?.mask != nil {
                Bind.slider(ctx, tr("prop.maskFeather"), key: .maskFeather, range: 0...1, display: Fmt.percent)
                Bind.slider(ctx, tr("prop.maskRotation"), key: .maskRotation, range: -180...180, display: Fmt.degrees)
                ToggleRow(tr("inspector.mask.invert"), isOn: Binding(get: { ctx.clip?.mask?.inverted ?? false },
                                                                   set: { v in Bind.apply(ctx.store, ctx.clip!.id, "cmd.editClip") { $0.mask?.inverted = v } }))
            }
        }
    }

    func maskTile(_ shape: MaskShape?, _ symbol: String, _ title: String) -> some View {
        let selected = ctx.clip?.mask?.shape == shape
        return VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 16))
                .frame(width: 44, height: 44)
                .background(Theme.segmentSelected, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Theme.accent : .clear, lineWidth: 2))
            Text(verbatim: title).font(.system(size: 10)).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .onTapGesture {
            Bind.apply(ctx.store, ctx.clip!.id, "cmd.editClip") { c in
                c.mask = shape.map { Mask(shape: $0, size: $0 == .mirror ? Vec2(1, 0.4) : Vec2(0.5, 0.5)) }
            }
        }
    }
}

struct AudioSection: View {
    let ctx: InspectorContext
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.rowSpacing) {
            // UI works in dB (−60…+20), model in linear gain.
            Bind.slider(ctx, tr("prop.volume"), key: .volume, range: -60...20, display: { $0 <= -59.9 ? "-∞dB" : String(format: "%.1fdB", $0) },
                        toUI: { max(-60, AudioProps.decibels($0)) }, fromUI: { $0 <= -59.9 ? 0 : pow(10, $0 / 20) }, gestureName: "cmd.volume")
            let half = (ctx.clip?.duration.seconds ?? 2) / 2
            Bind.value(ctx, tr("inspector.fadeIn"), range: 0...max(half, 0.1), display: Fmt.seconds, gestureName: "cmd.volume",
                       get: { $0.audio.fadeIn.seconds }, set: { c, v in c.audio.fadeIn = Time(v) })
            Bind.value(ctx, tr("inspector.fadeOut"), range: 0...max(half, 0.1), display: Fmt.seconds, gestureName: "cmd.volume",
                       get: { $0.audio.fadeOut.seconds }, set: { c, v in c.audio.fadeOut = Time(v) })
        }
    }
}

struct SpeedSection: View {
    let ctx: InspectorContext
    var body: some View {
        let store = ctx.store
        let clip = ctx.clip
        VStack(alignment: .leading, spacing: Theme.Metrics.rowSpacing) {
            // log scale 0.1× … 100×
            SliderRow(tr("inspector.speed"), range: -1...2, display: { Fmt.speed(pow(10, $0)) },
                      parse: { Double($0.filter { "0123456789.".contains($0) }).map { log10(max(0.1, min(100, $0))) } },
                      get: { log10(max(0.1, clip?.speed.averageRate ?? 1)) },
                      set: { v in
                          guard let id = clip?.id else { return }
                          let s = Speed.constant((pow(10, v) * 100).rounded() / 100)
                          store.updateGesture { p in try TimelineOps.setSpeed(id, s, in: &p.timeline) }
                      },
                      onBegin: { store.beginGesture("cmd.speed") }, onEnd: { store.endGesture() })
            if let clip {
                InfoRow(tr("inspector.duration"), "\(Fmt.seconds(clip.sourceDuration.seconds)) → \(Fmt.seconds(clip.duration.seconds))")
                ToggleRow(tr("inspector.changePitch"), isOn: Binding(get: { !(clip.audio.preservePitch) },
                                                                   set: { v in Bind.apply(store, clip.id, "cmd.speed") { $0.audio.preservePitch = !v } }))
            }
        }
    }
}

struct AnimationSection: View {
    let ctx: InspectorContext
    @State private var phase = "in"
    var body: some View {
        let target: AnimationTargets = ctx.isText ? .text : (ctx.clip.map { if case .sticker = $0.content { return true }; return false } == true ? .sticker : .video)
        let kind = AnimationPhaseKind(rawValue: phase) ?? .in
        let current: AnimationInstance? = {
            switch kind { case .in: return ctx.clip?.animations.inAnim; case .out: return ctx.clip?.animations.outAnim; case .combo: return ctx.clip?.animations.combo }
        }()
        VStack(alignment: .leading, spacing: 12) {
            SegmentedTabs([("in", tr("anim.phase.in")), ("out", tr("anim.phase.out")), ("combo", tr("anim.phase.combo"))], selection: $phase)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 62, maximum: 72), spacing: 8)], spacing: 10) {
                tile(nil, "nosign", tr("anim.none"), selected: current == nil, kind: kind)
                ForEach(Registries.animations(kind, for: target)) { d in
                    tile(d, d.symbol, tr(d.nameKey), selected: current?.typeID == d.id, kind: kind)
                }
            }
            if let current, let clip = ctx.clip {
                Bind.value(ctx, tr("inspector.duration"), range: 0.1...max(0.2, clip.duration.seconds), display: Fmt.seconds, gestureName: "cmd.animation",
                           get: { c in
                               switch kind { case .in: return c.animations.inAnim?.duration.seconds ?? 0.5
                               case .out: return c.animations.outAnim?.duration.seconds ?? 0.5
                               case .combo: return c.animations.combo?.duration.seconds ?? 1 }
                           },
                           set: { c, v in
                               switch kind { case .in: c.animations.inAnim?.duration = Time(v)
                               case .out: c.animations.outAnim?.duration = Time(v)
                               case .combo: c.animations.combo?.duration = Time(v) }
                           })
                .id(current.typeID)
            }
        }
    }

    func tile(_ d: AnimationDescriptor?, _ symbol: String, _ title: String, selected: Bool, kind: AnimationPhaseKind) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 16))
                .frame(width: 56, height: 56)
                .background(Theme.segmentSelected, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Theme.accent : .clear, lineWidth: 2))
            Text(verbatim: title).font(.system(size: 10)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
        }
        .onTapGesture {
            guard let id = ctx.clip?.id else { return }
            Bind.apply(ctx.store, id, "cmd.animation") { c in
                let inst = d.map { AnimationInstance(typeID: $0.id, duration: min($0.defaultDuration, c.duration)) }
                switch kind {
                case .in: c.animations.inAnim = inst; if inst != nil { c.animations.combo = nil }
                case .out: c.animations.outAnim = inst; if inst != nil { c.animations.combo = nil }
                case .combo: c.animations.combo = inst; if inst != nil { c.animations.inAnim = nil; c.animations.outAnim = nil }
                }
            }
        }
    }
}

/// Effect stack of the selected clip: one block per effect with sliders generated from its `ParamSpec`s, so every
/// registered effect/filter/adjustment gets inspector UI for free.
struct EffectStackSection: View {
    let ctx: InspectorContext
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let clip = ctx.clip {
                if clip.effects.isEmpty {
                    Text(loc: "inspector.noEffects").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
                    Button(tr("inspector.addAdjust")) {
                        Bind.apply(ctx.store, clip.id, "cmd.effect") { $0.effects.append(BuiltinAdjustments.basic.makeInstance()) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                ForEach(clip.effects) { inst in
                    if let d = Registries.effects[inst.typeID] { EffectBlock(ctx: ctx, instance: inst, descriptor: d) }
                }
            }
        }
    }
}

struct EffectBlock: View {
    let ctx: InspectorContext
    let instance: EffectInstance
    let descriptor: EffectDescriptor
    @State private var expanded = true
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.rowSpacing) {
            HStack {
                Toggle("", isOn: Binding(get: { instance.isEnabled }, set: { v in
                    Bind.apply(ctx.store, ctx.clip!.id, "cmd.effect") { c in
                        if let i = c.effects.firstIndex(where: { $0.id == instance.id }) { c.effects[i].isEnabled = v }
                    }
                })).toggleStyle(.checkbox).labelsHidden().tint(Theme.accent)
                SectionHeader(tr(descriptor.nameKey), expanded: $expanded) {
                    Bind.apply(ctx.store, ctx.clip!.id, "cmd.effect") { c in
                        if let i = c.effects.firstIndex(where: { $0.id == instance.id }) { c.effects[i].params = descriptor.makeInstance().params }
                    }
                }
                Button {
                    Bind.apply(ctx.store, ctx.clip!.id, "cmd.effect") { c in c.effects.removeAll { $0.id == instance.id } }
                } label: { Image(systemName: "trash").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help(tr("inspector.removeEffect"))
            }
            if expanded {
                ForEach(descriptor.params, id: \.key) { spec in
                    if case .scalar(let lo, let hi, _) = spec.kind {
                        Bind.slider(ctx, tr(spec.nameKey), key: .effect(instance.id, spec.key), range: lo...hi,
                                    display: { Fmt.int($0 * spec.displayScale) }, gestureName: "cmd.effect")
                    }
                }
            }
        }
    }
}

struct TextSection: View {
    let ctx: InspectorContext
    @State private var draft = ""
    var body: some View {
        let store = ctx.store
        VStack(alignment: .leading, spacing: Theme.Metrics.rowSpacing) {
            TextEditor(text: $draft)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 64)
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 4))
                .onAppear { if case .text(let t) = ctx.clip?.content { draft = t.string } }
                .onChange(of: draft) { _, v in
                    guard let id = ctx.clip?.id, case .text(var t) = ctx.clip?.content, t.string != v else { return }
                    t.string = v
                    Bind.apply(store, id, "cmd.text") { c in c.content = .text(t); c.name = v }
                }
            Bind.value(ctx, tr("inspector.fontSize"), range: 0.01...0.4, display: { Fmt.int($0 * 250) }, gestureName: "cmd.text",
                       get: { c in if case .text(let t) = c.content { return t.fontSize }; return 0.06 },
                       set: { c, v in if case .text(var t) = c.content { t.fontSize = v; c.content = .text(t) } })
            HStack(spacing: 12) {
                ColorPicker(tr("inspector.color"), selection: Binding(
                    get: { if case .text(let t) = ctx.clip?.content { return Color(t.color) }; return .white },
                    set: { col in
                        guard let id = ctx.clip?.id, let c = NSColor(col).usingColorSpace(.sRGB) else { return }
                        Bind.apply(store, id, "cmd.text") { clip in
                            if case .text(var t) = clip.content {
                                t.color = RGBA(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
                                clip.content = .text(t)
                            }
                        }
                    }), supportsOpacity: true)
                    .font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary)
                Spacer()
                toggle("bold", symbol: "bold") { $0.bold.toggle() }
                toggle("italic", symbol: "italic") { $0.italic.toggle() }
            }
            HStack(spacing: 6) {
                ForEach(Registries.textStyles.all) { s in
                    Button(tr(s.nameKey)) {
                        guard let id = ctx.clip?.id else { return }
                        Bind.apply(store, id, "cmd.text") { c in
                            if case .text(var t) = c.content {
                                let keep = (t.string, t.fontSize, t.alignment)
                                t = TextContent(string: keep.0, fontSize: keep.1, alignment: keep.2); s.apply(&t); t.styleID = s.id
                                c.content = .text(t)
                            }
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    func toggle(_ name: String, symbol: String, _ body: @escaping (inout TextContent) -> Void) -> some View {
        Button {
            guard let id = ctx.clip?.id else { return }
            Bind.apply(ctx.store, id, "cmd.text") { c in if case .text(var t) = c.content { body(&t); c.content = .text(t) } }
        } label: { Image(systemName: symbol) }
            .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help(tr("inspector.\(name)"))
    }
}

struct DetailsSection: View {
    @Bindable var store: EditorStore
    var body: some View {
        let s = store.project.settings
        VStack(alignment: .leading, spacing: 12) {
            Text(loc: "inspector.tab.details").font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.textPrimary)
            InfoRow(tr("details.name"), store.projectName)
            InfoRow(tr("details.saved"), store.packageURL?.path ?? tr("details.notSaved"))
            InfoRow(tr("details.proxy"), tr("details.proxy.\(ProxyManager.shared.policy.rawValue)"))
            Rectangle().fill(Theme.separator).frame(height: 1)
            InfoRow(tr("details.ratio"), s.aspectPreset == "original" ? tr("player.ratio.original") : s.aspectPreset)
            InfoRow(tr("details.resolution"), "\(Int(s.canvasSize.width))×\(Int(s.canvasSize.height))")
            HStack {
                Text(loc: "details.frameRate").font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary).frame(width: 110, alignment: .leading)
                Picker("", selection: Binding(get: { s.frameRate }, set: { fr in store.perform(UpdateSettings { $0.frameRate = fr }) })) {
                    ForEach(FrameRate.common, id: \.self) { Text(verbatim: "\($0.description) fps").tag($0) }
                }
                .labelsHidden().frame(width: 120)
                Spacer()
            }
            HStack {
                Text(loc: "settings.language").font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary).frame(width: 110, alignment: .leading)
                Picker("", selection: Binding(get: { L10n.shared.languagePreference }, set: { L10n.shared.setLanguagePreference($0) })) {
                    ForEach(["system", "en", "fr"], id: \.self) { Text(loc: "settings.language.\($0)").tag($0) }
                }
                .labelsHidden().frame(width: 140)
                Spacer()
            }
        }
    }
}
