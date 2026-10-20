import SwiftUI
import Perception
import MontageCore
import MontageEngine

/// Dropped-frame telemetry of the preview (PB-013): fed with the item time of every frame the player presents while
/// playing; a frame whose time jumps by more than 1.5 frame durations counts the skipped frames as dropped. The drop
/// ratio over the last ~2 s of expected frames gives a level (CapCut "There are dropped frames" / "Video lags a lot").
public struct FrameDropMeter: Sendable, Equatable {
    public enum Level: String, Sendable { case ok, dropping, lagging }
    /// Window of expected frames the ratio is computed over.
    public var window = 60
    private var samples: [Int] = []   // 1 + dropped frames per presented frame
    private var last: Time?
    public init() {}

    public mutating func reset() { samples.removeAll(); last = nil }

    public mutating func presented(_ t: Time, frameDuration fd: Time, rate: Double = 1) {
        defer { last = t }
        guard let last, fd.ticks > 0, rate > 0 else { return }
        let step = Double((t - last).ticks) / (Double(fd.ticks) * rate)
        guard step > 0, step < 30 else { return }       // a seek / loop wrap, not a drop
        let frames = max(1, Int(step.rounded()))
        samples.append(frames)
        var total = samples.reduce(0, +)
        while total - (samples.first ?? 0) >= window { total -= samples.removeFirst() }
    }

    /// Dropped / expected frames over the window (0 until half a window was seen).
    public var dropRatio: Double {
        let expected = samples.reduce(0, +)
        guard expected >= window / 2 else { return 0 }
        return Double(expected - samples.count) / Double(expected)
    }

    public var level: Level { dropRatio >= 0.3 ? .lagging : dropRatio >= 0.08 ? .dropping : .ok }
}

/// Playback health shown by the player (PB-013) and acted on by auto optimization (PB-003): Smart lowers the preview
/// quality one step when frames drop; Deep also turns proxies on and goes down to quarter quality.
@MainActor @Perceptible
public final class PlaybackHealth {
    public private(set) var level: FrameDropMeter.Level = .ok
    /// Banner dismissed for this session.
    public var dismissed = false
    @PerceptionIgnored var meter = FrameDropMeter()
    @PerceptionIgnored weak var store: EditorStore?
    @PerceptionIgnored private var lastOptimized: Date?

    func presented(_ t: Time, playing: Bool) {
        guard let store else { return }
        guard playing else { meter.reset(); return }
        meter.presented(t, frameDuration: store.project.settings.frameRate.frameDuration)
        let l = meter.level
        guard l != level else { return }
        level = l
        if l != .ok { autoOptimize() }
    }

    /// Auto optimization (Settings ▸ Performance): lower preview cost once per 5 s of lag.
    func autoOptimize() {
        guard let store, let s = Optional(AppPreferences.shared.settings) else { return }
        let mode = AutoOptimization(rawValue: s.autoOptimization) ?? .none
        guard mode != .none else { return }
        if let lastOptimized, Date().timeIntervalSince(lastOptimized) < 5 { return }
        if optimize(store, deep: mode == .deep) {
            lastOptimized = Date()
            store.showToast(tr("playback.optimized", tr(store.previewQuality.nameKey)))
        }
    }

    /// One optimization step (also the banner's [Optimize] button). Returns false when nothing is left to lower.
    @discardableResult
    func optimize(_ store: EditorStore, deep: Bool) -> Bool {
        meter.reset(); level = .ok
        if deep, !store.playerUI.usesProxies { store.setUsesProxies(true); return true }
        let next: PreviewQuality? = switch store.previewQuality {
        case .full, .auto: .half
        case .half: deep ? .quarter : nil
        case .quarter: nil
        }
        guard let next else { return false }
        store.previewQuality = next
        return true
    }
}

/// Settings ▸ Performance ▸ Auto optimization (PB-003).
public enum AutoOptimization: String, CaseIterable, Sendable {
    case none, smart, deep
    public var nameKey: String { "settings.autoOptimization.\(rawValue)" }
}

/// Settings ▸ Performance ▸ Playback priority (PB-004).
public enum PlaybackPriority: String, CaseIterable, Sendable {
    case quality, performance
    public var nameKey: String { "settings.priority.\(rawValue)" }
    public var hintKey: String { "settings.priority.\(rawValue).hint" }
}

/// "There are dropped frames" / "Video lags a lot" banner over the bottom of the preview, with [Optimize] and ✕.
struct DroppedFramesBanner: View {
    @Perception.Bindable var store: EditorStore
    @Perception.Bindable var health: PlaybackHealth
    var body: some View {
        WithPerceptionTracking {
            if health.level != .ok && !health.dismissed {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(red: 0.91, green: 0.70, blue: 0.23))
                    Text(verbatim: tr(health.level == .lagging ? "playback.lagging" : "playback.dropping"))
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textPrimary)
                    Button(tr("playback.optimize")) {
                        if !health.optimize(store, deep: health.level == .lagging) { store.showToast(tr("playback.nothingToOptimize")) }
                    }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small).testID("player.optimize")
                    IconButton("xmark", help: tr("common.close")) { health.dismissed = true }
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Theme.menu, in: RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.35), radius: 6)
                .padding(.bottom, 10)
                .testID("player.droppedFrames")
            }
        }
    }
}
