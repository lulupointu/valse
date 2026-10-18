import SwiftUI
import MontageCore
import MontageEngine

/// Main editor window content (CapCut "Default" layout, UX.md §1.1): title bar, then asset panel / player / inspector
/// on top and the full-width timeline below, separated by draggable 6 pt gutters.
public struct EditorView: View {
    @Bindable var store: EditorStore
    @State private var topFraction: CGFloat = 0.54
    @State private var leftFraction: CGFloat = 0.34
    @State private var rightFraction: CGFloat = 0.31
    private let locale = LocaleState.shared

    public init(store: EditorStore) { self.store = store }

    public var body: some View {
        if store.playerUI.isFullscreen {
            FullscreenPlayer(store: store)
                .overlay(alignment: .top) { ToastView(toast: store.toast).padding(.top, 54) }
                .preferredColorScheme(.dark)
                .id(locale.revision)
        } else {
            editor
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            TitleBar(store: store)
            GeometryReader { geo in
                let g = Theme.Metrics.gutter
                let inner = CGSize(width: geo.size.width - 2 * Theme.Metrics.outerGutter,
                                   height: geo.size.height - Theme.Metrics.outerGutter)
                let topH = max(220, min(inner.height - 160, inner.height * topFraction))
                let leftW = max(Theme.Metrics.minAssetWidth * 0.7, inner.width * leftFraction)
                let rightW = max(Theme.Metrics.minInspectorWidth * 0.8, inner.width * rightFraction)
                // Each panel in its own hosting view (perf, W14 — see IsolatedHost): a slider tick, playhead move or
                // asset scroll lays out only its panel, not the whole window.
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        IsolatedHost { AssetPanel(store: store) }.testID("panel.assets").frame(width: leftW)
                        Splitter(axis: .vertical) { dx in leftFraction = clamp((leftW + dx) / inner.width, 0.2, 0.45) }
                            .frame(width: g)
                        IsolatedHost { PlayerPanel(store: store) }.testID("panel.player").frame(maxWidth: .infinity)
                        Splitter(axis: .vertical) { dx in rightFraction = clamp((rightW - dx) / inner.width, 0.2, 0.45) }
                            .frame(width: g)
                        IsolatedHost { InspectorPanel(store: store) }.testID("panel.inspector").frame(width: rightW)
                    }
                    .frame(height: topH)
                    Splitter(axis: .horizontal) { dy in topFraction = clamp((topH + dy) / inner.height, 0.3, 0.75) }
                        .frame(height: g)
                    IsolatedHost { TimelinePanel(store: store) }.testID("panel.timeline")
                }
                .padding(.horizontal, Theme.Metrics.outerGutter)
                .padding(.bottom, Theme.Metrics.outerGutter)
            }
        }
        .background(Theme.window)
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
        .sheet(isPresented: Binding(get: { store.ai.isModelSheetPresented }, set: { store.ai.isModelSheetPresented = $0 })) {
            ModelManagerSheet { store.ai.isModelSheetPresented = false }   // W10 AI models
        }
        .preferredColorScheme(.dark)
        .id(locale.revision)
    }

    private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), hi) }
}

/// Draggable gutter between panels.
struct Splitter: View {
    enum Axis { case vertical, horizontal }
    let axis: Axis
    let onDrag: (CGFloat) -> Void
    @State private var last: CGFloat = 0
    var body: some View {
        Rectangle().fill(Color.clear)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { (axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                let d = axis == .vertical ? v.translation.width : v.translation.height
                onDrag(d - last); last = d
            }.onEnded { _ in last = 0 })
    }
}

/// Window title bar (36 pt): autosave status, project name, shortcuts & Export (UX.md §1.1).
struct TitleBar: View {
    /// Opens the shortcut window (set by the app shell, W12 `AppModel`).
    @MainActor public static var showShortcuts: (() -> Void)?
    @Bindable var store: EditorStore
    var body: some View {
        ZStack {
            HStack(spacing: 10) {
                Spacer().frame(width: 76)  // traffic lights
                if let saved = store.lastAutosave {
                    Text(loc: "titlebar.autosaved", saved.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                // CapCut: ⌨ opens the shortcut window (language lives in Settings ▸ General)
                if let show = TitleBar.showShortcuts {
                    Button(action: show) { Image(systemName: "keyboard").font(.system(size: 13)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                        .help(tr("menu.shortcuts"))
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
            Text(verbatim: store.projectName)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.Metrics.titleBarHeight)
        .background(Theme.window)
    }
}

struct ToastView: View {
    let toast: Toast?
    var body: some View {
        if let toast {
            // CapCut (UX §9): centred white pill, black 12 pt text; errors stay red
            Text(verbatim: toast.message)
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
