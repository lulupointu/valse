import SwiftUI
import MontageCore
import MontageEngine
import MontageAI
import Perception

/// Text ▸ AI writer (UX_AI §11, AI-029): Topic · Requirements · type → [Generate] ("Generating..."), then an editable
/// script with Make longer / Make shorter / Rewrite and Add to track (Split and add / Add without split). Runs on
/// Apple Intelligence or the local Qwen model; without either it points to the AI models sheet.
@MainActor @Perceptible final class AIWriterState {
    static let shared = AIWriterState()
    var topic = ""
    var requirements = ""
    var kind: AIWriter.Kind = .talking
    var language: String? = nil
    var script = ""
    var task: Task<Void, Never>?
    var busy: Bool { task != nil }
    var error: String?
}

struct AIWriterPanel: View {
    let store: EditorStore
    var body: some View {
        WithPerceptionTracking {
            let st = AIWriterState.shared
            let _ = ModelManager.shared.states   // re-render when a model download finishes (`isAvailable` is a disk check)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !AIWriter.isAvailable {
                            HintText(text: tr("writer.needsModel"), color: IStyle.warning)
                            Button(tr("models.manage")) { store.ai.isModelSheetPresented = true }.buttonStyle(SecondaryButtonStyle())
                        }
                        label("writer.topic")
                        TextField(tr("writer.topic.placeholder"), text: Binding(get: { st.topic }, set: { st.topic = $0 }), axis: .vertical)
                            .textFieldStyle(.plain).font(Theme.Fonts.row).lineLimit(2...4)
                            .padding(8).padding(.trailing, 22).background(IStyle.field, in: RoundedRectangle(cornerRadius: 6)).testID("writer.topic")
                            .overlay(alignment: .trailing) {   // AI2 TX-034
                                DictateButton(text: Binding(get: { st.topic }, set: { st.topic = $0 }), testID: "writer.dictate").padding(.trailing, 2)
                            }
                        label("writer.requirements")
                        TextField(tr("writer.requirements.placeholder"), text: Binding(get: { st.requirements }, set: { st.requirements = $0 }), axis: .vertical)
                            .textFieldStyle(.plain).font(Theme.Fonts.row).lineLimit(2...4)
                            .padding(8).background(IStyle.field, in: RoundedRectangle(cornerRadius: 6))
                        HStack {
                            Dropdown(items: AIWriter.Kind.allCases.map { ($0, tr($0.nameKey)) }, selection: st.kind) { st.kind = $0 }
                            Dropdown(items: [(Optional<String>.none, tr("captions.autoDetect")), (Optional("fr"), CaptionLanguages.title("fr")),
                                             (Optional("en"), CaptionLanguages.title("en"))], selection: st.language) { st.language = $0 }
                        }
                        HStack {
                            Spacer()
                            PillButton(title: tr(st.busy ? "writer.generating" : "writer.generate"), accent: true,
                                       enabled: AIWriter.isAvailable && !st.busy && !st.topic.trimmingCharacters(in: .whitespaces).isEmpty) { generate() }
                                .testID("writer.generate")
                        }
                        if let e = st.error { HintText(text: e, color: IStyle.warning) }
                        if !st.script.isEmpty || st.busy {
                            label("writer.script")
                            TextEditor(text: Binding(get: { st.script }, set: { st.script = $0 }))
                                .font(Theme.Fonts.row).scrollContentBackground(.hidden).frame(minHeight: 160)
                                .padding(6).background(IStyle.field, in: RoundedRectangle(cornerRadius: 6))
                                .overlay { if st.busy { ProgressView().controlSize(.small) } }
                                .testID("writer.script")
                            HStack(spacing: 6) {
                                PillButton(title: tr("writer.longer"), enabled: !st.busy) { revise(.longer) }
                                PillButton(title: tr("writer.shorter"), enabled: !st.busy) { revise(.shorter) }
                                PillButton(title: tr("writer.rewrite"), enabled: !st.busy) { revise(.rewrite) }
                            }
                            HintText(text: tr("writer.disclaimer"))
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !st.script.isEmpty {
                    HStack {
                        Spacer()
                        Button(tr("writer.addNoSplit")) { add(split: false) }.buttonStyle(SecondaryButtonStyle()).disabled(st.busy)
                        Button(tr("writer.addSplit")) { add(split: true) }.buttonStyle(AccentButtonStyle()).disabled(st.busy).testID("writer.add")
                    }
                    .padding(12)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.separator).frame(height: 1) }
                }
            }
            .background(Theme.panel)
        }
    }

    func label(_ key: String) -> some View { Text(loc: key).font(Theme.Fonts.row).foregroundStyle(IStyle.label) }

    var language: String { AIWriterState.shared.language ?? L10n.shared.language }

    func generate() {
        let st = AIWriterState.shared
        let (topic, req, kind, lang) = (st.topic, st.requirements, st.kind, language)
        run { try await AIWriter.write(topic: topic, requirements: req, kind: kind, language: lang) }
    }

    func revise(_ r: AIWriter.Revision) {
        let s = AIWriterState.shared.script, lang = language
        run { try await AIWriter.revise(s, r, language: lang) }
    }

    func run(_ work: @escaping @Sendable () async throws -> String) {
        let st = AIWriterState.shared
        st.error = nil
        st.task = Task {
            do { st.script = try await Task.detached { try await work() }.value } catch { st.error = tr("writer.failed") }
            st.task = nil
        }
    }

    func add(split: Bool) {
        let segs = AIWriter.segments(AIWriterState.shared.script, start: store.transport.playhead.seconds, split: split)
        guard !segs.isEmpty else { return }
        if store.perform(Edit("cmd.writerAdd") { p in _ = CaptionOps.addCaptionTrack(segs, to: &p, origin: .script) }) {
            store.showToast(tr("writer.added"))
        }
    }
}
