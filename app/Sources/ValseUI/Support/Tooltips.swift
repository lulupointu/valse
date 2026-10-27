import AppKit
import SwiftUI

/// App-wide hover tooltips (C3-4, C6-4).
///
/// CapCut shows its dark hint pill after a short pause (~0.2 s) and drops it the moment the mouse leaves. AppKit's
/// tooltip manager (behind SwiftUI's `.help()`) can't do that: its delay is process-wide, it lingers after the mouse
/// leaves, and once one tooltip is visible the next element's tooltip shows instantly. So every `.help(_: String)` in
/// ValseUI goes through a small custom system instead:
/// - `View.help(_:)` below shadows SwiftUI's String overload inside this module: existing and future `.help(tr(…))`
///   sites need no change. It keeps the text as the accessibility hint (AXHelp on macOS, what VoiceOver read before)
///   and adds an invisible `TooltipAnchorView` behind the view (tracking area only, never hit-tested).
/// - `TooltipCenter` shows one pill window under the hovered anchor after `showDelay`, every time (moving from one
///   element to the next restarts the delay: no "already visible" instant mode), hides it on exit, click, scroll or key.
public enum Tooltips {
    /// Delay before a hover tooltip appears (CapCut ≈ 0.2 s). It disappears immediately when the mouse leaves.
    public static let initialDelayMilliseconds = 200
    static var showDelay: TimeInterval { Double(initialDelayMilliseconds) / 1000 }
    static let defaultsKey = "NSInitialToolTipDelay"

    /// Call before `NSApplication.run()` (ValseApp/main.swift). The few remaining AppKit tooltips (NSMenu items)
    /// use the same delay; registration domain only, so nothing is written to the user's defaults.
    public static func install(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [defaultsKey: initialDelayMilliseconds])
    }

    /// Effective AppKit delay in milliseconds.
    public static func currentDelayMilliseconds(_ defaults: UserDefaults = .standard) -> Int {
        defaults.object(forKey: defaultsKey) == nil ? 1000 : defaults.integer(forKey: defaultsKey)
    }
}

extension View {
    /// Valse tooltip (shadows SwiftUI's `help(_: StringProtocol)` for `String` arguments in ValseUI, see `Tooltips`).
    /// The text stays the accessibility help of the view. An empty text adds nothing.
    ///
    /// Policy (FB-10, owner): a tooltip must add something. Put one on symbol-only controls (icon buttons, ⓘ, status
    /// dots) and where the visible text is not clear on its own (it explains an action / a consequence, shows a full
    /// path or file name that is truncated, a date…). Never on a control whose visible label already says it all
    /// ("Add text" on "Add text", an effect tile's name under the tile). Shortcuts go in the tooltip of icon-only
    /// controls (or when the tooltip already adds information), not as the only content on a labelled button.
    func help(_ text: String) -> some View { modifier(TooltipModifier(text: text)) }
}

struct TooltipModifier: ViewModifier {
    let text: String
    func body(content: Content) -> some View {
        if text.isEmpty {
            content
        } else {
            content
                .background(TooltipAnchor(text: text).allowsHitTesting(false).accessibilityHidden(true))
                .accessibilityHint(Text(verbatim: text))
        }
    }
}

struct TooltipAnchor: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> TooltipAnchorView { TooltipAnchorView(text: text) }
    func updateNSView(_ v: TooltipAnchorView, context: Context) { v.text = text }
    static func dismantleNSView(_ v: TooltipAnchorView, coordinator: ()) { v.center.exit(v) }
}

/// Invisible view behind a `.help()` element: reports enter / exit to `TooltipCenter`. Never takes clicks.
final class TooltipAnchorView: NSView {
    var text: String { didSet { if text != oldValue { center.textChanged(self) } } }
    let center: TooltipCenter
    private var area: NSTrackingArea?

    init(text: String, center: TooltipCenter = .shared) {
        self.text = text
        self.center = center
        super.init(frame: .zero)
        center.register(self)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }
    override func mouseEntered(with event: NSEvent) { center.enter(self) }
    override func mouseExited(with event: NSEvent) { center.exit(self) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { center.exit(self) }
    }
    override func viewDidHide() { super.viewDidHide(); center.exit(self) }

    /// Anchor rect in window coordinates, nil when not on screen (no window, hidden, scrolled out).
    var windowRect: CGRect? {
        guard let w = window, !isHiddenOrHasHiddenAncestor else { return nil }
        // visibleRect is empty in a window that isn't ordered in, and SwiftUI's platform-view hosts can report it
        // larger than the view: clip the bounds with it instead of using it alone.
        let full = convert(bounds, to: nil)
        let r = w.isVisible ? full.intersection(convert(visibleRect, to: nil)) : full
        guard r.width > 0, r.height > 0 else { return nil }
        return r
    }
}

/// The single tooltip of the app (state machine + pill window). `TooltipCenter.shared` in the app; tests make their own.
@MainActor
final class TooltipCenter {
    static let shared = TooltipCenter()

    let delay: TimeInterval
    /// Anchor under the mouse (pending or shown).
    private weak var current: TooltipAnchorView?
    /// Anchor whose tooltip was dismissed by a click / scroll / key: it stays hidden until the mouse leaves it.
    private weak var dismissed: TooltipAnchorView?
    private var timer: DispatchWorkItem?
    private(set) var shownText: String?
    private var window: TooltipWindow?
    private let anchors = NSHashTable<TooltipAnchorView>.weakObjects()
    private var monitor: Any?
    /// Whether the pill window is ordered on screen (off in unit tests).
    var ordersWindow = true

    init(delay: TimeInterval = Tooltips.showDelay) { self.delay = delay }

