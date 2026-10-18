import SwiftUI
import MontageCore
import MontageEngine

/// Top-centre player: header ("Player"), Metal preview, transport bar (timecode · play · ratio / quality).
public struct PlayerPanel: View {
    @Bindable var store: EditorStore
    public init(store: EditorStore) { self.store = store }

    public var body: some View {
        Panel {
            HStack {
                Text(loc: "panel.player").font(Theme.Fonts.panelTitle).foregroundStyle(Theme.textPrimary)
                Spacer()
                Menu {
                    Picker(tr("player.quality"), selection: $store.previewQuality) {
                        ForEach(PreviewQuality.allCases, id: \.self) { q in Text(loc: q.nameKey).tag(q) }
                    }
                } label: { Image(systemName: "line.3.horizontal").font(.system(size: 13)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(.horizontal, 12)
        } content: {
            VStack(spacing: 0) {
                PlayerHost(store: store).frame(maxWidth: .infinity, maxHeight: .infinity)
                TransportBar(store: store, transport: store.transport)
            }
        }
    }
}

struct TransportBar: View {
    @Bindable var store: EditorStore
    @Bindable var transport: TransportState

    var body: some View {
        let rate = store.project.settings.frameRate
        ZStack {
            HStack(spacing: 4) {
                Text(verbatim: Timecode.string(transport.playhead, rate: rate)).foregroundStyle(Theme.accent)
                Text(verbatim: "/").foregroundStyle(Theme.textTertiary)
                Text(verbatim: Timecode.string(store.project.duration, rate: rate)).foregroundStyle(Theme.textSecondary)
                Spacer()
                qualityMenu
                ratioMenu
                IconButton("arrow.up.left.and.arrow.down.right", help: tr("player.fullscreen")) {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
            }
            .font(.system(size: 11).monospacedDigit())
            IconButton(transport.isPlaying ? "pause.fill" : "play.fill", help: tr("player.playPause")) { store.togglePlay() }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
    }

    var qualityMenu: some View {
        Picker(selection: $store.previewQuality) {
            ForEach(PreviewQuality.allCases, id: \.self) { q in Text(loc: q.nameKey).tag(q) }
        } label: { EmptyView() }
            .pickerStyle(.menu).labelsHidden().fixedSize().controlSize(.small)
            .help(tr("player.quality"))
    }

    var ratioMenu: some View {
        Menu {
            ForEach(ProjectSettings.aspectPresets, id: \.id) { preset in
                Button(preset.id) {
                    store.perform(UpdateSettings { s in s.canvasSize = preset.size; s.aspectPreset = preset.id })
                }
            }
        } label: {
            Text(verbatim: store.project.settings.aspectPreset == "original" ? tr("player.ratio.original") : store.project.settings.aspectPreset)
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help(tr("player.ratio"))
    }
}

/// Bridges the AppKit/Metal PlayerView into SwiftUI.
struct PlayerHost: NSViewRepresentable {
    let store: EditorStore
    func makeNSView(context: Context) -> PlayerView {
        let v = PlayerView(engine: store.engine)
        SnapshotRegistry.shared.player = v
        return v
    }
    func updateNSView(_ v: PlayerView, context: Context) { v.requestRedraw() }
}
