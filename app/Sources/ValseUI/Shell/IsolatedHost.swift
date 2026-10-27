import SwiftUI
import AppKit

/// Hosts `content` in its own `NSHostingView` (perf, W14). SwiftUI lays out a hosting view's whole tree from its root
/// on every invalidation, so one inspector slider tick re-ran layout of the entire editor window (asset grid, player,
/// timeline chrome: ~70 % of the tick's main-thread time). Inside its own host, the panel's changes lay out only the
/// panel; the outer tree just gives it a frame (`sizingOptions = []`: inner content never feeds size back out).
/// Environment does not cross the boundary: the editor's dark colour scheme is re-applied here. `.testID` frames
/// (`.global`) stay in window coordinates in a nested hosting view, so the UI test driver needs nothing special.
struct IsolatedHost<Content: View>: NSViewRepresentable {
    let content: Content
    /// SE-017: the editor panel this host shows (keyboard focus navigation between panels).
    var panel: DetachablePanel?

    init(panel: DetachablePanel? = nil, @ViewBuilder content: () -> Content) { self.panel = panel; self.content = content() }

    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        let h = NSHostingView(rootView: wrapped)
        if let panel { PanelFocus.shared.register(h, for: panel) }
        h.sizingOptions = []
        if #available(macOS 13.3, *) { h.safeAreaRegions = [] }
        return h
    }

    func updateNSView(_ host: NSHostingView<AnyView>, context: Context) { host.rootView = wrapped }

    /// Fills the proposal: asking the inner hosting view for its fitting size would lay out its whole tree.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSHostingView<AnyView>, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 10, height: 10))
    }

    private var wrapped: AnyView { AnyView(content.environment(\.colorScheme, .dark).uitestNoMotion()) }
}
