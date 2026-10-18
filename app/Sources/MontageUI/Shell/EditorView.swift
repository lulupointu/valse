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
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        AssetPanel(store: store).testID("panel.assets").frame(width: leftW)
                        Splitter(axis: .vertical) { dx in leftFraction = clamp((leftW + dx) / inner.width, 0.2, 0.45) }
                            .frame(width: g)
                        PlayerPanel(store: store).testID("panel.player").frame(maxWidth: .infinity)
                        Splitter(axis: .vertical) { dx in rightFraction = clamp((rightW - dx) / inner.width, 0.2, 0.45) }
                            .frame(width: g)
                        InspectorPanel(store: store).testID("panel.inspector").frame(width: rightW)
                    }
                    .frame(height: topH)
                    Splitter(axis: .horizontal) { dy in topFraction = clamp((topH + dy) / inner.height, 0.3, 0.75) }
                        .frame(height: g)
                    TimelinePanel(store: store).testID("panel.timeline")
                }
                .padding(.horizontal, Theme.Metrics.outerGutter)
                .padding(.bottom, Theme.Metrics.outerGutter)
            }
        }
        .background(Theme.window)
        .overlay(alignment: .top) { ToastView(toast: store.toast).padding(.top, 54) }
        .sheet(isPresented: $store.isExportSheetPresented) { ExportSheet(store: store) }
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
                Menu {
                    ForEach(["system", "en", "fr"], id: \.self) { lang in
                        Button(tr("settings.language.\(lang)")) { L10n.shared.setLanguagePreference(lang) }
                    }
                } label: { Image(systemName: "globe").font(.system(size: 13)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(tr("settings.language"))
                    .testID("titlebar.language")
                Button { store.isExportSheetPresented = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 11, weight: .semibold))
                        Text(loc: "titlebar.export")
                    }
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(store.project.duration == .zero)
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
            Text(verbatim: toast.message)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(toast.isError ? Color(hex: 0x8A2E2E) : Theme.menu, in: RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.4), radius: 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .id(toast.id)
        }
    }
}
