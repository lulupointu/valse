import SwiftUI
import MontageCore
import MontageEngine
import MontageAI
import Perception

/// AI clipper (UX_AI §10.2, AI-031): right-click a main-track video ▸ AI clipper… → Duration · Editing style · More
/// requirements · ☐ Add captions → [Get clips] ("AI clipping... %", cancel) → Highlight clips (tick / untick) →
/// [Save] rebuilds the main track from them (one undo step; "Keyframes and speed changes will be removed").
@MainActor @Perceptible final class AIClipperState {
    var clipID: ClipID
    var duration: ClipDuration = .auto
    var style: ClipperStyle = .chronological
    var requirements = ""
    var addCaptions = true
    var highlights: [Highlight] = []
    var selected: Set<Double> = []
    var job: JobID?
    var error: String?
    init(clipID: ClipID) { self.clipID = clipID }
}

struct AIClipperSheet: View {
    let store: EditorStore
    let st: AIClipperState
    let close: () -> Void

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 14) {
                Text(loc: "clipper.title").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                if st.highlights.isEmpty {
                    settings
                } else {
                    results
                }
                if let e = st.error { HintText(text: e, color: IStyle.warning) }
                HStack {
                    Button(tr("ai.cancel")) { cancel(); close() }.buttonStyle(SecondaryButtonStyle())
                    Spacer()
                    if st.highlights.isEmpty {
                        Button(tr("clipper.get")) { run() }.buttonStyle(AccentButtonStyle()).disabled(st.job != nil).testID("clipper.get")
                    } else {
                        Button(tr("clipper.back")) { st.highlights = [] }.buttonStyle(SecondaryButtonStyle())
                        Button(tr("clipper.save")) { save() }.buttonStyle(AccentButtonStyle()).disabled(st.selected.isEmpty).testID("clipper.save")
                    }
                }
            }
            .padding(20)
            .frame(width: 520)
            .background(Theme.panel)
            .testID("clipper.sheet")
        }
    }

    var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            InlineRow(label: tr("clipper.duration")) {
                Dropdown(items: ClipDuration.allCases.map { ($0, tr($0.nameKey)) }, selection: st.duration) { st.duration = $0 }
            }
            InlineRow(label: tr("clipper.style")) {
                Dropdown(items: ClipperStyle.allCases.map { ($0, tr($0.nameKey)) }, selection: st.style) { st.style = $0 }
            }
            Text(loc: "clipper.requirements").font(Theme.Fonts.row).foregroundStyle(IStyle.label)
            TextField(tr("clipper.requirements.placeholder"), text: Binding.perceived(get: { st.requirements }, set: { st.requirements = $0 }), axis: .vertical)
                .textFieldStyle(.plain).font(Theme.Fonts.row).lineLimit(2...3)
                .padding(8).background(IStyle.field, in: RoundedRectangle(cornerRadius: 6))
                .disabled(!OnDeviceLLM.isAvailable)
            ToggleLine(label: tr("clipper.captions"), isOn: Binding.perceived(get: { st.addCaptions }, set: { st.addCaptions = $0 }))
            HintText(text: tr(OnDeviceLLM.isAvailable ? "clipper.hint.llm" : "clipper.hint.local"))
            if let job = st.job {
                let p = store.jobProgress(job) ?? 0
                JobProgressLine(text: tr("clipper.progress", JobInfo.percent(p)), progress: p) { cancel() }
            }
        }
    }

    var results: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: tr("clipper.results", st.highlights.count)).font(Theme.Fonts.row).foregroundStyle(IStyle.label)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(st.highlights) { h in
                        WithPerceptionTracking {
                            HStack(alignment: .top, spacing: 10) {
                                CapCheckbox(isOn: Binding.perceived(get: { st.selected.contains(h.id) }, set: { on in
                                    if on { st.selected.insert(h.id) } else { st.selected.remove(h.id) }
                                }))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: h.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                    Text(verbatim: "\(Self.tc(h.start)) – \(Self.tc(h.end)) · \(Int(h.duration.rounded())) s")
                                        .font(.system(size: 11)).foregroundStyle(IStyle.caption)
                                }
                                Spacer()
                            }
                            .padding(8).background(IStyle.tile, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
            HintText(text: tr("clipper.warning"))
        }
    }

    static func tc(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

    func run() {
        guard let c = store.project.timeline.clip(st.clipID), let a = c.mediaID.flatMap(store.project.asset) else { return }
        var o = AIClipper.Options()
        o.duration = st.duration; o.requirements = st.requirements; o.language = store.ai.captionLanguage
        let opts = o
        let box = HighlightBox()
        st.error = nil
        Task {
            let id = await JobQueue.shared.enqueue(titleKey: "clipper.job", priority: 1, heavy: true, subject: c.id.description) { progress in
                box.value = try await AIClipper.highlights(a, options: opts) { progress.report($0) }
            }
            st.job = id
            let s = await JobQueue.shared.wait(id)
            st.job = nil
            switch s {
            case .done:
                st.highlights = box.value
                st.selected = Set(box.value.map(\.id))
                if box.value.isEmpty { st.error = tr("ai.error.noSpeech") }
            case .failed: st.error = tr("clipper.failed")
            default: break
            }
        }
    }

    func cancel() { if let j = st.job { Task { await JobQueue.shared.cancel(j) } } }

    func save() {
        guard let media = store.project.timeline.clip(st.clipID)?.mediaID else { return }
        let hs = st.highlights.filter { st.selected.contains($0.id) }
        let style = st.style, captions = st.addCaptions
        if store.perform(Edit("cmd.clipper") { p in try Highlights.rebuildMainTrack(hs, media: media, style: style, in: &p) }) {
            store.showToast(tr("clipper.done"))
            close()
            if captions { store.ai.captionSource = .allTracks; store.generateCaptions() }
        }
    }
}

nonisolated final class HighlightBox: @unchecked Sendable { var value: [Highlight] = [] }
