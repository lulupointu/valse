import SwiftUI
import MontageCore
import MontageAI
import Perception

/// Dictate (TX-034): a mic button next to a text field. Click → speak → the words stream into the field (appended to
/// what it held), click again (or pause 2.5 s) to stop. On-device speech recognition only. `onStart` / `onEnd` let a
/// caller wrap the session in one undo step (text clips use a store gesture).
struct DictateButton: View {
    @Binding var text: String
    var testID: String
    var language: String? = nil
    var onStart: (() -> Void)? = nil
    var onEnd: (() -> Void)? = nil
    @State private var base = ""
    @State private var error: String?

    var body: some View {
        WithPerceptionTracking {
            let d = Dictation.shared
            let active = d.owner == testID
            Button { toggle() } label: {
                ZStack {
                    if active {
                        Circle().fill(Theme.danger.opacity(0.25 + 0.5 * d.level)).frame(width: 24, height: 24)
                    }
                    Image(systemName: active ? "mic.fill" : "mic")
                        .font(.system(size: 13))
                        .foregroundStyle(active ? Theme.danger : (error == nil ? IStyle.icon : IStyle.warning))
                }
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(error ?? tr(active ? "dictate.stop" : "dictate.start"))
            .testID(testID)
        }
    }

    func toggle() {
        let d = Dictation.shared
        if d.owner == testID { d.stop(); return }
        base = text
        error = nil
        let lang = language ?? L10n.shared.language
        Task {
            do {
                var started = false
                try await d.start(owner: testID, language: lang, onText: { t, _ in
                    if !started { started = true; onStart?() }
                    text = DictationText.merge(base: base, dictated: t)
                }, onEnd: { if started { onEnd?() } })
            } catch let f as Dictation.Failure {
                error = tr(f.messageKey)
            } catch {
                self.error = tr("dictate.error.failed")
            }
        }
    }
}

extension EditorStore {
    /// Binding to a text clip's string for dictation: every partial result updates the clip live inside one gesture
    /// (`DictateButton` onStart/onEnd), so a whole dictation is one undo step "Dictate".
    func dictationBinding(for clipID: ClipID) -> Binding<String> {
        Binding.perceived(get: { [weak self] in
            guard case .text(let t)? = self?.project.timeline.clip(clipID)?.content else { return "" }
            return t.string
        }, set: { [weak self] s in
            self?.updateGesture { p in
                guard var c = p.timeline.clip(clipID), case .text(var t) = c.content else { return }
                t.setString(s)
                c.content = .text(t)
                if t.template == nil { c.name = s.replacingOccurrences(of: "\n", with: " ") }
                p.timeline[clip: clipID] = c
            }
        })
    }
}
