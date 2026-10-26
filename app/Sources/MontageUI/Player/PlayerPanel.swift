import SwiftUI
import AppKit
import MontageCore
import MontageEngine
import Perception

/// Top-centre player (UX.md §4.1): header ("Player" + ☰ menu), Metal preview with the canvas overlay, transport bar
/// (timecode · play · quality · zoom · ratio · full screen).
public struct PlayerPanel: View {
    @Perception.Bindable var store: EditorStore
    public init(store: EditorStore) { self.store = store }

    public var body: some View {
        WithPerceptionTracking {
            Panel {
                HStack {
                    if let pv = store.playerUI.preview {
                        // "Previewing — Effects" (UX.md §4.1): library / source preview, Esc or ✕ returns to the timeline
                        Text(verbatim: tr("player.previewing", tr(pv.titleKey))).font(Theme.Fonts.panelTitle)
                            .foregroundStyle(Theme.textPrimary).testID("player.previewTitle")
                        IconButton("xmark", help: tr("player.preview.exit")) { store.exitPreview() }.testID("player.exitPreview")
                    } else {
                        Text(loc: "panel.player").font(Theme.Fonts.panelTitle).foregroundStyle(Theme.textPrimary)
                    }
                    Spacer()
                    PlayerMenuButton(store: store)
                }
                .padding(.horizontal, 12)
            } content: {
                VStack(spacing: 0) {
                    PlayerCanvasArea(store: store)
                    TransportBar(store: store, transport: store.transport, ui: store.playerUI)
                }
            }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { AssetPanelFocus.playerFrame = $0 }
        }
    }
}

/// Preview + overlay + floating zoom bar.
struct PlayerCanvasArea: View {
    @Perception.Bindable var store: EditorStore
    var body: some View {
        WithPerceptionTracking {
            ZStack(alignment: .bottom) {
                PlayerHost(store: store).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottomLeading) { KeystrokeOverlay() }
                    .overlay(alignment: .top) { GuidePositionPopover(store: store, ui: store.playerUI).padding(.top, 40) }
                    .overlay(alignment: .topTrailing) { HDRDisplayNotice(store: store) }
                    .overlay { MulticamGrid(store: store, ui: store.playerUI) }   // PB-016
                if store.playerUI.isZoomBarVisible {
                    ZoomBar(ui: store.playerUI, store: store).padding(.bottom, 10)
                } else {
                    DroppedFramesBanner(store: store, health: store.playerUI.health)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// ⊖ ──●── ⊕ 100 % [fit] (UX.md §4.1, screenshot 105). Logarithmic slider over `PlayerViewport.zoomRange`.
struct ZoomBar: View {
    @Perception.Bindable var ui: PlayerUIState
    let store: EditorStore
    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 8) {
                IconButton("minus.magnifyingglass", help: tr("shortcut.playerZoomOut")) { store.zoomPlayer(by: 0.8) }
                Slider(value: Binding.perceived(get: { log2(ui.zoom) }, set: { v in
                    ui.zoom = pow(2, v)
                    if ui.zoom <= 1 { ui.pan = .zero }
                }), in: log2(PlayerViewport.zoomRange.lowerBound)...log2(PlayerViewport.zoomRange.upperBound))
                .controlSize(.mini).frame(width: 120)
                IconButton("plus.magnifyingglass", help: tr("shortcut.playerZoomIn")) { store.zoomPlayer(by: 1.25) }
                Text(verbatim: "\(Int((ui.zoom * 100).rounded()))%").font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary).frame(width: 40)
                Button(tr("player.zoom.fit")) { store.resetPlayerZoom() }.buttonStyle(SecondaryButtonStyle()).controlSize(.small)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Theme.menu, in: RoundedRectangle(cornerRadius: 8))
            .valseFloatingCard(radius: 8, depth: 3)
        }
    }
}

struct TransportBar: View {
    @Perception.Bindable var store: EditorStore
    @Perception.Bindable var transport: TransportState
    @Perception.Bindable var ui: PlayerUIState

