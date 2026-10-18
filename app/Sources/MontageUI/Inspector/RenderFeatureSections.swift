import SwiftUI
import AppKit
import MontageCore
import MontageEngine

// Inspector UI for the W6/W9 render features: Video ▸ Chroma key / Stabilize / Motion blur, Speed ▸ Smooth slow-mo.
// CapCut layout: an optional section with an enable checkbox; controls appear when it is on.

/// Section body with a CapCut-style enable checkbox in front of the controls.
struct FeatureToggle<Content: View>: View {
    let label: String
    let isOn: Bool
    let set: (Bool) -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.rowSpacing) {
            Toggle(isOn: Binding(get: { isOn }, set: set)) {
                Text(verbatim: label).font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.textPrimary)
            }
            .toggleStyle(.checkbox)
            if isOn { content() }
        }
    }
}

struct ChromaKeySection: View {
    let ctx: InspectorContext
    var body: some View {
        let ck = ctx.clip?.chromaKey
        FeatureToggle(label: tr("inspector.chroma.enable"), isOn: ck != nil, set: { on in
            guard let id = ctx.clip?.id else { return }
            Bind.apply(ctx.store, id, "cmd.chroma") { $0.chromaKey = on ? ChromaKey() : nil }
        }) {
            HStack(spacing: 8) {
                Text(loc: "inspector.chroma.color").font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button { pickFromScreen() } label: { Image(systemName: "eyedropper") }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help(tr("inspector.chroma.picker"))
                ColorPicker("", selection: Binding(get: { Color(rgba: ck?.color ?? .green) }, set: { setColor($0.rgba) }),
                            supportsOpacity: false).labelsHidden()
            }
            Bind.slider(ctx, tr("inspector.chroma.intensity"), key: .chromaIntensity, range: 0...1, display: Fmt.percent, gestureName: "cmd.chroma")
            Bind.slider(ctx, tr("inspector.chroma.shadow"), key: .chromaShadow, range: 0...1, display: Fmt.percent, gestureName: "cmd.chroma")
            Bind.value(ctx, tr("inspector.chroma.feather"), range: 0...1, display: Fmt.percent, gestureName: "cmd.chroma",
                       get: { $0.chromaKey?.edgeFeather ?? 0 }, set: { $0.chromaKey?.edgeFeather = $1 })
            Bind.value(ctx, tr("inspector.chroma.cleanup"), range: 0...1, display: Fmt.percent, gestureName: "cmd.chroma",
                       get: { $0.chromaKey?.edgeCleanup ?? 0 }, set: { $0.chromaKey?.edgeCleanup = $1 })
            Bind.value(ctx, tr("inspector.chroma.spill"), range: 0...1, display: Fmt.percent, gestureName: "cmd.chroma",
                       get: { $0.chromaKey?.spill ?? 0 }, set: { $0.chromaKey?.spill = $1 })
        }
    }

    private func setColor(_ c: RGBA) {
        guard let id = ctx.clip?.id else { return }
        Bind.apply(ctx.store, id, "cmd.chroma") { $0.chromaKey?.color = RGBA(c.r, c.g, c.b) }
    }

    /// System colour sampler: click anywhere (e.g. the green in the player) to pick the key colour.
    private func pickFromScreen() {
        NSColorSampler().show { color in
            guard let c = color?.usingColorSpace(.sRGB) else { return }
            Task { @MainActor in setColor(RGBA(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))) }
        }
    }
}