    /// Text of the anchor waiting for the delay (state dump / tests).
    var pendingText: String? { shownText == nil ? current?.text : nil }

    func register(_ a: TooltipAnchorView) {
        anchors.add(a)
        installMonitor()
    }

    func enter(_ a: TooltipAnchorView) {
        guard current !== a else { return }
        guard !Self.coveredByModal(a) else { if let c = current { exit(c) }; return }   // FB-07
        if dismissed !== a { dismissed = nil }   // the mouse left the dismissed element
        hide()
        current = a
        guard dismissed !== a else { return }
        let item = DispatchWorkItem { [weak self, weak a] in
            MainActor.assumeIsolated {
                guard let self, let a, self.current === a else { return }
                self.show(a)
            }
        }
        timer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func exit(_ a: TooltipAnchorView) {
        if dismissed === a { dismissed = nil }
        guard current === a else { return }
        current = nil
        hide()
    }

    func textChanged(_ a: TooltipAnchorView) {
        guard current === a, shownText != nil else { return }
        show(a)
    }

    /// FB-07: an anchor under an in-window modal (outside its card) never shows its tooltip.
    static func coveredByModal(_ a: TooltipAnchorView) -> Bool {
        guard ModalHoverGate.isActive(in: a.window) else { return false }
        guard let r = a.windowRect else { return true }
        return ModalHoverGate.isBlocked(CGPoint(x: r.midX, y: r.midY), in: a.window)
    }

    /// A modal just appeared: drop the tooltip of an element it covers.
    func modalDidAppear() {
        if let c = current, Self.coveredByModal(c) { exit(c) }
    }

    /// Click, scroll or key press: the tooltip goes away and stays away until the mouse enters another element.
    func dismissForInteraction() {
        guard let c = current else { return }
        dismissed = c
        hide()
    }

    private func hide() {
        timer?.cancel()
        timer = nil
        shownText = nil
        window?.orderOut(nil)
    }

    private func show(_ a: TooltipAnchorView) {
        timer = nil
        shownText = a.text
        guard ordersWindow, let host = a.window, let rect = a.windowRect else { return }
        let w = window ?? TooltipWindow()
        window = w
        w.setText(a.text)
        w.setFrameOrigin(TooltipWindow.origin(size: w.frame.size, anchor: host.convertToScreen(rect),
                                              screen: (host.screen ?? NSScreen.main)?.visibleFrame))
        w.orderFront(nil)
    }

    private func installMonitor() {
        guard monitor == nil, self === TooltipCenter.shared else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]) { e in
            MainActor.assumeIsolated { TooltipCenter.shared.dismissForInteraction() }
            return e
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TooltipCenter.shared.dismissForInteraction() }
        }
    }

    /// Synthetic mouse moves (UI test driver): AppKit only fires tracking areas for real mouse moves, so the driver
    /// resolves the anchor under the point itself (smallest visible anchor containing it).
    func mouseMoved(to p: CGPoint, in w: NSWindow) {
        let hit = anchors.allObjects
            .filter { $0.window === w }
            .compactMap { a in a.windowRect.flatMap { $0.contains(p) ? (a, $0.width * $0.height) : nil } }
            .min { $0.1 < $1.1 }?.0
        if let hit { enter(hit) } else if let c = current { exit(c) }
    }
}

/// Dark pill (UX.md §9: `#000` at 85 %, 12 pt white, radius 4) in a borderless, click-through, non-activating panel.
final class TooltipWindow: NSPanel {
    private let label = NSTextField(wrappingLabelWithString: "")
    static let maxTextWidth: CGFloat = 280
    static let gap: CGFloat = 4

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .popUpMenu
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        bg.layer?.cornerRadius = 4
        label.font = .systemFont(ofSize: 12)
        label.textColor = .white
        label.preferredMaxLayoutWidth = Self.maxTextWidth
        label.setAccessibilityElement(false)
        bg.addSubview(label)
        contentView = bg
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setText(_ text: String) {
        label.stringValue = text
        // U1: measure the WRAPPED text. `fittingSize` gives the one-line size, so a text wider than `maxTextWidth` was
        // clamped to that width with a one-line height and its second line cut off ("Double-cliquez pour lire à partir de").
        let s = Self.textSize(text, font: label.font ?? .systemFont(ofSize: 12))
        let size = CGSize(width: s.width + 16, height: s.height + 8)
        label.frame = CGRect(x: 8, y: 4, width: size.width - 16, height: size.height - 8)
        setContentSize(size)
    }

    /// Size of `text` wrapped at `maxTextWidth` (rounded up to whole points).
    static func textSize(_ text: String, font: NSFont) -> CGSize {
        let cell = NSTextFieldCell(textCell: text)
        cell.font = font
        cell.wraps = true
        cell.lineBreakMode = .byWordWrapping
        let s = cell.cellSize(forBounds: CGRect(x: 0, y: 0, width: maxTextWidth, height: 10_000))
        return CGSize(width: ceil(min(s.width, maxTextWidth)), height: ceil(s.height))
    }

    /// Visible label (tests).
    var labelFrame: CGRect { label.frame }

    /// Centred under the anchor (above it when there's no room below), kept inside the screen's visible frame.
    static func origin(size: CGSize, anchor: CGRect, screen: CGRect?) -> CGPoint {
        var p = CGPoint(x: anchor.midX - size.width / 2, y: anchor.minY - gap - size.height)
        guard let s = screen else { return p }
        if p.y < s.minY { p.y = anchor.maxY + gap }
        p.x = min(max(p.x, s.minX + 2), s.maxX - size.width - 2)
        return p
    }
}