    var body: some View {
        WithPerceptionTracking {
            let rate = store.projectSettings.frameRate
            ZStack {
                HStack(spacing: 4) {
                    // while previewing a library item the timecode shows the item's own time / duration
                    let pv = ui.preview
                    let now = pv.map { (ui.previewTime - $0.range.start).clamped(.zero, $0.range.duration) } ?? transport.playhead
                    TimecodeEntry(store: store, time: now, rate: rate, editable: pv == nil)
                    Text(verbatim: "/").foregroundStyle(Theme.textTertiary)
                    Text(verbatim: Timecode.display(pv?.range.duration ?? store.projectDuration, rate: rate)).foregroundStyle(Theme.textSecondary)
                        .testID("player.duration")
                    Spacer()
                    PopupButton(help: tr("player.quality")) { BoxLabel(text: tr(PlayerMenus.qualityShortKey(store.previewQuality))) }
                        menu: { PlayerMenus.quality(store) }
                    IconButton("plus.magnifyingglass", help: tr("player.zoom"), active: ui.isZoomBarVisible || ui.isZoomed) {
                        ui.isZoomBarVisible.toggle()
                    }
                    PopupButton(help: "") { BoxLabel(text: tr("player.ratio")) } menu: { PlayerMenus.ratio(store) }
                    Rectangle().fill(Theme.separator).frame(width: 1, height: 14).padding(.horizontal, 2)
                    IconButton(ui.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                               help: tr(ui.isFullscreen ? "player.exitFullscreen" : "player.fullscreen")) {
                        store.togglePlayerFullscreen()
                    }
                }
                .font(.system(size: 11).monospacedDigit())
                HStack(spacing: 2) {
                    IconButton(transport.isPlaying ? "pause.fill" : "play.fill", help: tr("player.playPause")) { store.togglePlay() }.testID("player.play")
                    if ui.loopEnabled {
                        IconButton("repeat", help: tr("player.loop"), active: true) { store.toggleLoop() }
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .opacity(store.isPlayerEmpty ? 0.35 : 1)
            .disabled(store.isPlayerEmpty)
        }
    }
}

/// Current-time timecode of the player (TL-037): click to type a timecode (HH:MM:SS:FF, digits right-aligned, `+10` /
/// `-1:00` relative), Return seeks there (clamped to the project), Esc cancels. Format follows Settings ▸ Edit ▸ Time code.
struct TimecodeEntry: View {
    @Perception.Bindable var store: EditorStore
    let time: Time
    let rate: FrameRate
    var editable = true
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        WithPerceptionTracking {
            let label = Timecode.display(time, rate: rate)
            if editing {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.accent)
                    .frame(width: CGFloat(label.count) * 7 + 8)
                    .padding(.horizontal, 2)
                    .background(Theme.inset, in: RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.accent.opacity(0.8), lineWidth: 1))
                    .focused($focused)
                    .onSubmit { commit() }
                    .onExitCommand { editing = false }
                    .onValueChange(of: focused) { _, f in if !f { editing = false } }
                    .onAppear { text = label; focused = true }
                    .testID("player.timecode.field")
            } else {
                Text(verbatim: label).foregroundStyle(Theme.accent)
                    .contentShape(Rectangle())
                    .onTapGesture { if editable && !store.isPlayerEmpty { store.engine.pause(); editing = true } }
                    .help(tr("player.timecode.help"))
                    .testID("player.timecode")
            }
        }
    }

    func commit() {
        let d = TimecodeDisplay.current
        if let t = Timecode.parse(text, rate: rate, style: d.style, dropFrame: d.dropFrame, relativeTo: time) {
            store.seek(to: rate.snap(t.clamped(.zero, store.projectDuration)))
        } else {
            store.showToast(tr("player.timecode.invalid"), error: true)
        }
        editing = false
    }
}

extension EditorStore {
    /// Nothing to play: empty timeline and no library preview (dimmed transport, no frame).
    var isPlayerEmpty: Bool { playerUI.preview == nil && project.duration <= .zero }
}

/// Small outlined label used by CapCut's "Full" / "Ratio" buttons.
struct BoxLabel: View {
    let text: String
    var body: some View {
        WithPerceptionTracking {
            Text(verbatim: text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 3).frame(height: 15)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.textPrimary.opacity(0.85), lineWidth: 1))
                .padding(.horizontal, 4)
        }
    }
}

