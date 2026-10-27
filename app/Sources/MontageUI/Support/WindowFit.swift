import SwiftUI
import AppKit
import Perception

// BUG-OVERSIZED-SHEETS (owner rule): no sheet, popover, dialog, menu panel or auxiliary window is ever larger than the
// window it belongs to, and no window is larger than its screen's visibleFrame (2017 13" MacBook Pro on macOS 13).
// Content that doesn't fit scrolls, with the primary buttons pinned outside the scroll area; fixed sizes are ideal
// sizes clamped to the available space. The one mechanism, used everywhere:
// - `WindowFit`: the clamping math (unit-tested, WindowFitTests) + `NSWindow.fitToScreen()` for real windows.
// - `HostWindowSpace.shared`: the main window's content size, published by RootView (`.publishesHostWindowSize()`).
// - In-window modals: `.fittedFrame(ideal)` (fixed-size dialogs), `.fittedFrame(width:)` + `.scrollsWhenTight()` on the
//   body (content-sized cards: pinned header, body that scrolls when tight, pinned footer; `DialogCard` does it),
//   `.inWindowModal(isPresented:)` instead of `.sheet` (a SwiftUI sheet sizes itself to its content, unbounded).
// - Popovers: `.fittedPopover(isPresented:)` instead of `.popover` (content scrolls past the window's height).
// WindowFitTests.sourcesUseTheFitMechanism forbids raw `.sheet(` / `.popover(` and unclamped NSWindow / NSPanel.

public enum WindowFit {
    /// Free space kept around an in-window modal / popover (each side).
    public static let margin: CGFloat = 16

    /// What a modal may take inside a container of `container` size.
    public static func available(in container: CGSize, margin: CGFloat = margin) -> CGSize {
        CGSize(width: max(0, container.width - 2 * margin), height: max(0, container.height - 2 * margin))
    }

    /// `ideal` clamped to what `container` leaves (never larger, never negative).
    public static func fit(_ ideal: CGSize, in container: CGSize, margin: CGFloat = margin) -> CGSize {
        let a = available(in: container, margin: margin)
        return CGSize(width: max(0, min(ideal.width, a.width)), height: max(0, min(ideal.height, a.height)))
    }

    /// A window frame inside a screen's visible frame: size clamped first, then the origin moved so it lies inside.
    public static func clamp(_ frame: CGRect, to visible: CGRect) -> CGRect {
        let w = min(frame.width, visible.width), h = min(frame.height, visible.height)
        let x = min(max(frame.minX, visible.minX), visible.maxX - w)
        let y = min(max(frame.minY, visible.minY), visible.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// A window's minimum size never exceeds the screen (else AppKit keeps it larger than the screen).
    public static func clamp(minSize: CGSize, to visible: CGSize) -> CGSize {
        CGSize(width: min(minSize.width, visible.width), height: min(minSize.height, visible.height))
    }

    /// Whether `frame` (window content coordinates) lies inside a window content of `window` size (½ pt tolerance).
    public static func isInside(_ frame: CGRect, window: CGSize) -> Bool {
        CGRect(origin: .zero, size: window).insetBy(dx: -0.5, dy: -0.5).contains(frame)
    }
}

extension NSWindow {
    /// BUG-OVERSIZED-SHEETS: keeps this window (and its minimum size) inside its screen's visible frame. Call after
    /// sizing / positioning a real window and when it changes screen. Offscreen test windows don't call it.
    public func fitToScreen(_ screen: NSScreen? = nil) {
        guard let s = screen ?? self.screen ?? NSScreen.main else { return }
        let v = s.visibleFrame
        guard v.width > 0, v.height > 0 else { return }
        minSize = WindowFit.clamp(minSize: minSize, to: v.size)
        let f = WindowFit.clamp(frame, to: v)
        if f != frame { setFrame(f, display: isVisible) }
    }
}

/// The main window's content size (RootView publishes it); in-window modals and popovers clamp to it.
@MainActor @Perceptible
public final class HostWindowSpace {
    public static let shared = HostWindowSpace()
    /// nil until RootView is laid out (unit tests): the main screen's visible size is used instead.
    public var size: CGSize?
    /// Frames (window content coordinates) of the fitted cards / popovers / their primary buttons now on screen
    /// (`ui.fit` in the UI-test state dump).
    @PerceptionIgnored public var reported: [String: CGRect] = [:]

    public var container: CGSize { size ?? NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800) }
    /// Space an in-window modal may take.
    public var available: CGSize { WindowFit.available(in: container) }
    public func fit(_ ideal: CGSize) -> CGSize { WindowFit.fit(ideal, in: container) }

    /// `ui.fit`: window size, reported frames and the ones outside the window (must stay empty).
    func dump() -> [String: Any] {
        let w = SyntheticEvents.testWindow?.contentView?.bounds.size ?? size ?? .zero
        return ["window": [Double(w.width), Double(w.height)],
                "shown": reported.keys.sorted().joined(separator: ","),
                "outside": reported.filter { !WindowFit.isInside($0.value, window: w) }.keys.sorted().joined(separator: ","),
                "frames": reported.mapValues { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] }]
    }
}

