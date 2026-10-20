import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MontageCore
import MontageEffects
import MontageEngine
import Perception

/// Adjust ▸ Basic ▸ LUT (CapCut): Name dropdown ("None" + imported LUTs), Import…, Strength.
/// A chosen LUT is one `user.lut.<hash>` effect instance on the clip (kept first in the stack so later adjustments
/// grade on top of the look, as in CapCut).
struct LUTSection: View {
    let ctx: InspectorContext
    @State private var revision = 0

    static func isLUT(_ e: EffectInstance) -> Bool { e.typeID.hasPrefix(LUTLibrary.idPrefix) }

    var body: some View {
        WithPerceptionTracking {
            let current = ctx.clip?.effects.first(where: Self.isLUT)
            VStack(alignment: .leading, spacing: Theme.Metrics.rowSpacing) {
                HStack {
                    Text(loc: "inspector.lut.name").font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Picker(tr("inspector.lut.name"), selection: Binding(get: { current?.typeID ?? "" }, set: { choose($0) })) {
                        Text(loc: "inspector.lut.none").tag("")
                        ForEach(LUTLibrary.shared.all, id: \.id) { Text(verbatim: $0.name).tag($0.id) }
                    }
                    .labelsHidden().frame(width: 150).id(revision)
                    Button(tr("inspector.lut.import")) { importLUT() }.buttonStyle(SecondaryButtonStyle())
                }
                if let current {
                    Bind.row(ctx, tr("fx.param.strength"), key: ParamKey.effect(current.id, "intensity"),
                             spec: RowSpec(range: 0...100, format: Fmt.percentValue), toUI: { $0 * 100 }, fromUI: { $0 / 100 },
                             gestureName: "cmd.effect")
                }
                // CapCut [115]: "Skin tone protection (Turn it on to make skin tone more natural)" — CL-010
                ToggleLine(label: tr("adjust.skinProtect"), detail: tr("adjust.skinProtect.detail"),
                           isOn: Bind.binding(ctx, "cmd.skinProtect", get: { $0.skinToneProtection ?? false },
                                              set: { $0.skinToneProtection = $1 ? true : nil }, default: false))
                    .testID("adjust.skinProtect")
            }
        }
    }

    private func choose(_ id: String) {
        guard let clipID = ctx.clip?.id else { return }
        Bind.apply(ctx.store, clipID, "cmd.effect") { c in
            let old = c.effects.firstIndex(where: Self.isLUT)
            let strength = old.flatMap { c.effects[$0].params["intensity"] }
            if let old { c.effects.remove(at: old) }
            guard !id.isEmpty, let d = Registries.effects[id] else { return }
            var inst = d.makeInstance()
            if let strength { inst.params["intensity"] = strength }
            c.effects.insert(inst, at: 0)
        }
    }

    private func importLUT() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ["cube", "3dl"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        var last: String?
        for url in panel.urls {
            do { last = try LUTLibrary.shared.importLUT(url) } catch { ctx.store.showToast(tr("lut.error.invalid"), error: true) }
        }
        revision += 1
        if let last { choose(last) }
    }
}
