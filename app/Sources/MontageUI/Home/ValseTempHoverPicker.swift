import SwiftUI
import MontageCore

// TEMPORARY (VALSE-HOME round 6): lets the owner compare the feature-card hover treatments live, without relaunching.
// Once one is picked: delete this file, the picker in `HomeTopBar` and the `choice` in `FeatureCardFace`, and keep only
// the chosen `ValseCardHoverStyle.of(_:)` values.

/// The one switch for the temporary picker. `false` hides it (the stored / default option still applies).
enum ValseTempHoverPicker {
    static let enabled = true
    /// Never in UI tests, screenshots, offscreen windows or review recordings (baselines only ever show the rest state).
    @MainActor static var visible: Bool {
        let a = CommandLine.arguments
        return enabled && !a.contains("--uitest") && !a.contains("--snapshot") && !a.contains("--offscreen")
            && !ValseDebugClock.shared.active
    }
}

/// The feature-card hover options (`ValseCardHoverStyle.of`): A lift off a block, B tile pops, C edge bar, D icon only.
enum ValseCardHover: String, CaseIterable {
    case a = "A", b = "B", c = "C", d = "D"
}

/// The current option, remembered across launches. `VALSE_TEMP_CARD_HOVER=A…D` forces one (review stills).
@MainActor final class ValseCardHoverChoice: ObservableObject {
    static let shared = ValseCardHoverChoice()
    private static let key = "ValseTempCardHover"
    @Published var option: ValseCardHover {
        didSet { AppDefaults.store.set(option.rawValue, forKey: Self.key) }
    }
    private init() {
        let forced = ProcessInfo.processInfo.environment["VALSE_TEMP_CARD_HOVER"].flatMap(ValseCardHover.init(rawValue:))
        option = forced ?? AppDefaults.store.string(forKey: Self.key).flatMap(ValseCardHover.init(rawValue:)) ?? .a
    }
}

/// "Hover A B C D": a compact segmented control in the Home top bar (temporary, see the file header).
struct ValseTempHoverPickerView: View {
    @ObservedObject private var choice = ValseCardHoverChoice.shared
    var body: some View {
        HStack(spacing: 2) {
            Text(verbatim: "Hover").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.Valse.text3)
                .padding(.leading, 6).padding(.trailing, 2)
            ForEach(ValseCardHover.allCases, id: \.self) { o in
                let on = choice.option == o
                Button { choice.option = o } label: {
                    Text(verbatim: o.rawValue).font(.system(size: 11, weight: on ? .bold : .medium).monospaced())
                        .foregroundStyle(on ? Theme.Valse.ink : Theme.Valse.text2)
                        .frame(width: 22, height: 20)
                        .background(on ? Theme.Valse.mint : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "Hover \(o.rawValue)"))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.Valse.control, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.Valse.stroke))
    }
}