extension View {
    /// RootView: publishes the window content size to `HostWindowSpace`.
    func publishesHostWindowSize() -> some View {
        background(GeometryReader { g in
            Color.clear
                .onAppear { HostWindowSpace.shared.size = g.size }
                .onValueChange(of: g.size) { _, s in HostWindowSpace.shared.size = s }
        })
    }

    /// Reports this view's window frame as `key` in `ui.fit` (UI tests check it lies inside the window).
    func reportsFit(_ key: String) -> some View {
        background(GeometryReader { g in
            Color.clear
                .onAppear { HostWindowSpace.shared.reported[key] = g.frame(in: .global) }
                .onValueChange(of: g.frame(in: .global)) { _, f in HostWindowSpace.shared.reported[key] = f }
                .onDisappear { HostWindowSpace.shared.reported[key] = nil }
        })
    }

    /// A fixed-size in-window dialog: `ideal` clamped to the window (its content must lay out in less: flexible
    /// areas / scroll views).
    func fittedFrame(_ ideal: CGSize) -> some View { modifier(FittedFrame(ideal: ideal)) }

    /// A content-sized in-window card of width `width` (clamped) whose height never exceeds the window's.
    func fittedFrame(width: CGFloat) -> some View { modifier(FittedWidth(width: width)) }

    /// `.popover` whose content never gets taller / wider than the window: past that it scrolls.
    func fittedPopover<C: View>(isPresented: Binding<Bool>, arrowEdge: Edge = .top, @ViewBuilder content: @escaping () -> C) -> some View {
        // the one raw popover call (WindowFitTests allows it in this file only)
        popover(isPresented: isPresented, arrowEdge: arrowEdge) { PopoverFit(content: content()) }
    }

    /// In-window replacement for `.sheet`: dimmed window, centred card clamped to the window, Esc closes.
    func inWindowModal<C: View>(isPresented: Binding<Bool>, fitKey: String, @ViewBuilder content: @escaping () -> C) -> some View {
        overlay {
            WithPerceptionTracking {
                if isPresented.wrappedValue {
                    InWindowModal(fitKey: fitKey, close: { isPresented.wrappedValue = false }, content: content)
                }
            }
        }
    }

    /// The card's scrolling body: as is when it fits the height it is offered, else inside a vertical scroll view.
    func scrollsWhenTight() -> some View {
        ViewThatFits(in: .vertical) {
            self
            ScrollView(.vertical) { self }
        }
    }
}

private struct FittedFrame: ViewModifier {
    let ideal: CGSize
    func body(content: Content) -> some View {
        WithPerceptionTracking {
            let s = HostWindowSpace.shared.fit(ideal)
            content.frame(width: s.width, height: s.height)
        }
    }
}

private struct FittedWidth: ViewModifier {
    let width: CGFloat
    func body(content: Content) -> some View {
        WithPerceptionTracking {
            let a = HostWindowSpace.shared.available
            let w = min(width, a.width)
            CapLayout(limit: CGSize(width: w, height: a.height)) { content.frame(width: w) }
        }
    }
}

/// Proposes at most `limit` (also for an unspecified proposal: a card's `ViewThatFits` then compares its ideal height
/// with the window's) and takes its child's size, clamped. Unlike `.frame(maxHeight:)` it never grows past the child.
struct CapLayout: Layout {
    let limit: CGSize
    private func capped(_ p: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: min(p.width ?? limit.width, limit.width), height: min(p.height ?? limit.height, limit.height))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let s = subviews.first else { return .zero }
        let size = s.sizeThatFits(capped(proposal))
        return CGSize(width: min(size.width, limit.width), height: min(size.height, limit.height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// Popover content: as is while it fits the window, else scrolled at the window's height.
private struct PopoverFit<C: View>: View {
    let content: C
    @State private var natural: CGSize?
    var body: some View {
        WithPerceptionTracking {
            let a = HostWindowSpace.shared.available
            if let n = natural, n.height > a.height || n.width > a.width {
                ScrollView([.vertical, .horizontal]) { measured }
                    .frame(width: min(n.width, a.width), height: min(n.height, a.height))
            } else {
                measured
            }
        }
    }
    private var measured: some View {
        // no extra sizing: a popover already lays its content out at its ideal size
        content.background(GeometryReader { g in
            Color.clear
                .onAppear { natural = g.size }
                .onValueChange(of: g.size) { _, s in natural = s }
        })
    }
}

/// `inWindowModal`'s overlay.
private struct InWindowModal<C: View>: View {
    let fitKey: String
    let close: () -> Void
    @ViewBuilder let content: () -> C
    var body: some View {
        WithPerceptionTracking {
            ZStack {
                Color.black.opacity(0.5).ignoresSafeArea().contentShape(Rectangle()).onTapGesture {}
                content()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.separator))
                    .shadow(color: .black.opacity(TestAnchors.isEnabled ? 0 : 0.5), radius: TestAnchors.isEnabled ? 0 : 20)
                    .modalHoverShield()   // FB-07
                    .reportsSnapshotFrame { SnapshotRegistry.shared.modalFrame = $0 }
                    .reportsFit(fitKey)
            }
            .onExitCommand(perform: close)
        }
    }
}