struct StabilizeSection: View {
    let ctx: InspectorContext
    var body: some View {
        let st = ctx.clip?.stabilization
        FeatureToggle(label: tr("inspector.stabilize.enable"), isOn: st != nil, set: { on in
            guard let id = ctx.clip?.id else { return }
            Bind.apply(ctx.store, id, "cmd.stabilize") { $0.stabilization = on ? Stabilization() : nil }
        }) {
            HStack {
                Text(loc: "inspector.stabilize.level").font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary)
                Spacer()
                Picker("", selection: Binding(get: { st?.level ?? .recommended }, set: { l in
                    if let id = ctx.clip?.id { Bind.apply(ctx.store, id, "cmd.stabilize") { $0.stabilization?.level = l } }
                })) {
                    ForEach(StabilizationLevel.allCases, id: \.self) { Text(loc: $0.nameKey).tag($0) }
                }
                .labelsHidden().frame(width: 150)
            }
            if let a = ctx.asset, !StabilizationStore.shared.isAnalyzed(a) {
                Text(loc: "inspector.stabilize.analyzing").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

struct MotionBlurSection: View {
    let ctx: InspectorContext
    var body: some View {
        let mb = ctx.clip?.motionBlur
        FeatureToggle(label: tr("inspector.motionBlur.enable"), isOn: mb != nil, set: { on in
            guard let id = ctx.clip?.id else { return }
            Bind.apply(ctx.store, id, "cmd.motionBlur") { $0.motionBlur = on ? MotionBlur() : nil }
        }) {
            Bind.value(ctx, tr("inspector.motionBlur.amount"), range: 0...1, display: Fmt.percent, gestureName: "cmd.motionBlur",
                       get: { $0.motionBlur?.amount ?? 0 }, set: { $0.motionBlur?.amount = $1 })
            HStack {
                Text(loc: "inspector.motionBlur.times").font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary)
                Spacer()
                Picker("", selection: Binding(get: { mb?.clampedSamples ?? 2 }, set: { n in
                    if let id = ctx.clip?.id { Bind.apply(ctx.store, id, "cmd.motionBlur") { $0.motionBlur?.samples = n } }
                })) {
                    ForEach([2, 4, 6], id: \.self) { Text(verbatim: "\($0)x").tag($0) }
                }
                .labelsHidden().frame(width: 90)
            }
        }
    }
}

struct SmoothSlowMoSection: View {
    let ctx: InspectorContext
    var body: some View {
        let m = ctx.clip?.smoothSlowMo
        FeatureToggle(label: tr("inspector.slowmo.enable"), isOn: m != nil, set: { on in
            guard let id = ctx.clip?.id else { return }
            Bind.apply(ctx.store, id, "cmd.slowmo") { $0.smoothSlowMo = on ? .frameBlending : nil }
        }) {
            HStack {
                Text(loc: "inspector.slowmo.method").font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary)
                Spacer()
                Picker("", selection: Binding(get: { m ?? .frameBlending }, set: { v in
                    if let id = ctx.clip?.id { Bind.apply(ctx.store, id, "cmd.slowmo") { $0.smoothSlowMo = v } }
                })) {
                    ForEach(SlowMotionMethod.allCases, id: \.self) { Text(loc: $0.nameKey).tag($0) }
                }
                .labelsHidden().frame(width: 150)
            }
        }
    }

    /// CapCut only offers smooth slow-mo below 1×.
    static func applies(_ ctx: InspectorContext) -> Bool {
        guard ctx.isMediaVideo, let c = ctx.clip else { return false }
        switch c.speed {
        case .constant(let v): return v < 1
        case .curve(let cv): return cv.points.contains { $0.v < 1 }
        }
    }
}

@MainActor
enum RenderFeatureInspector {
    static let sections: [InspectorSection] = [
        InspectorSection(id: "video.chroma", tab: "video", order: 3, titleKey: nil,
                         appliesTo: { $0.isMediaVideo || $0.asset?.kind == .image }) { AnyView(ChromaKeySection(ctx: $0)) },
        InspectorSection(id: "video.stabilize", tab: "video", order: 4, titleKey: nil,
                         appliesTo: { $0.isMediaVideo }) { AnyView(StabilizeSection(ctx: $0)) },
        InspectorSection(id: "video.motionBlur", tab: "video", order: 5, titleKey: nil,
                         appliesTo: { $0.isMediaVideo }) { AnyView(MotionBlurSection(ctx: $0)) },
        InspectorSection(id: "speed.smoothSlowMo", tab: "speed", order: 1, titleKey: nil,
                         appliesTo: { SmoothSlowMoSection.applies($0) }) { AnyView(SmoothSlowMoSection(ctx: $0)) },
    ]
}

extension Color {
    init(rgba c: RGBA) { self.init(c) }
    var rgba: RGBA {
        let n = NSColor(self).usingColorSpace(.sRGB) ?? .green
        return RGBA(Double(n.redComponent), Double(n.greenComponent), Double(n.blueComponent), Double(n.alphaComponent))
    }
}
