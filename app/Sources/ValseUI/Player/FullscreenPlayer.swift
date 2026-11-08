import SwiftUI
import ValseCore
import Perception

/// Player-only full screen (PB-006, ⇧⌘F; PB-006b overlay transport): the picture fills the window on black, a click
/// plays / pauses, a double-click or esc leaves (a viewing mode, owner Q1 = A). The transport is an overlay over the
/// bottom of the picture that shows when the mouse moves and fades out after 3 s without movement
/// (`FullscreenControlsModel`). Also the content of the detached player window in native full screen (owner Q8 = A).
public struct FullscreenPlayer: View {
    @Perception.Bindable var store: EditorStore

    public init(store: EditorStore) { self.store = store }

    public var body: some View {
        WithPerceptionTracking {
            let model = store.playerUI.fullscreenControls
            ZStack(alignment: .bottom) {
                PlayerCanvasArea(store: store, bannerInset: model.isShown ? FullscreenControls.height : 0)
                FullscreenInput(store: store)
                FullscreenProgressLine(store: store, transport: store.transport, model: model)
                FullscreenControls(store: store, transport: store.transport, ui: store.playerUI, model: model)
            }
            .background(Color.black)
            .testID("fullscreen.player")
        }
    }
}

/// Thin progress line along the bottom edge after a key while the bar is hidden (owner Q3 = B): 3 pt, no buttons,
/// no cursor, 1.5 s.
struct FullscreenProgressLine: View {
    let store: EditorStore
    @Perception.Bindable var transport: TransportState
    @Perception.Bindable var model: FullscreenControlsModel
    var body: some View {
        WithPerceptionTracking {
            let on = model.isFlashing && !model.isShown
            GeometryReader { geo in
                WithPerceptionTracking {
                    let s = ScrubSource(store)
                    let f = s.duration > .zero ? min(max(s.now.seconds / s.duration.seconds, 0), 1) : 0
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.25))
                        Rectangle().fill(Color(hex: 0xF3E9C8).opacity(0.95)).frame(width: geo.size.width * f)
                    }
                }
            }
            .frame(height: 3)
            .background { if on { Color.clear.reportsSnapshotFrame { SnapshotRegistry.shared.floatingFrames["fullscreen.progressLine"] = $0 } } }
            .opacity(on ? 1 : 0)
            .animation(on ? nil : .easeIn(duration: 0.35), value: on)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .testID("fullscreen.progressLine")
        }
    }
}

/// The overlay bar (spec §3): scrim, full-width seek bar, control row ▶ · timecode · context · loop · exit
/// (owner Q7 = A, minimal).
struct FullscreenControls: View {
    /// Scrubber row (32) + control row (44) + bottom inset (16).
    static let height: CGFloat = 92
    static let margin: CGFloat = 24

    let store: EditorStore
    @Perception.Bindable var transport: TransportState
    @Perception.Bindable var ui: PlayerUIState
    @Perception.Bindable var model: FullscreenControlsModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 0

    var body: some View {
        WithPerceptionTracking {
            let shown = model.isShown && width >= 320
            VStack(spacing: 0) {
                FullscreenScrubber(store: store)
                    .frame(height: FullscreenScrubberView.height)
                    .testID("fullscreen.scrubber")
                    .padding(.horizontal, Self.margin)
                    .overlay(alignment: .bottomLeading) { FullscreenHoverTip(store: store, model: model, rowWidth: width) }
                controlRow
                    .frame(height: 44)
                    .contentShape(Rectangle())   // a click between the buttons is not a click on the picture
                    .padding(.horizontal, Self.margin - 6)
                Color.clear.frame(height: 16)
            }
            .background(alignment: .bottom) { scrim }
            .frame(maxWidth: .infinity)
            .background { if shown { Color.clear.reportsSnapshotFrame { SnapshotRegistry.shared.floatingFrames["fullscreen.controls"] = $0 } } }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
            .opacity(shown ? (store.isPlayerEmpty ? 0.35 : 1) : 0)
            .allowsHitTesting(shown && !store.isPlayerEmpty)
            .animation(shown ? .easeOut(duration: reduceMotion ? 0.08 : 0.15) : .easeIn(duration: reduceMotion ? 0.08 : 0.35), value: shown)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(tr("fullscreen.controls"))
            .testID("fullscreen.controls")
        }
    }

    private var scrim: some View {
        let k = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.85 : 0.7
        return LinearGradient(colors: [.black.opacity(0), .black.opacity(k)], startPoint: .top, endPoint: .bottom)
            .frame(height: 140)
            .allowsHitTesting(false)
    }

    private var controlRow: some View {
        HStack(spacing: 6) {
            FullscreenGlyph(transport.isPlaying ? "pause.fill" : "play.fill", size: 22,
                            help: tr(transport.isPlaying ? "fullscreen.pause" : "fullscreen.play")) { store.togglePlay() }
                .testID("fullscreen.play")
            timecode
            Spacer(minLength: 12)
            FullscreenContextChip(store: store, maxWidth: max(80, width * 0.4))
            Spacer(minLength: 12)
            FullscreenGlyph("repeat", size: 17, help: tr("fullscreen.loop"), tint: ui.loopEnabled ? Theme.accentText : nil) { store.toggleLoop() }
                .testID("fullscreen.loop")
            FullscreenGlyph("arrow.down.right.and.arrow.up.left", size: 17, help: tr("player.exitFullscreen")) { store.exitViewingFullscreen() }
                .testID("fullscreen.exit")
        }
    }

