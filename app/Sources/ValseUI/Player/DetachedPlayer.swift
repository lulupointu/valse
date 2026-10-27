import SwiftUI
import AppKit
import ValseCore
import Perception

/// Detachable panels (PB-006 "Detach player", SE-006 separate windows / dual screen): a panel moves into its own
/// resizable window (drag it to a second display, or full-screen it there); the editor shows a placeholder with
/// [Attach]. Closing the window attaches it back. Only one view of a panel exists at a time (the player owns the
/// engine's video output). During UI tests no real window may appear, so detached panels are hosted in the test window
/// instead (EditorView).
public enum DetachablePanel: String, CaseIterable, Sendable {
    case player, assets, inspector, timeline
    var titleKey: String { "panel.detached.\(rawValue)" }
    var defaultSize: NSSize {
        switch self {
        case .player: return NSSize(width: 960, height: 600)
        case .assets, .inspector: return NSSize(width: 520, height: 640)
        case .timeline: return NSSize(width: 1400, height: 420)
        }
    }
}

@MainActor
final class DetachedPanelsController: NSObject, NSWindowDelegate {
    static let shared = DetachedPanelsController()
    private var windows: [DetachablePanel: NSWindow] = [:]
    private weak var store: EditorStore?

    func sync(_ store: EditorStore) {
        self.store = store
        if TestAnchors.isEnabled { return }
        for p in DetachablePanel.allCases {
            if store.detachedPanels.contains(p) {
                let w = windows[p] ?? make(p, store)
                windows[p] = w
                w.makeKeyAndOrderFront(nil)
            } else if let w = windows[p] {
                windows[p] = nil
                w.delegate = nil
                w.close()
            }
        }
    }

    @ViewBuilder static func content(_ p: DetachablePanel, _ store: EditorStore) -> some View {
        switch p {
        case .player: PlayerPanel(store: store)
        case .assets: AssetPanel(store: store)
        case .inspector: InspectorPanel(store: store)
        case .timeline: TimelinePanel(store: store)
        }
    }

    private func make(_ p: DetachablePanel, _ store: EditorStore) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: p.defaultSize),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = tr(p.titleKey)
        w.identifier = NSUserInterfaceItemIdentifier(p.rawValue)
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.fullScreenPrimary]
        w.delegate = self
        w.contentView = NSHostingView(rootView: Self.content(p, store).environment(\.colorScheme, .dark).background(Theme.panel).uitestNoMotion())
        // open on another display when there is one (dual screen), else centred over the editor
        let editor = NSApp.mainWindow?.screen
        if let other = NSScreen.screens.first(where: { $0 != editor }) {
            let f = other.visibleFrame
            w.setFrame(NSRect(x: f.midX - p.defaultSize.width / 2, y: f.midY - p.defaultSize.height / 2,
                              width: min(p.defaultSize.width, f.width), height: min(p.defaultSize.height, f.height)), display: false)
            w.fitToScreen(other)
        } else {
            w.center()
            w.fitToScreen(editor)   // BUG-OVERSIZED-SHEETS: e.g. the 1400 pt timeline window on a 1280 pt screen
        }
        return w
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, let id = w.identifier?.rawValue, let p = DetachablePanel(rawValue: id) else { return }
        windows[p] = nil
        store?.setPanel(p, detached: false)
    }
}

extension EditorStore {
    /// Panels currently in their own window.
    public var detachedPanels: Set<DetachablePanel> {
        var s = EditorLayout.shared.detached
        if playerUI.isDetached { s.insert(.player) } else { s.remove(.player) }
        return s
    }

    /// View ▸ Detach / Attach (PB-006 / SE-006).
    public func setPanel(_ p: DetachablePanel, detached on: Bool) {
        guard detachedPanels.contains(p) != on else { return }
        if p == .player {
            if on && playerUI.isFullscreen { setPlayerFullscreen(false) }
            playerUI.isDetached = on
        }
        if on { EditorLayout.shared.detached.insert(p) } else { EditorLayout.shared.detached.remove(p) }
        DetachedPanelsController.shared.sync(self)
    }

    public func setPlayerDetached(_ on: Bool) { setPanel(.player, detached: on) }

    /// Attaches every panel (closing the project).
    func attachAllPanels() { for p in detachedPanels { setPanel(p, detached: false) } }
}

/// What the editor shows in a panel's slot while it is detached.
struct DetachedPanelPlaceholder: View {
    let store: EditorStore
    let panel: DetachablePanel
    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 12) {
                Image(systemName: "rectangle.on.rectangle").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.textTertiary)
                Text(loc: "panel.detached.placeholder").font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                Button(tr("panel.attach")) { store.setPanel(panel, detached: false) }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small).testID("\(panel.rawValue).attach")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.panelRadius))
            .testID("\(panel.rawValue).detachedPlaceholder")
        }
    }
}
