import SwiftUI
import MontageCore
import MontageEngine
import Perception

/// Main editor window content (CapCut "Default" layout, UX.md §1.1): title bar, then asset panel / player / inspector
/// on top and the full-width timeline below, separated by draggable 6 pt gutters.
public struct EditorView: View {
    @Perception.Bindable var store: EditorStore
    @Perception.Bindable private var layout = EditorLayout.shared
    @Perception.Bindable private var onboarding = Onboarding.shared
    @Perception.Bindable private var panelFocus = PanelFocus.shared   // SE-017
    private let locale = LocaleState.shared

    public init(store: EditorStore) { self.store = store }

    public var body: some View {
        WithPerceptionTracking {
            if store.playerUI.isFullscreen {
                FullscreenPlayer(store: store)
                    .overlay(alignment: .top) { ToastView(toast: store.toast).padding(.top, 54) }
                    .preferredColorScheme(.dark)
                    .id(locale.revision)
            } else {
                editor
            }
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            TitleBar(store: store)
            GeometryReader { geo in
                WithPerceptionTracking {
                    let inner = CGSize(width: geo.size.width - 2 * Theme.Metrics.outerGutter,
                                       height: geo.size.height - Theme.Metrics.outerGutter)
                    Group {
                        if layout.preset == .vertical { verticalPanels(inner) } else { standardPanels(inner) }
                    }
                    .padding(.horizontal, Theme.Metrics.outerGutter)
                    .padding(.bottom, Theme.Metrics.outerGutter)
                }
            }
        }
        .background(Theme.window)
        .overlay(alignment: .top) {
            // P1: title-bar project switcher popover
            if let sw = ProjectSwitcher.active { ProjectSwitcherOverlay(switcher: sw) }
        }
        .overlay { QuickCutOverlay(store: store) }   // TL-048 Quick cut popover (hangs from the timeline toolbar button)
        .overlay(alignment: .top) { ToastView(toast: store.toast).padding(.top, 54) }
        .overlay(alignment: .topTrailing) {
            // W5: during UI tests the keyframe panel (normally a floating NSPanel) lives in the offscreen test window
            if TestAnchors.isEnabled && store.keyframeUI.showsPanel {
                KeyframePanel(store: store).frame(width: 500, height: 420)   // over the (SwiftUI) inspector, clear of Metal views
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.separator))
                    .testID("panel.keyframes").padding(.top, 60).padding(.trailing, 14)
            }
        }
        .overlay {
            // Export window: an in-window modal (dimmed editor, centred 720×663 dialog), like CapCut's modal window.
            if store.isExportSheetPresented { ExportModal(store: store) }
        }
        .overlay(alignment: .bottomTrailing) {
            // PB-006 during UI tests: the "detached" player is hosted here (no real window may appear on screen)
            if TestAnchors.isEnabled, let p = layout.detached.sorted(by: { $0.rawValue < $1.rawValue }).first {
                IsolatedHost { DetachedPanelsController.content(p, store) }.frame(width: 480, height: 300)
                    .testID("panel.\(p.rawValue).detached").padding(20)
            }
        }
        .overlay(alignment: .topTrailing) {
            // PM-016: the last tip points at Export (title bar)
            if onboarding.step == .export { CoachCard(step: .export).padding(.top, 44).padding(.trailing, 12) }
        }
        .overlay {
            if onboarding.showsWhatsNew {
                ZStack { Color.black.opacity(0.4).ignoresSafeArea(); WhatsNewCard() }
            }
        }
        .onAppear { onboarding.editorDidAppear() }
        .overlay {
            // MI-015 / MI-017 screen & camera recorder: in-window modal like Export
            if let m = RecordingUI.shared.model { RecorderModal(store: store, model: m) }
        }
        .overlay {
            // CV-006 crop dialog (F3): in-window modal like Export
            if let m = CropDialogState.shared.model { CropDialogModal(store: store, model: m) }
        }
        .overlay {
            // W1 cover editor (main-track "Cover" button, TL-045): in-window modal like Export
            if let m = store.timelineUI.coverEditor { CoverEditorModal(store: store, model: m) }
        }
        .overlay {
            // W10 AI clipper: in-window modal like Export

            if let st = store.ai.clipper {
                ZStack {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    AIClipperSheet(store: store, st: st) { store.ai.clipper = nil }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(radius: 20)
                }
            }
        }
        .overlay { ModelDownloadOverlay(store: store) }   // OB-07 download popup + bottom-right progress
        .sheet(isPresented: Binding.perceived(get: { store.ai.isModelSheetPresented }, set: { store.ai.isModelSheetPresented = $0 })) {
            WithPerceptionTracking {
                ModelManagerSheet { store.ai.isModelSheetPresented = false }   // W10 AI models
            }
        }
        .preferredColorScheme(.dark)
        .id(locale.revision)
    }

    private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), hi) }

    // Each panel lives in its own hosting view (perf, W14 — see IsolatedHost): a slider tick, playhead move or asset
    // scroll lays out only its panel, not the whole window. A detached panel (PB-006 / SE-006) shows a placeholder.
    @ViewBuilder private func slot(_ p: DetachablePanel, id: String) -> some View {
        Group {
            if layout.detached.contains(p) {
                DetachedPanelPlaceholder(store: store, panel: p)
            } else {
                IsolatedHost(panel: p) { DetachedPanelsController.content(p, store) }.testID(id)
            }
        }
        .overlay(alignment: p == .timeline ? .top : .center) {
            // PM-016 editor walkthrough: the tip of this panel
            if let s = onboarding.step, s.panel == p {
                CoachCard(step: s).padding(.top, p == .timeline ? 60 : 0)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent, lineWidth: 0))
            }
        }
        .overlay {
            // SE-017: keyboard focus ring (View ▸ Next panel)
            if panelFocus.current == p {
                RoundedRectangle(cornerRadius: Theme.Metrics.panelRadius).stroke(Theme.accent, lineWidth: 2).allowsHitTesting(false)
                    .testID("focusRing.\(p.rawValue)")
            }
        }
        .overlay {
            if let s = onboarding.step, s.panel == p {
                RoundedRectangle(cornerRadius: Theme.Metrics.panelRadius).stroke(Theme.accent, lineWidth: 2).allowsHitTesting(false)
            }
        }
    }
    private var assets: some View { slot(.assets, id: "panel.assets") }
    private var player: some View { slot(.player, id: "panel.player") }
    private var inspector: some View { slot(.inspector, id: "panel.inspector") }
    private var timeline: some View { slot(.timeline, id: "panel.timeline") }

    /// Default family (UX.md §1.1): asset panel / player / inspector on top, full-width timeline below.
    @ViewBuilder private func standardPanels(_ inner: CGSize) -> some View {
        let g = Theme.Metrics.gutter
        let f = layout.fractions
        let topH = max(220, min(inner.height - 160, inner.height * f.top))
        let leftW = max(Theme.Metrics.minAssetWidth * 0.7, inner.width * f.left)
        let rightW = max(Theme.Metrics.minInspectorWidth * 0.8, inner.width * f.right)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                assets.frame(width: leftW)
                Splitter(axis: .vertical, value: leftW) { w in layout.fractions.left = clamp(w / inner.width, 0.18, 0.5) }
                    .frame(width: g)
                player.frame(maxWidth: .infinity)
                Splitter(axis: .vertical, value: rightW, sign: -1) { w in layout.fractions.right = clamp(w / inner.width, 0.18, 0.5) }
                    .frame(width: g)
                inspector.frame(width: rightW)
            }
            .frame(height: topH)
            Splitter(axis: .horizontal, value: topH) { h in layout.fractions.top = clamp(h / inner.height, 0.3, 0.75) }
                .frame(height: g)
            timeline
        }
    }

    /// Vertical (9:16): a full-height player column on the right; assets + inspector over the timeline on the left.
    @ViewBuilder private func verticalPanels(_ inner: CGSize) -> some View {
        let g = Theme.Metrics.gutter
        let f = layout.fractions
        let playerW = max(320, inner.width * f.right)
        let leftColumn = inner.width - playerW - g
        let topH = max(220, min(inner.height - 160, inner.height * f.top))
        let assetW = max(Theme.Metrics.minAssetWidth * 0.7, leftColumn * f.left)
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    assets.frame(width: assetW)
                    Splitter(axis: .vertical, value: assetW) { w in layout.fractions.left = clamp(w / leftColumn, 0.3, 0.7) }
                        .frame(width: g)
                    inspector.frame(maxWidth: .infinity)
                }
                .frame(height: topH)
                Splitter(axis: .horizontal, value: topH) { h in layout.fractions.top = clamp(h / inner.height, 0.3, 0.75) }
                    .frame(height: g)
                timeline
            }
            Splitter(axis: .vertical, value: playerW, sign: -1) { w in layout.fractions.right = clamp(w / inner.width, 0.22, 0.5) }
                .frame(width: g)
            player.frame(width: playerW)
        }
    }
}

