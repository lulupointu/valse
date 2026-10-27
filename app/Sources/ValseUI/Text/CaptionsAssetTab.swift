import SwiftUI
import ValseCore
import ValseEngine
import Perception

/// Asset panel ▸ Captions (C4, CapCut's own top-level tab between Transitions and Filters, [21]): Auto captions ·
/// Local captions.
struct CaptionsAssetTab: View {
    let store: EditorStore
    @Perception.Bindable private var state = CaptionsTabState.shared

    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 0) {
                SubNav(items: [("auto", tr("ai.captions")), ("local", tr("text.nav.local"))],
                       selection: $state.nav)
                Group {
                    switch state.nav {
                    case "local": LocalCaptionsPanel(store: store)
                    default: CaptionsTab(store: store)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Selected Captions sub-nav entry (kept when the tab is reopened).
@MainActor @Perceptible
final class CaptionsTabState {
    static let shared = CaptionsTabState()
    var nav = "auto"
}
