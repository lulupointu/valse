import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MontageCore
import MontageEngine
import MontageAI
import Perception

/// Home ▸ Long video to shorts (AI-031, UX_AI §10.1), added by AI2 on top of W12's Home: Upload long video → select the
/// part → Set duration for shorts + ☐ Add captions → Get shorts ("Analyzing… / Converting shorts… %", Cancel) →
/// "Shorts (N)": one new 9:16 project per highlight (auto reframed, captioned), each opens in the editor.
@MainActor @Perceptible
public final class ShortsWizardState {
    public static let shared = ShortsWizardState()
    public enum Step: String { case upload, settings, running, results }

    public var isPresented = false
    public var step: Step = .upload
    public var asset: MediaAsset?
    public var problem: ShortsPlanner.Problem?
    public var loading = false
    public var rangeStart: Double = 0
    public var rangeEnd: Double = 0
    public var duration: ShortsDuration = .auto
    public var captions = true
    public var phase: LongToShorts.Phase?
    public var progress: Double = 0
    public var error: String?
    public var results: [URL] = []
    @PerceptionIgnored var job: JobID?

    public func present() { reset(); isPresented = true }

    public func close() {
        cancel()
        isPresented = false
    }

    func reset() {
        step = .upload; asset = nil; problem = nil; error = nil; results = []; progress = 0; phase = nil
        duration = .auto; captions = true; loading = false
    }

    /// Probes and validates the chosen file (≥ 1 min, ≤ 3 h, video with audio).
    public func load(_ url: URL) async {
        loading = true
        defer { loading = false }
        error = nil
        guard let a = try? await MediaProbe.probe(url) else { problem = .notVideo; asset = nil; return }
        asset = a
        problem = ShortsPlanner.validate(a)
        rangeStart = 0
        rangeEnd = a.duration.seconds
        if problem == nil { step = .settings }
    }

    func choose() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.movie]
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { Task { await load(u) } }
    }

    func start(app: AppModel) {
        guard let a = asset, job == nil else { return }
        var o = LongToShorts.Options()
        o.duration = duration
        o.captions = captions
        if rangeStart > 0.5 || rangeEnd < a.duration.seconds - 0.5 { o.range = rangeStart...max(rangeEnd, rangeStart + 1) }
        let opts = o
        step = .running
        progress = 0
        phase = .analyzing
        error = nil
        let box = ShortsBox()
        Task {
            let id = await JobQueue.shared.enqueue(titleKey: "shorts.title", priority: 1, heavy: true) { progress in
                box.projects = try await LongToShorts.run(a, options: opts, progress: { p in
                    progress.report(p)
                    Task { @MainActor in ShortsWizardState.shared.progress = p }
                }, phase: { ph in Task { @MainActor in ShortsWizardState.shared.phase = ph } })
            }
            job = id
            let (state, failure) = await JobQueue.shared.waitResult(id)
            job = nil
            switch state {
            case .done:
                var urls: [URL] = []
                for p in box.projects { if let u = try? app.library.create(p) { urls.append(u) } }
                results = urls
                step = .results
                app.refreshSoon()
            case .cancelled:
                step = .settings
            default:
                if case .failed = state { error = SpeechFailure.userText(failure, fallbackKey: "shorts.error.failed") }
                step = .settings
            }
        }
    }

    public func cancel() {
        if let id = job { Task { await JobQueue.shared.cancel(id) } }
    }

    /// UI tests (`"project": "home:0:shorts"` / `"home:0:shorts-ok"`): a synthetic 4 s (too short) or 70 s video.
    func loadSynthetic(seconds: Double) async {
        present()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("montage-shorts-\(Int(seconds))s.mp4")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? await SyntheticMedia.writeVideo(to: url, size: CGSize(width: 320, height: 180), seconds: seconds, fps: 10,
                                                 pattern: .movingBox(RGBA(0.1, 0.1, 0.12), RGBA(0.34, 0.75, 0.8)), audioHz: 220)
        }
        await load(url)
    }
}

nonisolated final class ShortsBox: @unchecked Sendable { var projects: [Project] = [] }

/// The wizard as a centred Home dialog (dimmed backdrop), like W12's modals.
struct ShortsWizardHost: View {
    @Perception.Bindable var app: AppModel
    var body: some View {
        WithPerceptionTracking {
            let st = ShortsWizardState.shared
            if st.isPresented {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    DialogCard(title: tr("shorts.title"), width: 560, onClose: { st.close() }) {
                        ShortsWizardView(app: app).padding(20)
                    }
                    .modalHoverShield()   // FB-07
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { SnapshotRegistry.shared.modal = ($0, 0.55) }
                    .onDisappear { SnapshotRegistry.shared.modal = nil }
                    .testID("shorts.dialog")
                }
            }
        }
    }
}

struct ShortsWizardView: View {
    @Perception.Bindable var app: AppModel
    var body: some View {
        WithPerceptionTracking {
            let st = ShortsWizardState.shared
            VStack(alignment: .leading, spacing: 14) {
                switch st.step {
                case .upload: upload
                case .settings: settings
                case .running: running
                case .results: results
                }
            }
        }
    }