/// Draggable gutter between panels.
///
/// U1 (owner: "flicker while moving UI elements"): the drag is read in the WINDOW's coordinate space and mapped
/// absolutely (size at press + mouse travel). It used to read `DragGesture`'s default local space — the splitter's own
/// frame, which moves with every resize — and add up per-event deltas, so each event saw the mouse travel minus the
/// splitter's last move: the panel only followed half the mouse and its width alternated between two values on
/// successive frames (the owner's recording: asset panel edge 820 / 857 / 821 / 858 px…), the whole layout jittering.
struct Splitter: View {
    enum Axis { case vertical, horizontal }
    let axis: Axis
    /// The size this splitter controls (panel width / height) as currently laid out.
    let value: CGFloat
    /// +1 when dragging right / down grows `value`, −1 when it shrinks it (the panel is after the splitter).
    var sign: CGFloat = 1
    /// New size for the panel (unclamped: the caller clamps).
    let onDrag: (CGFloat) -> Void
    @State private var start: CGFloat?
    @State private var pushed = false
    var body: some View {
        WithPerceptionTracking {
            Rectangle().fill(Color.clear)
                .contentShape(Rectangle())
                .onHover { inside in
                    // FB-07: no resize cursor through a dialog; pop only what was pushed
                    if inside, !pushed, !ModalHoverGate.isActive() {
                        (axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push(); pushed = true
                    } else if !inside, pushed { NSCursor.pop(); pushed = false }
                }
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global).onChanged { v in
                    let s = start ?? value
                    if start == nil { start = s }
                    onDrag(Self.size(start: s, translation: v.translation, axis: axis, sign: sign))
                }.onEnded { _ in start = nil })
        }
    }

    /// Panel size for a drag that started at `start`: absolute, so it never drifts or oscillates.
    static func size(start: CGFloat, translation: CGSize, axis: Axis, sign: CGFloat) -> CGFloat {
        start + sign * (axis == .vertical ? translation.width : translation.height)
    }
}

