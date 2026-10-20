import SwiftUI
import MontageCore
import MontageEngine
import MontageAI

/// TX-030 "Align to speech" (Text ▸ Local captions ▸ script): the typed script becomes captions timed on the speech.
@MainActor @Observable final class ScriptAlignState {
    static let shared = ScriptAlignState()
    var job: JobID?
    var progress: Double = 0
}

extension EditorStore {
    public func alignScriptToSpeech(_ script: String) {
        let st = ScriptAlignState.shared
        guard st.job == nil, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let project = self.project
        let box = AlignBox()
        st.progress = 0
        Task {
            let id = await JobQueue.shared.enqueue(titleKey: "align.job", priority: 1, heavy: true) { progress in
                box.output = try await ScriptAligner.run(script: script, project: project, language: nil) { p in
                    progress.report(p)
                    Task { @MainActor in ScriptAlignState.shared.progress = p }
                }
            }
            st.job = id
            let state = await JobQueue.shared.wait(id)
            st.job = nil
            switch state {
            case .done:
                guard let o = box.output, perform(o.command) else { return }
                showToast(tr("align.done", o.count, Int((o.matchRatio * 100).rounded())))
            case .failed(let msg):
                let key = msg.contains("mismatch") ? "align.error.mismatch" : (msg.contains("noInput") ? "captions.error.noAudio" : "ai.error.noSpeech")
                showToast(tr(key), error: true)
            case .cancelled: showToast(tr("align.cancelled"))
            default: break
            }
        }
    }

    public func cancelScriptAlignment() {
        if let id = ScriptAlignState.shared.job { Task { await JobQueue.shared.cancel(id) } }
    }
}

/// The "Align to speech" row under the script editor.
struct AlignScriptRow: View {
    let store: EditorStore
    @Binding var script: String
    var body: some View {
        let st = ScriptAlignState.shared
        VStack(alignment: .leading, spacing: 6) {
            if st.job != nil {
                JobProgressLine(text: tr("align.progress", Int(st.progress * 100)), progress: st.progress) { store.cancelScriptAlignment() }
                    .testID("align.progress")
            } else {
                Button { store.alignScriptToSpeech(script) } label: {
                    Label(tr("align.button"), systemImage: "waveform.and.magnifyingglass")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(tr("align.help"))
                .testID("align.button")
            }
        }
    }
}

nonisolated final class AlignBox: @unchecked Sendable { var output: ScriptAligner.Output? }
