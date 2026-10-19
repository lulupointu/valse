import SwiftUI
import MontageCore
import MontageEngine

/// Asset panel ▸ Captions (C4, CapCut's own top-level tab between Transitions and Filters, [21]): Auto captions ·
/// Local captions · Filler words. "Filler words" is the same transcript / filler review as the Transcript panel
/// (`TranscriptWorkspace`), so both entry points share one UX.
struct CaptionsAssetTab: View {
    let store: EditorStore
    @Bindable private var state = CaptionsTabState.shared

    var body: some View {
        HStack(spacing: 0) {
            SubNav(items: [("auto", tr("ai.captions")), ("local", tr("text.nav.local")), ("fillers", tr("captions.nav.fillers"))],
                   selection: $state.nav)
            Group {
                switch state.nav {
                case "local": LocalCaptionsPanel(store: store)
                case "fillers": TranscriptWorkspace(store: store, context: .captions)
                default: CaptionsTab(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Selected Captions sub-nav entry (kept when the tab is reopened; the inspector's "Remove filler words" opens it).
@MainActor @Observable
final class CaptionsTabState {
    static let shared = CaptionsTabState()
    var nav = "auto"
}

@MainActor
extension EditorStore {
    /// Opens Captions ▸ Filler words (from the inspector caption list), unless the Transcript panel is showing it.
    func showFillerWords() {
        if ai.transcriptOpen { return }
        activeAssetTab = "captions"
        CaptionsTabState.shared.nav = "fillers"
    }
}
