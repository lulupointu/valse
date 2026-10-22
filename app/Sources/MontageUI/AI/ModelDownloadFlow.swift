import SwiftUI
import MontageCore
import MontageAI
import Perception

/// OB-07: one path for every option that needs a download (AI models via `ModelManager`). The feature calls
/// `store.ai.downloads.require([spec]) { action }`: installed → the action runs at once; otherwise a popup says what
/// must be downloaded (names, approximate size) with Download / Cancel. On Download the popup closes, the bottom-right
/// indicator shows each download (name + progress, ✕ → inline confirm), and the action runs when every model is in.
@MainActor @Perceptible
public final class ModelDownloadFlow {
    public struct Prompt: Identifiable {
        public let id = UUID()
        public let specs: [AIModelSpec]
        let action: @MainActor () -> Void
        public var bytes: Int64 { specs.reduce(0) { $0 + $1.bytes } }
    }
    struct Pending { let specs: [AIModelSpec]; let action: @MainActor () -> Void }

    /// The open "Download required" popup (nil = closed).
    public private(set) var prompt: Prompt?
    /// Models whose ✕ was clicked in the indicator: the inline "Stop download" confirmation is showing.
    public private(set) var confirmingCancel: Set<String> = []
    /// Downloads started from this flow that failed (model id → message), shown in the indicator until dismissed.
    public private(set) var failures: [String: String] = [:]
    /// Actions waiting for their downloads.
    @PerceptionIgnored private(set) var pending: [UUID: Pending] = [:]
    public var pendingCount: Int { pending.count }
    /// Actions that ran after their download finished (UI tests: `ui.models.flow.proceeded`).
    public private(set) var proceeded = 0

    @PerceptionIgnored private let managerOverride: ModelManager?
    var manager: ModelManager { managerOverride ?? ModelManager.shared }

    public init(manager: ModelManager? = nil) { managerOverride = manager }

    func isInstalled(_ s: AIModelSpec) -> Bool { manager.state(s).isInstalled || ModelCatalog.installedURL(s) != nil }

    /// Runs `action` now when every model is installed; otherwise asks first (models already downloading need no
    /// new consent: the action just waits for them).
    public func require(_ specs: [AIModelSpec], then action: @escaping @MainActor () -> Void) {
        let missing = specs.filter { !isInstalled($0) }
        if missing.isEmpty { action(); return }
        if missing.allSatisfy({ manager.state($0).isBusy }) { wait(for: missing, action); return }
        prompt = Prompt(specs: missing, action: action)
    }

    /// Popup ▸ Download.
    public func confirm() {
        guard let p = prompt else { return }
        prompt = nil
        for s in p.specs { failures[s.id] = nil; manager.download(s) }
        wait(for: p.specs, p.action)
    }

    /// Popup ▸ Cancel (or Esc): nothing is downloaded, the action doesn't run.
    public func dismissPrompt() { prompt = nil }

    private func wait(for specs: [AIModelSpec], _ action: @escaping @MainActor () -> Void) {
        let key = UUID()
        pending[key] = Pending(specs: specs, action: action)
        for s in specs {
            manager.whenFinished(s) { [weak self] state in self?.finished(key, s, state) }
        }
    }

    private func finished(_ key: UUID, _ spec: AIModelSpec, _ state: AIModelState) {
        confirmingCancel.remove(spec.id)
        guard let p = pending[key] else { return }
        switch state {
        case .installed:
            guard p.specs.allSatisfy(isInstalled) else { return }   // others still downloading
            pending[key] = nil
            proceeded += 1
            p.action()
        case .failed(let msg):
            pending[key] = nil
            failures[spec.id] = msg
        default:   // cancelled
            pending[key] = nil
        }
    }

    /// Indicator ✕: show the inline confirmation (the download keeps going).
    public func askCancel(_ spec: AIModelSpec) { confirmingCancel.insert(spec.id) }
    public func keepDownloading(_ spec: AIModelSpec) { confirmingCancel.remove(spec.id) }
    /// Indicator ▸ Stop download (confirmed).
    public func confirmCancel(_ spec: AIModelSpec) {
        confirmingCancel.remove(spec.id)
        manager.cancel(spec)
    }
    public func dismissFailure(_ id: String) { failures[id] = nil }

    /// Models shown in the indicator: every download in progress (from this popup or a panel's Download button).
    var activeSpecs: [AIModelSpec] { ModelCatalog.all.filter { manager.state($0).isBusy } }

    func dump() -> [String: Any] {
        ["prompt": prompt?.specs.map(\.id).joined(separator: ",") ?? "", "pending": pending.count, "proceeded": proceeded,
         "confirming": confirmingCancel.sorted().joined(separator: ","), "failures": failures.keys.sorted().joined(separator: ","),
         "active": activeSpecs.map(\.id).joined(separator: ",")]
    }
}

extension EditorStore {
    /// OB-07: runs `action` once `specs` are installed, asking before any download (see `ModelDownloadFlow`).
    public func requireModels(_ specs: [AIModelSpec], then action: @escaping @MainActor () -> Void) {
        ai.downloads.require(specs, then: action)
    }
}

