import SwiftUI
import AppKit
import CoreVideo
import QuartzCore
import os
import Perception

// macOS 13 back-ports. Every helper calls the macOS 14 API unchanged when it is available (`if #available`), so the
// macOS 14+ behaviour is exactly the native one; the fallback branch only runs on macOS 13.

extension View {
    /// `onChange(of:) { old, new in }` (macOS 14). macOS 13: `onChange(of:perform:)`, the old value being the one this
    /// view was last built with (captured when the body ran), which is what the macOS 14 variant passes too.
    @ViewBuilder
    func onValueChange<V: Equatable>(of value: V, _ action: @escaping (_ old: V, _ new: V) -> Void) -> some View {
        if #available(macOS 14, *) {
            onChange(of: value, action)
        } else {
            onChange(of: value) { [value] new in action(value, new) }
        }
    }

    /// `onChange(of:) { }` (macOS 14). macOS 13: `onChange(of:perform:)`.
    @ViewBuilder
    func onValueChange<V: Equatable>(of value: V, _ action: @escaping () -> Void) -> some View {
        if #available(macOS 14, *) {
            onChange(of: value, action)
        } else {
            onChange(of: value) { _ in action() }
        }
    }

    /// `scrollBounceBehavior(.basedOnSize, axes: .horizontal)`, which needs macOS 13.3; on 13.0–13.2 the scroll view
    /// keeps its default bounce.
    @ViewBuilder
    func horizontalBounceBasedOnSize() -> some View {
        if #available(macOS 13.3, *) {
            scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        } else {
            self
        }
    }
}

/// Vsync callback for views that draw with Metal (player, timeline). macOS 14+ uses `NSView.displayLink(target:selector:)`
/// at the call site (unchanged); this is the macOS 13 path: a `CVDisplayLink` on the window's display whose callbacks
/// hop to the main thread (at most one pending, so a busy main thread skips vsyncs like a CADisplayLink does).
/// `tick` receives the target presentation time in `CACurrentMediaTime()` seconds, like `CADisplayLink.targetTimestamp`.
nonisolated final class LegacyDisplayLink {
    private var link: CVDisplayLink?
    private let pending = OSAllocatedUnfairLock(initialState: false)

    init(screen: NSScreen?, tick: @escaping @MainActor (CFTimeInterval) -> Void) {
        var l: CVDisplayLink?
        let display = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        if let display { CVDisplayLinkCreateWithCGDisplay(display, &l) } else { CVDisplayLinkCreateWithActiveCGDisplays(&l) }
        guard let l else { return }
        let pending = pending
        let secondsPerHostTick: Double = {
            var tb = mach_timebase_info_data_t()
            mach_timebase_info(&tb)
            return Double(tb.numer) / Double(tb.denom) / 1e9
        }()
        let box = UncheckedSendableBox(tick)
        CVDisplayLinkSetOutputHandler(l) { @Sendable _, _, outputTime, _, _ in
            let target = Double(outputTime.pointee.hostTime) * secondsPerHostTick
            let skip = pending.withLock { busy -> Bool in
                if busy { return true }
                busy = true
                return false
            }
            if !skip {
                DispatchQueue.main.async {
                    pending.withLock { $0 = false }
                    MainActor.assumeIsolated { box.value(target) }
                }
            }
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(l)
        link = l
    }

    func invalidate() {
        if let link { CVDisplayLinkStop(link) }
        link = nil
    }

    deinit { invalidate() }
}

extension View {
    /// `containerRelativeFrame(.horizontal) { w, _ in width(w) }` (macOS 14). macOS 13: the container is taken to be
    /// the window's content view (true for the title bar, the only user), tracked through window resizes.
    @ViewBuilder
    func containerRelativeWidth(_ width: @escaping (CGFloat) -> CGFloat) -> some View {
        if #available(macOS 14, *) {
            containerRelativeFrame(.horizontal) { w, _ in width(w) }
        } else {
            modifier(WindowRelativeWidth(width: width))
        }
    }
}

private struct WindowRelativeWidth: ViewModifier {
    let width: (CGFloat) -> CGFloat
    @State private var windowWidth: CGFloat?

    func body(content: Content) -> some View {
        content
            .frame(width: windowWidth.map(width))
            .background(WindowWidthReader { windowWidth = $0 })
    }
}

private struct WindowWidthReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void
    func makeNSView(context: Context) -> ReaderView { ReaderView() }
    func updateNSView(_ v: ReaderView, context: Context) { v.onChange = onChange }

    final class ReaderView: NSView {
        var onChange: ((CGFloat) -> Void)?
        private var observer: NSObjectProtocol?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let w = window else { return }
            report()
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
        }
        private func report() {
            guard let w = window?.contentView?.bounds.width else { return }
            DispatchQueue.main.async { [weak self] in self?.onChange?(w) }
        }
    }
}

/// SwiftUI on macOS 14+ tracks Observation reads made in `updateNSView`; Perception (macOS 13) only tracks view bodies,
/// so a representable that reads perceptible state there would miss changes. Such reads go through `run`: macOS 14+
/// just calls `update` (unchanged); macOS 13 records what it read and runs it again when that changes.
final class RepresentableTracking {
    private var generation = 0

    func run(_ update: @escaping @MainActor () -> Void) {
        if #available(macOS 14, *) { update(); return }
        generation &+= 1
        let g = generation
        withPerceptionTracking { update() } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == g else { return }
                self.run(update)
            }
        }
    }
}