/// A button that pops up an AppKit menu (two-line items, custom images, checkmarks — like CapCut's player menus).
struct PopupButton<Label: View>: View {
    let help: String
    @ViewBuilder let label: () -> Label
    let menu: () -> NSMenu
    var body: some View {
        WithPerceptionTracking {
            Button {
                let m = menu()
                m.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            } label: { label().contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help(help)
        }
    }
}

/// Header ☰ menu: guides & rulers, safe zones, loop, proxies, export still frame (UX.md §4.1, screenshot 107).
struct PlayerMenuButton: View {
    let store: EditorStore
    var body: some View {
        WithPerceptionTracking {
            PopupButton(help: tr("player.menu")) {
                Image(systemName: "line.3.horizontal").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    .frame(width: 24, height: 24)
            } menu: { PlayerMenus.main(store) }
        }
    }
}

@MainActor
enum PlayerMenus {
    static func qualityShortKey(_ q: PreviewQuality) -> String { "player.quality.\(q.rawValue).short" }
    /// Menu order: Full, High (auto), Medium (1/2), Low (1/4).
    static let qualities: [PreviewQuality] = [.full, .auto, .half, .quarter]

    static func item(_ title: String, checked: Bool = false, enabled: Bool = true, key: String = "",
                     mods: NSEvent.ModifierFlags = [], _ action: @escaping () -> Void) -> NSMenuItem {
        let i = PlayerMenuAction.item(title, action)
        i.state = checked ? .on : .off
        i.isEnabled = enabled
        if !key.isEmpty { i.keyEquivalent = key; i.keyEquivalentModifierMask = mods }
        return i
    }

    static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title)
        m.autoenablesItems = false
        items.forEach(m.addItem)
        i.submenu = m
        return i
    }

    static func quality(_ store: EditorStore) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        for q in qualities {
            let i = item("", checked: store.previewQuality == q) { store.previewQuality = q }
            let title = NSMutableAttributedString(string: tr("player.quality.\(q.rawValue).title") + "\n",
                                                  attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])
            title.append(NSAttributedString(string: tr("player.quality.\(q.rawValue).detail"),
                                            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            i.attributedTitle = title
            m.addItem(i)
        }
        m.addItem(.separator())
        m.addItem(item(tr("player.proxy"), checked: store.playerUI.usesProxies) { store.setUsesProxies(!store.playerUI.usesProxies) })
        return m
    }

    static func ratio(_ store: EditorStore) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let current = store.project.settings.aspectPreset
        m.addItem(item(tr("player.ratio.original"), checked: current == "original") { store.setRatio("original") })
        m.addItem(item(tr("player.ratio.custom"), checked: current == "custom") { CustomCanvasPanel.run(store) })
        m.addItem(.separator())
        for id in ProjectSettings.ratioMenu {
            guard let id, let size = ProjectSettings.presetSize(id) else { m.addItem(.separator()); continue }
            let i = item(tr("player.ratio.\(id)"), checked: current == id) { store.setRatio(id) }
            i.image = ratioIcon(size)
            m.addItem(i)
        }
        return m
    }

    /// Outline rectangle of the ratio (shown at the right of each Ratio row in CapCut; AppKit shows it at the left).
    static func ratioIcon(_ size: Size2) -> NSImage {
        let box = NSSize(width: 18, height: 16)
        return NSImage(size: box, flipped: false) { _ in
            let k = min(16 / size.width, 13 / size.height)
            let w = size.width * k, h = size.height * k
            let r = NSRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h).insetBy(dx: 0.5, dy: 0.5)
            NSColor.labelColor.withAlphaComponent(0.8).setStroke()
            let p = NSBezierPath(rect: r); p.lineWidth = 1; p.stroke()
            return true
        }
    }

    static func main(_ store: EditorStore) -> NSMenu {
        let ui = store.playerUI
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(submenu(tr("player.guidesRulers"), [
            item(tr("player.guide.addH")) { ui.guides.append(CanvasGuide(axis: .horizontal, position: 0.5)); ui.showGuides = true },
            item(tr("player.guide.addV")) { ui.guides.append(CanvasGuide(axis: .vertical, position: 0.5)); ui.showGuides = true },
            item(tr("player.guide.edit"), enabled: !ui.guides.isEmpty) { ui.editingGuide = ui.guides.last?.id; ui.showGuides = true },
            item(tr("player.guide.lock"), checked: ui.guidesLocked, enabled: !ui.guides.isEmpty) { ui.guidesLocked.toggle() },
            item(tr("player.guide.show"), checked: ui.showGuides, enabled: !ui.guides.isEmpty, key: ";", mods: .command) { ui.showGuides.toggle() },
            item(tr("player.guide.clear"), enabled: !ui.guides.isEmpty) { ui.guides.removeAll() },
            .separator(),
            item(tr("player.rulers"), checked: ui.showRulers, key: "r", mods: [.command, .option]) { ui.showRulers.toggle() },
        ]))
        m.addItem(submenu(tr("player.scope"), ScopeMode.allCases.map { s in
            item(tr(s.titleKey), checked: ui.scope == s) { ui.scope = s }
        }))
        m.addItem(submenu(tr("player.safe"), SafeZone.allCases.map { z in
            item(tr(z.titleKey), checked: ui.safeZone == z) { ui.safeZone = z }
        }))
        m.addItem(.separator())
        m.addItem(item(tr("player.loop"), checked: ui.loopEnabled) { store.toggleLoop() })
        m.addItem(item(tr("player.fullscreen"), key: "f", mods: [.command, .shift]) { store.togglePlayerFullscreen() })
        m.addItem(.separator())
        m.addItem(item(tr("player.exportStill"), enabled: store.project.duration > .zero) { store.exportStillFrame() })
        return m
    }
}

