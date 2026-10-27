import SwiftUI
import AppKit
import ValseCore
import ValseEngine
import Perception

// Inspector UI for the W6/W9 render features: Video ▸ Basic ▸ ☐ Stabilize / ☐ Motion blur (UX.md §5.1) and the
// Speed ▸ Normal ▸ ☐ Smooth slow-mo method. Optional sections use the header checkbox (`chrome.isEnabled`).

struct StabilizeSection: View {
    let ctx: InspectorContext

    static func chrome(_ ctx: InspectorContext) -> InspectorSectionChrome {
        let pending = ctx.asset.map { StabilizationStore.shared.isPending($0) } ?? false
        return InspectorSectionChrome(
            isEnabled: Bind.binding(ctx, "cmd.stabilize", get: { $0.stabilization != nil },
                                    set: { c, on in c.stabilization = on ? (c.stabilization ?? Stabilization()) : nil }, default: false),
            subtitle: pending ? tr("inspector.stabilize.analyzing") : nil)
    }

    var body: some View {
        WithPerceptionTracking {
            InlineRow(label: tr("inspector.stabilize.level")) {
                Dropdown(items: StabilizationLevel.allCases.map { ($0, tr($0.nameKey)) },
                         selection: ctx.clip?.stabilization?.level ?? .recommended) { l in
                    // C2: the settings show while unticked; picking a level there turns stabilization on with it
                    if let id = ctx.clip?.id { Bind.apply(ctx.store, id, "cmd.stabilize") { c in
                        var s = c.stabilization ?? Stabilization(); s.level = l; c.stabilization = s
                    } }
                }
            }
        }
    }
}

struct MotionBlurSection: View {
    let ctx: InspectorContext

    static func chrome(_ ctx: InspectorContext) -> InspectorSectionChrome {
        InspectorSectionChrome(
            isEnabled: Bind.binding(ctx, "cmd.motionBlur", get: { $0.motionBlur != nil },
                                    set: { c, on in c.motionBlur = on ? (c.motionBlur ?? MotionBlur()) : nil }, default: false))
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                ClipParamRow(ctx: ctx, label: tr("inspector.motionBlur.amount"), spec: RowSpec(range: 0...100, format: Fmt.percentValue),
                             get: { c, _ in (c.motionBlur ?? MotionBlur()).amount * 100 },
                             set: { c, v, _ in var m = c.motionBlur ?? MotionBlur(); m.amount = v / 100; c.motionBlur = m },   // edit while off = on
                             keyframeKeys: [], gestureName: "cmd.motionBlur")
                InlineRow(label: tr("inspector.motionBlur.direction")) {   // CV-014 (F3)
                    SegmentedTabs(MotionBlurDirection.allCases.map { ($0.rawValue, tr($0.nameKey)) },
                                  selection: Binding.perceived(get: { (ctx.clip?.motionBlur?.direction ?? .backward).rawValue }, set: { v in
                                      guard let id = ctx.clip?.id, let d = MotionBlurDirection(rawValue: v) else { return }
                                      Bind.apply(ctx.store, id, "cmd.motionBlur") { $0.motionBlur?.direction = d == .backward ? nil : d }
                                  }))
                    .testID("motionBlur.direction")
                }
                InlineRow(label: tr("inspector.motionBlur.times")) {
                    Dropdown(items: [2, 4, 6].map { ($0, "\($0)x") }, selection: ctx.clip?.motionBlur?.clampedSamples ?? 2) { n in
                        if let id = ctx.clip?.id { Bind.apply(ctx.store, id, "cmd.motionBlur") { c in
                            var m = c.motionBlur ?? MotionBlur(); m.samples = n; c.motionBlur = m
                        } }
                    }
                }
            }
        }
    }
}

/// Speed ▸ Normal ▸ ☐ Smooth slow-mo (only below 1×) with the method dropdown (frame blending / optical flow).
struct SmoothSlowMoRow: View {
    let ctx: InspectorContext

    static func applies(_ c: Clip?) -> Bool {
        guard let c else { return false }
        switch c.speed {
        case .constant(let v): return v < 1
        case .curve(let cv): return cv.points.contains { $0.v < 1 }
        }
    }

    var body: some View {
        WithPerceptionTracking {
            let on = ctx.clip?.smoothSlowMo != nil
            let available = Self.applies(ctx.clip)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    CapCheckbox(isOn: Bind.binding(ctx, "cmd.slowmo", get: { $0.smoothSlowMo != nil },
                                                   set: { c, v in c.smoothSlowMo = v ? .frameBlending : nil }, default: false),
                                enabled: available)
                    Text(loc: "inspector.smoothSlowmo").font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.textPrimary)
                    Text(loc: "inspector.smoothSlowmo.hint").font(.system(size: 12)).foregroundStyle(IStyle.caption).lineLimit(1)
                }
                .opacity(available ? 1 : 0.4)
                if on && available {
                    InlineRow(label: tr("inspector.slowmo.method")) {
                        Dropdown(items: SlowMotionMethod.allCases.map { ($0, tr($0.nameKey)) },
                                 selection: ctx.clip?.smoothSlowMo ?? .frameBlending) { m in
                            if let id = ctx.clip?.id { Bind.apply(ctx.store, id, "cmd.slowmo") { $0.smoothSlowMo = m } }
                        }
                    }
                }
            }
        }
    }
}

@MainActor
enum RenderFeatureInspector {
    static let sections: [InspectorSection] = [
        InspectorSection(id: "video.stabilize", tab: "video", subTab: "basic", order: 40, titleKey: "inspector.stabilize",
                         appliesTo: { $0.isMediaVideo }, chrome: StabilizeSection.chrome) { AnyView(StabilizeSection(ctx: $0)) },
        InspectorSection(id: "video.motionBlur", tab: "video", subTab: "basic", order: 60, titleKey: "inspector.motionBlur",
                         appliesTo: { $0.isMediaVideo }, chrome: MotionBlurSection.chrome) { AnyView(MotionBlurSection(ctx: $0)) },
    ]
}