    private var timecode: some View {
        let rate = store.projectSettings.frameRate
        let s = ScrubSource(store)
        return HStack(spacing: 4) {
            TimecodeEntry(store: store, time: s.now, rate: rate, editable: !s.isPreview, fontSize: 13, color: Theme.accentText,
                          idPrefix: "fullscreen") { e in if e { model.pin(.timecode) } else { model.unpin(.timecode) } }
            Text(verbatim: "/ " + Timecode.display(s.duration, rate: rate))
                .foregroundStyle(Theme.textPrimary.opacity(0.7))
                .testID("fullscreen.duration")
        }
        .font(.system(size: 13).monospacedDigit())
        .padding(.leading, 4)
    }
}

/// A glyph button of the overlay: 32×32 hit target, white glyph with a soft shadow (legible on any footage).
struct FullscreenGlyph: View {
    let symbol: String
    let size: CGFloat
    let help: String
    var tint: Color?
    let action: () -> Void
    init(_ symbol: String, size: CGFloat, help: String, tint: Color? = nil, action: @escaping () -> Void) {
        self.symbol = symbol; self.size = size; self.help = help; self.tint = tint; self.action = action
    }
    var body: some View {
        WithPerceptionTracking {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: size, weight: .regular))
                    .foregroundStyle(tint ?? Theme.textPrimary)
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel(help)
        }
    }
}

/// Context label (owner Q5 = A / Q6 = A, not clickable): "Main timeline › Intro" inside a compound (last segment
/// semibold, truncated from the left), the timeline's name with several timelines, "Previewing — X" in a preview.
struct FullscreenContextChip: View {
    let store: EditorStore
    let maxWidth: CGFloat
    var body: some View {
        WithPerceptionTracking {
            let p = store.project
            let path = CompoundEditing.path(p)
            let slots = store.timelineSlots
            let label = FullscreenContext.label(previewTitle: store.playerUI.preview.map { tr("player.previewing", tr($0.titleKey)) },
                                                compoundPath: path, rootName: tr("compound.root"), timelineNames: slots.map(\.name),
                                                activeTimeline: slots.first { $0.id == p.activeTimelineID }?.name)
            if let label {
                chipText(label, lastBold: !path.isEmpty && store.playerUI.preview == nil)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(Color.black.opacity(0.35), in: Capsule())
                    .frame(maxWidth: maxWidth)
                    .help(label)
                    .testID("fullscreen.context")
            }
        }
    }

    @ViewBuilder private func chipText(_ s: String, lastBold: Bool) -> some View {
        if lastBold, let r = s.range(of: " › ", options: .backwards) {
            HStack(spacing: 0) {
                Text(verbatim: String(s[..<r.upperBound])).lineLimit(1).truncationMode(.head)
                Text(verbatim: String(s[r.upperBound...])).fontWeight(.semibold).lineLimit(1).layoutPriority(1)
            }
        } else {
            Text(verbatim: s).lineLimit(1).truncationMode(.head)
        }
    }
}

/// Tooltip over the seek bar (spec §3.1 / §5.1, owner Q2 = B): frame thumbnail (once rendered), time (+ marker names),
/// and the fine-scrub label while slowed down (owner Q4 = C). Centred on the pointer, clamped to the screen margins.
struct FullscreenHoverTip: View {
    let store: EditorStore
    @Perception.Bindable var model: FullscreenControlsModel
    let rowWidth: CGFloat
    @State private var tipWidth: CGFloat = 0

    var body: some View {
        WithPerceptionTracking {
            if let t = model.hoverTime {
                let rate = store.projectSettings.frameRate
                let time = Timecode.display(t, rate: rate)
                VStack(spacing: 4) {
                    if !model.isScrubbing, let img = model.thumbnails.readyImage {
                        let sz = FullscreenThumbnailLoader.pointSize(canvas: store.projectSettings.canvasSize)
                        Image(decorative: img, scale: 2).resizable().frame(width: sz.width, height: sz.height)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .testID("fullscreen.hoverThumb")
                    }
                    Text(verbatim: model.hoverLabel.map { tr("fullscreen.markerHover", time, $0) } ?? time)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .testID("fullscreen.hoverTime")
                    if let f = model.fineScrub {
                        Text(verbatim: tr("fullscreen.fineScrub") + " · " + tr(f.speedKey))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.accentText)
                            .testID("fullscreen.fineScrub")
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(Theme.menu.opacity(0.92), in: RoundedRectangle(cornerRadius: 6))
                .fixedSize()
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { tipWidth = $0 }
                .reportsSnapshotFrame { SnapshotRegistry.shared.floatingFrames["fullscreen.hoverTip"] = $0 }
                .offset(x: x, y: -(FullscreenScrubberView.height - FullscreenScrubberView.trackY + 3 + 8))
                .allowsHitTesting(false)
            }
        }
    }

    /// Leading x so the tip is centred on the pointer and stays 8 pt inside the screen.
    private var x: CGFloat {
        let c = FullscreenControls.margin + model.hoverX
        return min(max(c - tipWidth / 2, 8), max(8, rowWidth - tipWidth - 8))
    }
}
