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
    func body(content: Content) -> some View {
        if TestAnchors.isEnabled {
            content
                .accessibilityIdentifier(id)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { TestAnchors.shared.set(id, $0, token: token) }
                .onDisappear { TestAnchors.shared.remove(id, token: token) }
        } else {
            content.accessibilityIdentifier(id)
        }
    }
}

/// Frames (SwiftUI global space = hosting view coordinates, top-left origin) of every visible `.testID` view.
@MainActor
public final class TestAnchors {
    public static let shared = TestAnchors()
    /// Set by the UI test driver before the window is built. Off in normal runs (no geometry tracking cost).
    public nonisolated(unsafe) static var isEnabled = false
    private(set) var frames: [String: CGRect] = [:]
    private var owners: [String: UUID] = [:]

    func set(_ id: String, _ frame: CGRect, token: UUID) { frames[id] = frame; owners[id] = token }
    func remove(_ id: String, token: UUID) {
        guard owners[id] == token else { return }
        frames[id] = nil; owners[id] = nil
    }
    public var ids: [String] { frames.keys.sorted() }
    public func frame(_ id: String) -> CGRect? { frames[id] }
}
