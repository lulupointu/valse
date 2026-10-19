import SwiftUI
import MontageCore

// Video ▸ Basic ▸ ☐ HDR conversion (CL-014): shown for a video whose transfer differs from the project's (HDR footage in
// an SDR project, or SDR footage in an HDR project). Off = the default conversion (Apple-matched curve). On = BT.2390
// tone mapping with the source's peak brightness (HDR → SDR) or SDR highlights expanded to a peak (SDR → HDR).

enum HDRConversionInspector {
    /// The selected clip's source needs an SDR ↔ HDR conversion in this project.
    @MainActor static func direction(_ ctx: InspectorContext) -> (toSDR: Bool, applies: Bool) {
        guard ctx.kind != .adjustment, let a = ctx.asset, a.kind == .video else { return (false, false) }
        let project = ctx.store.projectSettings.colorSpace.transfer
        let src = a.transfer
        return (project == .sdr, src != project && (src == .sdr || project == .sdr))
    }

    nonisolated static func defaultPeak(toSDR: Bool) -> Double { toSDR ? 1000 : 600 }

    @MainActor static let sections: [InspectorSection] = [
        InspectorSection(id: "video.hdrConversion", tab: "video", subTab: "basic", order: 26, titleKey: "hdrConv.title",
                         appliesTo: { direction($0).applies }, chrome: { ctx in
            let store = ctx.store
            let toSDR = direction(ctx).toSDR
            return InspectorSectionChrome(isEnabled: Binding(get: { ctx.clip?.hdrConversion?.method == .bt2390 }, set: { on in
                guard let id = ctx.clip?.id else { return }
                store.perform(UpdateClip(id, nameKey: "cmd.hdrConversion") { c in
                    c.hdrConversion = on ? HDRConversion(method: .bt2390, peakNits: c.hdrConversion?.peakNits ?? defaultPeak(toSDR: toSDR)) : nil
                })
            }), reset: ctx.clip?.hdrConversion == nil ? nil : {
                guard let id = ctx.clip?.id else { return }
                store.perform(UpdateClip(id, nameKey: "cmd.hdrConversion") { c in
                    if c.hdrConversion != nil { c.hdrConversion = HDRConversion(method: .bt2390, peakNits: defaultPeak(toSDR: toSDR)) }
                })
            })
        }) { AnyView(HDRConversionSection(ctx: $0)) },
    ]
}

struct HDRConversionSection: View {
    let ctx: InspectorContext
    var body: some View {
        let toSDR = HDRConversionInspector.direction(ctx).toSDR
        let store = ctx.store
        let range = toSDR ? HDRConversion.sourcePeakRange : HDRConversion.targetPeakRange
        VStack(alignment: .leading, spacing: Theme.Metrics.rowSpacing) {
            HintText(text: tr(toSDR ? "hdrConv.hint.toSDR" : "hdrConv.hint.toHDR"))
            if let h = ctx.clip?.hdrConversion, let id = ctx.clip?.id {
                SliderRow(tr(toSDR ? "hdrConv.sourcePeak" : "hdrConv.targetPeak"), range: range,
                          display: { tr("hdrConv.nits", Int($0.rounded())) }, testID: "slider.hdrConv.peak",
                          get: { h.peakNits },
                          set: { v in Bind.apply(store, id, "cmd.hdrConversion") { $0.hdrConversion?.peakNits = min(max(v, range.lowerBound), range.upperBound) } },
                          onBegin: { store.beginGesture("cmd.hdrConversion") }, onEnd: { store.endGesture() })
            }
        }
    }
}