/// Window title bar (36 pt): autosave status, project name, shortcuts & Export (UX.md §1.1).
struct TitleBar: View {
    /// Opens the shortcut window (set by the app shell, W12 `AppModel`).
    @MainActor public static var showShortcuts: (() -> Void)?
    @Perception.Bindable var store: EditorStore
    var body: some View {
        WithPerceptionTracking {
            ZStack {
                HStack(spacing: 10) {
                    Spacer().frame(width: 76)  // traffic lights
                    if let saved = store.lastAutosave {
                        Text(loc: "titlebar.autosaved", saved.formatted(date: .omitted, time: .standard))
                            .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    // AI2: EditPilot editing agent (AI-048), ⌘J
                    Button { store.togglePilot() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles").font(.system(size: 12))
                            Text(loc: "pilot.title").font(.system(size: 11, weight: .medium))
                        }
                    }
                    .buttonStyle(.plain).foregroundStyle(store.ai.pilot.isOpen ? Theme.accent : Theme.textSecondary)
                    .help(tr("pilot.help"))
                    .testID("titlebar.pilot")
                    LayoutMenuButton()   // SE-005
                    // CapCut: ⌨ opens the shortcut window (language lives in Settings ▸ General)
                    if let show = TitleBar.showShortcuts {
                        Button(action: show) { Image(systemName: "keyboard").font(.system(size: 13)) }
                            .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                            .help(tr("keymap.title"))
                            .testID("titlebar.shortcuts")
                    }
                    ExportQueueButton(queue: store.exports.queue)
                    Button { store.openExport() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "square.and.arrow.up").font(.system(size: 11, weight: .semibold))
                            Text(loc: "titlebar.export")
                        }
                    }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(store.projectDuration == .zero)
                    .keyboardShortcut("e", modifiers: .command)
                    .testID("titlebar.export")
                }
                ProjectSwitcherButton(store: store)   // P1: click = project switcher (⌘⇧O)
            }
            .padding(.horizontal, 10)
            .frame(height: Theme.Metrics.titleBarHeight)
            .background(Theme.window)
        }
    }
}

struct ToastView: View {
    let toast: Toast?
    var body: some View {
        WithPerceptionTracking {
            if let toast {
                // CapCut (UX §9): centred white pill, black 12 pt text; errors stay red
                HStack(spacing: 10) {
                    Text(verbatim: toast.message)
                    if let title = toast.actionTitle, let action = toast.action {   // C4: "Undo" after an instant edit
                        Button(action: action) { Text(verbatim: title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accentDim) }
                            .buttonStyle(.plain).testID("toast.action")
                    }
                }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(toast.isError ? .white : .black)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(toast.isError ? Color(hex: 0xC24040) : Color.white, in: Capsule())
                    .shadow(color: .black.opacity(TestAnchors.isEnabled ? 0 : 0.35), radius: TestAnchors.isEnabled ? 0 : 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .id(toast.id)
            }
        }
    }
}
