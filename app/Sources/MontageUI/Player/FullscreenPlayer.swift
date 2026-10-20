import SwiftUI
import MontageCore
import Perception

/// Player-only full screen (PB-006, ⇧⌘F): the preview fills the window, the transport bar auto-hides after 2 s without
/// mouse movement, esc exits.
public struct FullscreenPlayer: View {
    @Perception.Bindable var store: EditorStore
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    public init(store: EditorStore) { self.store = store }

    public var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                PlayerCanvasArea(store: store)
                TransportBar(store: store, transport: store.transport, ui: store.playerUI)
                    .background(Theme.panel)
                    .opacity(controlsVisible ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: controlsVisible)
            }
            .background(Theme.panel)
            .onContinuousHover { phase in
                if case .active = phase { poke() }
            }
            .onAppear { poke() }
            .onDisappear { hideTask?.cancel() }
        }
    }

    private func poke() {
        controlsVisible = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { controlsVisible = false }
        }
    }
}
