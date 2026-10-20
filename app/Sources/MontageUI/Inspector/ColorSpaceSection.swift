import SwiftUI
import MontageCore
import Perception

/// Details ▸ Color space (CapCut project settings): SDR Rec.709 / HDR Rec.2020 HLG / HDR Rec.2020 PQ.
/// HDR projects export 10-bit (HEVC Main10 or ProRes) with Rec.2020 tags.
struct ColorSpaceSection: View {
    @Perception.Bindable var store: EditorStore
    var body: some View {
        WithPerceptionTracking {
            let current = store.projectSettings.colorSpace   // observation slice
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(loc: "details.colorSpace").font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary)
                        .frame(width: 110, alignment: .leading)
                    Picker(tr("details.colorSpace"), selection: Binding(get: { current },
                                                  set: { cs in store.perform(UpdateSettings { $0.colorSpace = cs }) })) {
                        ForEach(ProjectColorSpace.allCases, id: \.self) { Text(loc: $0.nameKey).tag($0) }
                    }
                    .labelsHidden().frame(width: 180)
                    Spacer()
                }
                if current.isHDR {
                    Text(loc: "details.colorSpace.hdrHint").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }
}
