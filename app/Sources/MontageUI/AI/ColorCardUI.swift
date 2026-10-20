import SwiftUI
import MontageCore
import MontageEngine
import MontageAI
import Perception

// Adjust ▸ Basic ▸ ☐ Color card (CL-028): put the playhead on a frame showing a ColorChecker 24 chart and tick it — the
// chart is found, its 24 patches fitted to the reference and the correction applied as a look (Strength keyframeable).

enum ColorCardInspector {
    @MainActor static let sections: [InspectorSection] = [
        InspectorSection(id: "adjust.colorCard", tab: "adjust", subTab: "basic", order: 4, titleKey: "colorCard.title",
                         appliesTo: ColorLookInspector.visual, chrome: { ctx in ColorLookInspector.chromeCard(ctx) }) { AnyView(ColorCardSection(ctx: $0)) },
    ]
}

extension ColorLookInspector {
    @MainActor static func chromeCard(_ ctx: InspectorContext) -> InspectorSectionChrome {
        let store = ctx.store
        return InspectorSectionChrome(isEnabled: Binding(get: {
            guard let c = ctx.clip else { return false }
            return look(c, .card) != nil || store.ai.lookJobs[ColorLookUI.key(c.id, .card)] != nil
        }, set: { on in
            guard let id = ctx.clip?.id else { return }
            if on { store.applyColorCard(id) } else { store.removeLook(id, kind: .card) }
        }), reset: { if let id = ctx.clip?.id { store.removeLook(id, kind: .card) } },
           keyframeKeys: look(ctx.clip, .card).map { [ParamKey.effect($0.id, "intensity")] })
    }
}

struct ColorCardSection: View {
    let ctx: InspectorContext
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: Theme.Metrics.rowSpacing) {
                HintText(text: tr("colorCard.hint"))
                if ColorLookInspector.look(ctx.clip, .card) != nil {
                    HStack {
                        Spacer()
                        PillButton(title: tr("colorCard.recalibrate"), symbol: "eyedropper") {
                            if let id = ctx.clip?.id { ctx.store.applyColorCard(id) }
                        }
                        .testID("colorCard.recalibrate")
                    }
                }
                LookStrengthSection(ctx: ctx, kind: .card)
            }
        }
    }
}

extension EditorStore {
    /// Color card: background job on the frame under the playhead → one undo step ("Color card").
    public func applyColorCard(_ clipID: ClipID) {
        let project = self.project, t = transport.playhead
        runLookJob(clipID, .card) { try await ColorCard.calibrate(project: project, clipID: clipID, at: t) }
    }
}