/// "Customized" ratio: width × height in pixels.
@MainActor
enum CustomCanvasPanel {
    static func run(_ store: EditorStore) {
        let s = store.project.settings.canvasSize
        let alert = NSAlert()
        alert.messageText = tr("player.ratio.custom.title")
        alert.informativeText = tr("player.ratio.custom.detail")
        let w = NSTextField(string: "\(Int(s.width))"), h = NSTextField(string: "\(Int(s.height))")
        for f in [w, h] { f.frame.size.width = 80; f.alignment = .right }
        let x = NSTextField(labelWithString: "×")
        let stack = NSStackView(views: [w, x, h])
        stack.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        alert.accessoryView = stack
        alert.addButton(withTitle: tr("player.ok"))
        alert.addButton(withTitle: tr("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn, let wv = Double(w.stringValue), let hv = Double(h.stringValue),
              wv > 0, hv > 0 else { return }
        store.setCustomCanvas(width: wv, height: hv)
    }
}

/// Bridges the AppKit/Metal player (preview + canvas overlay) into SwiftUI.
struct PlayerHost: NSViewRepresentable {
    let store: EditorStore
    func makeNSView(context: Context) -> PlayerContainerView {
        let v = PlayerContainerView(store: store)
        v.player.setAccessibilityIdentifier("player")
        v.player.setAccessibilityLabel(tr("ax.player"))   // SE-017
        v.player.setAccessibilityRole(.image)
        SnapshotRegistry.shared.player = v.player
        SnapshotRegistry.shared.playerOverlay = v.overlay
        return v
    }
    func updateNSView(_ v: PlayerContainerView, context: Context) { v.player.requestRedraw() }
    /// Fills the proposal (perf: without this SwiftUI measures the AppKit view with Auto Layout `fittingSize` on every pass).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PlayerContainerView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 10, height: 10))
    }
}

/// Metal preview with the transparent canvas overlay on top.
final class PlayerContainerView: NSView {
    let player: PlayerView
    let overlay: CanvasOverlayView

    init(store: EditorStore) {
        player = PlayerView(engine: store.engine)
        overlay = CanvasOverlayView(store: store)
        super.init(frame: .zero)
        addSubview(player)
        addSubview(overlay)
        overlay.onContentRectChange = { [weak player] r in player?.contentRect = r }
        overlay.frameSampler = { [weak player] in player?.sampleFrame() }
        let health = store.playerUI.health
        health.store = store
        player.onFramePresented = { [weak health, weak store] t in health?.presented(t, playing: store?.engine.isPlaying ?? false) }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        player.frame = bounds
        overlay.frame = bounds
    }
}

/// PB-014: an HDR project on a display without EDR headroom gets "Device does not support HDR — preview tone-mapped"
/// (CapCut's "Devices not supporting HDR"); EDR displays show HDR directly (PlayerView.configureColor).
struct HDRDisplayNotice: View {
    let store: EditorStore
    var body: some View {
        WithPerceptionTracking {
            if store.projectSettings.colorSpace.isHDR,
               (NSApp.mainWindow?.screen ?? NSScreen.main)?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1 <= 1 {
                HStack(spacing: 4) {
                    Image(systemName: "sun.max.trianglebadge.exclamationmark").font(.system(size: 10))
                    Text(loc: "player.hdr.unsupported").font(.system(size: 10.5))
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.black.opacity(0.55), in: Capsule())
                .padding(8)
                .allowsHitTesting(false)
                .testID("player.hdrUnsupported")
            }
        }
    }
}