/// Editor overlay: the "Download required" popup (centred, dimmed editor) and the bottom-right download indicator.
struct ModelDownloadOverlay: View {
    let store: EditorStore
    var body: some View {
        WithPerceptionTracking {
            let flow = store.ai.downloads
            let _ = flow.manager.states
            ZStack(alignment: .bottomTrailing) {
                if !flow.activeSpecs.isEmpty || !flow.failures.isEmpty {
                    ModelDownloadIndicator(flow: flow)
                        .reportsSnapshotFrame { SnapshotRegistry.shared.floatingFrames["modelDownloads"] = $0 }
                        .padding(.trailing, 16).padding(.bottom, 16)
                }
                if let p = flow.prompt {
                    ZStack {
                        Color.black.opacity(0.5).ignoresSafeArea().contentShape(Rectangle()).onTapGesture {}
                        ModelDownloadPrompt(prompt: p, confirm: flow.confirm, cancel: flow.dismissPrompt)
                            .reportsSnapshotFrame { SnapshotRegistry.shared.modalFrame = $0 }   // like ExportModal
                    }
                }
            }
        }
    }
}

extension View {
    /// Offscreen snapshots composite the Metal views (player, timeline) after SwiftUI: report this card's frame so it
    /// is redrawn on top (`SnapshotRegistry`); nil when it goes away.
    func reportsSnapshotFrame(_ set: @escaping (CGRect?) -> Void) -> some View {
        background(GeometryReader { g in
            Color.clear
                .onAppear { set(g.frame(in: .global)) }
                .onValueChange(of: g.frame(in: .global)) { _, f in set(f) }
                .onDisappear { set(nil) }
        })
    }
}

/// The popup: what needs downloading (name · size), why it's safe (once, then on-device), [Cancel] [Download].
struct ModelDownloadPrompt: View {
    let prompt: ModelDownloadFlow.Prompt
    let confirm: () -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 18)).foregroundStyle(Theme.accent)
                Text(loc: "download.prompt.title").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            }
            Text(verbatim: tr(prompt.specs.count == 1 ? "download.prompt.body.one" : "download.prompt.body.many",
                              ByteCountFormatter.string(fromByteCount: prompt.bytes, countStyle: .file)))
                .font(Theme.Fonts.row).foregroundStyle(IStyle.label).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(prompt.specs) { s in
                    HStack {
                        Text(loc: s.nameKey).font(Theme.Fonts.row).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(verbatim: "≈ " + ByteCountFormatter.string(fromByteCount: s.bytes, countStyle: .file))
                            .font(Theme.Fonts.hint).foregroundStyle(IStyle.caption)
                    }
                }
            }
            .padding(10)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
            HintText(text: tr("download.prompt.privacy"))
            HStack(spacing: 10) {
                Spacer()
                Button(tr("download.prompt.cancel"), action: cancel)
                    .buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction).testID("modelPrompt.cancel")
                Button(tr("download.prompt.download"), action: confirm)
                    .buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction).testID("modelPrompt.download")
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.separator))
        .shadow(radius: 20)
        .testID("modelPrompt")
    }
}

/// Bottom-right card: one row per download (name, %, bar, ✕ → "Stop download?" [Keep] [Stop]) and failed ones.
struct ModelDownloadIndicator: View {
    let flow: ModelDownloadFlow
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(flow.activeSpecs) { s in row(s) }
                ForEach(flow.failures.keys.sorted(), id: \.self) { id in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(IStyle.warning)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: ModelCatalog.spec(id).map { tr($0.nameKey) } ?? id).font(Theme.Fonts.row).foregroundStyle(Theme.textPrimary)
                            Text(verbatim: tr("download.failed", flow.failures[id] ?? "")).font(Theme.Fonts.hint).foregroundStyle(IStyle.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button { flow.dismissFailure(id) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help(tr("download.dismiss"))
                            .testID("modelDownloads.dismiss.\(id)")
                    }
                }
            }
            .padding(12)
            .frame(width: 280)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.separator))
            .shadow(radius: 10)
            .testID("modelDownloads.indicator")
        }
    }

    @ViewBuilder func row(_ s: AIModelSpec) -> some View {
        let state = flow.manager.state(s)
        let p: Double? = { if case .downloading(let v) = state { return v }; return nil }()
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle").foregroundStyle(Theme.accent)
                Text(loc: s.nameKey).font(Theme.Fonts.row).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer()
                Text(verbatim: p.map { "\(Int($0 * 100)) %" } ?? tr("models.verifying")).font(Theme.Fonts.hint).foregroundStyle(IStyle.caption)
                    .monospacedDigit()
                if !flow.confirmingCancel.contains(s.id) {
                    Button { flow.askCancel(s) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help(tr("download.cancel"))
                        .testID("modelDownloads.cancel.\(s.id)")
                }
            }
            if let p { ProgressView(value: p).tint(Theme.accent) } else { ProgressView().progressViewStyle(.linear).tint(Theme.accent) }
            if flow.confirmingCancel.contains(s.id) {
                Text(loc: "download.cancel.question").font(Theme.Fonts.hint).foregroundStyle(IStyle.label)
                HStack(spacing: 10) {
                    Spacer()
                    Button(tr("download.keep")) { flow.keepDownloading(s) }.buttonStyle(.link).font(Theme.Fonts.hint)
                        .testID("modelDownloads.keep.\(s.id)")
                    Button(tr("download.cancel.confirm")) { flow.confirmCancel(s) }
                        .buttonStyle(SecondaryButtonStyle()).testID("modelDownloads.confirmCancel.\(s.id)")
                }
            }
        }
    }
}