    // 1. Upload long video
    @ViewBuilder var upload: some View {
        let st = ShortsWizardState.shared
        VStack(spacing: 12) {
            Image(systemName: "film.stack").font(.system(size: 30)).foregroundStyle(Theme.accent)
            Text(loc: "shorts.upload").font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.textPrimary)
            Text(loc: "shorts.rules").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary).multilineTextAlignment(.center)
            if st.loading { ProgressView().controlSize(.small) }
            else {
                Button(tr("shorts.import")) { st.choose() }.buttonStyle(AccentButtonStyle()).testID("shorts.import")
            }
            if let p = st.problem {
                Label(tr(p.messageKey), systemImage: "exclamationmark.triangle.fill").font(Theme.Fonts.hint)
                    .foregroundStyle(IStyle.warning).testID("shorts.problem")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.separator, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            HomeDrop.load(providers) { urls in if let u = urls.first { Task { await st.load(u) } } }
            return true
        }
        Text(loc: "shorts.bestFor").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
    }

    // 2–3. Range, duration, captions
    @ViewBuilder var settings: some View {
        let st = ShortsWizardState.shared
        if let a = st.asset {
            HStack(spacing: 8) {
                Image(systemName: "film").foregroundStyle(Theme.accent)
                Text(verbatim: a.name).font(Theme.Fonts.row).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer()
                Text(verbatim: Self.clock(a.duration.seconds)).font(Theme.Fonts.numeric).foregroundStyle(IStyle.caption)
                Button(tr("shorts.change")) { st.reset() }.buttonStyle(.link).font(Theme.Fonts.hint).testID("shorts.change")
            }
            Text(loc: "shorts.selectPart").font(Theme.Fonts.row).foregroundStyle(IStyle.label)
            VStack(spacing: 4) {
                HStack { Text(loc: "shorts.from").frame(width: 44, alignment: .leading)
                    Slider(value: Binding.perceived(get: { st.rangeStart }, set: { st.rangeStart = min($0, st.rangeEnd - 30) }), in: 0...a.duration.seconds)
                    Text(verbatim: Self.clock(st.rangeStart)).font(Theme.Fonts.numeric).frame(width: 64, alignment: .trailing) }
                HStack { Text(loc: "shorts.to").frame(width: 44, alignment: .leading)
                    Slider(value: Binding.perceived(get: { st.rangeEnd }, set: { st.rangeEnd = max($0, st.rangeStart + 30) }), in: 0...a.duration.seconds)
                    Text(verbatim: Self.clock(st.rangeEnd)).font(Theme.Fonts.numeric).frame(width: 64, alignment: .trailing) }
            }
            .font(Theme.Fonts.hint).foregroundStyle(IStyle.caption)
            Text(loc: "shorts.setDuration").font(Theme.Fonts.row).foregroundStyle(IStyle.label)
            HStack(spacing: 6) {
                ForEach(ShortsDuration.allCases, id: \.self) { d in
                    WithPerceptionTracking {
                        Button { st.duration = d } label: {
                            Text(verbatim: tr(d.nameKey)).font(Theme.Fonts.row)
                                .foregroundStyle(st.duration == d ? Theme.accent : Theme.textPrimary)
                                .frame(maxWidth: .infinity).frame(height: 30)
                                .background(Theme.control.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(st.duration == d ? Theme.accent : .clear))
                        }
                        .buttonStyle(.plain)
                        .testID("shorts.duration.\(d.rawValue)")
                    }
                }
            }
            HStack(spacing: 8) {
                CapCheckbox(isOn: Binding.perceived(get: { st.captions }, set: { st.captions = $0 })).testID("shorts.captions")
                Text(loc: "shorts.captions").font(Theme.Fonts.row).foregroundStyle(IStyle.label)
            }
            HintText(text: tr("shorts.hint"))
            if let e = st.error { HintText(text: e, color: IStyle.warning) }
            HStack {
                Spacer()
                Button(tr("shorts.get")) { st.start(app: app) }.buttonStyle(AccentButtonStyle()).testID("shorts.get")
            }
        }
    }

    @ViewBuilder var running: some View {
        let st = ShortsWizardState.shared
        VStack(alignment: .leading, spacing: 10) {
            JobProgressLine(text: tr((st.phase ?? .analyzing).titleKey, Int(st.progress * 100)), progress: st.progress) { st.cancel() }
                .testID("shorts.progress")
            HintText(text: tr("shorts.runningHint"))
        }
        .frame(minHeight: 120)
    }

    @ViewBuilder var results: some View {
        let st = ShortsWizardState.shared
        Text(loc: "shorts.results", st.results.count).font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.textPrimary)
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 12) {
                ForEach(Array(st.results.enumerated()), id: \.offset) { i, url in
                    WithPerceptionTracking {
                        Button { st.close(); app.open(url) } label: {
                            VStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 6).fill(Theme.inset).aspectRatio(9 / 16, contentMode: .fit)
                                    .overlay(Image(systemName: "play.rectangle").font(.system(size: 22)).foregroundStyle(Theme.accent))
                                Text(verbatim: url.deletingPathExtension().lastPathComponent).font(.system(size: 11))
                                    .foregroundStyle(Theme.textSecondary).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .testID("shorts.result.\(i)")
                    }
                }
            }
        }
        .frame(maxHeight: 360)
        HStack { Spacer(); Button(tr("common.close")) { st.close() }.buttonStyle(SecondaryButtonStyle()) }
    }

    static func clock(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}
