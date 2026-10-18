import SwiftUI
import AppKit

/// Stable identifiers for UI tests (docs/TESTING.md).
///
/// `.testID("inspector.tab.video")` sets the SwiftUI `accessibilityIdentifier` and, only while the UI test driver runs
/// (`TestAnchors.isEnabled`), records the view's frame so scripts can target it with `"id:inspector.tab.video"`.
/// AppKit views use `setAccessibilityIdentifier(_:)`; the driver finds them by walking the view tree.
/// Naming: `<area>.<thing>[.<detail>]`, lowercase, no localized text (e.g. `toolbar.split`, `slider.opacity`).
extension View {
    public func testID(_ id: String) -> some View { modifier(TestIDModifier(id: id)) }
}

struct TestIDModifier: ViewModifier {
    let id: String
    /// Identifies this view instance: when a view tree is rebuilt (e.g. language switch), the old instance's
    /// `onDisappear` may run after the new one registered — it must not remove the new frame.
    @State private var token = UUID()
    /// Last frame, so an id change without a geometry change (index-based ids in a re-sorted list) re-registers.
    @State private var frame: CGRect?
    func body(content: Content) -> some View {
        if TestAnchors.isEnabled && TestAnchors.live.tracking {
            content
                .accessibilityIdentifier(id)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame = $0; TestAnchors.shared.set(id, $0, token: token) }
                .onChange(of: id) { old, new in
                    TestAnchors.shared.remove(old, token: token)
                    if let frame { TestAnchors.shared.set(new, frame, token: token) }
                }
                .onDisappear { if TestAnchors.live.tracking { TestAnchors.shared.remove(id, token: token) } }
        } else {
            content.accessibilityIdentifier(id)
        }
    }
}

/// Perf steps pause geometry tracking while they measure (`"anchors": "frozen"`, the default): every `.testID` view's
/// `onGeometryChange` otherwise runs on each layout pass, a test-only cost that would inflate interaction timings.
/// Frames recorded before the pause stay valid (the steps don't move views).
@Observable @MainActor
public final class TestAnchorTracking {
    public var tracking = true
}

/// Frames (SwiftUI global space = hosting view coordinates, top-left origin) of every visible `.testID` view.
@MainActor
public final class TestAnchors {
    public static let shared = TestAnchors()
    /// Set by the UI test driver before the window is built. Off in normal runs (no geometry tracking cost).
    public nonisolated(unsafe) static var isEnabled = false
    public static let live = TestAnchorTracking()
    private(set) var frames: [String: CGRect] = [:]
    /// Every live view instance claiming an id, oldest first (a view being removed can still report geometry after
    /// its replacement registered; when it disappears, the remaining owner's frame wins).
    private var owners: [String: [(token: UUID, frame: CGRect)]] = [:]

    func set(_ id: String, _ frame: CGRect, token: UUID) {
        var list = owners[id] ?? []
        if let i = list.firstIndex(where: { $0.token == token }) { list[i].frame = frame } else { list.append((token, frame)) }
        owners[id] = list
        frames[id] = list.last?.frame
    }
    func remove(_ id: String, token: UUID) {
        guard var list = owners[id] else { return }
        list.removeAll { $0.token == token }
        owners[id] = list.isEmpty ? nil : list
        frames[id] = list.last?.frame
    }
    public var ids: [String] { frames.keys.sorted() }
    public func frame(_ id: String) -> CGRect? { frames[id] }
}
