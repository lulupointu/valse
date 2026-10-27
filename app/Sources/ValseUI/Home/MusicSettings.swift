import SwiftUI
import AppKit
import ValseCore
import ValseEngine
import Perception

/// Settings ▸ Music: the online music & sound-effect library (owner exception to local-only). On/off switch, the
/// user's own free API keys per provider (stored in the Keychain on "Save", never in preferences or the repo), and
/// where to get them. Applied immediately (keys are secrets, not part of the Settings draft).
struct MusicSettings: View {
    private var state: OnlineAudioState { OnlineAudioState.shared }

    var body: some View {
        WithPerceptionTracking {
            @Perception.Bindable var st = state
            VStack(alignment: .leading, spacing: 0) {
                SettingsRow(tr("settings.music.online"), hint: tr("settings.music.online.hint")) {
                    SwitchButton(isOn: $st.enabled, id: "onlineAudio", label: tr("settings.music.online"))
                }
                SettingsDivider()
                ForEach(state.providers, id: \.id) { p in
                    WithPerceptionTracking {
                        ProviderKeyRow(provider: p)
                    }
                }
                HintText(text: tr("settings.music.keys.hint")).padding(.top, 6)
            }
        }
    }
}

struct ProviderKeyRow: View {
    let provider: any OnlineAudioProvider
    @State private var text = ""
    private var state: OnlineAudioState { OnlineAudioState.shared }

    var body: some View {
        WithPerceptionTracking {
            let saved = state.keysVersion >= 0 && state.key(provider.id) != nil
            SettingsRow(provider.name, hint: tr("settings.music.provider.\(provider.id)")) {
                HStack(spacing: 6) {
                    SecureField(tr(saved ? "settings.music.key.replace" : "settings.music.key.placeholder"), text: $text)
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .padding(.horizontal, 8).frame(minWidth: 150, maxWidth: 230).frame(height: 26)
                        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 4))
                        .onSubmit(save)
                        .testID("settings.music.key.\(provider.id)")
                    Button(tr("settings.music.key.save"), action: save).buttonStyle(AccentButtonStyle()).fixedSize()
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                        .testID("settings.music.save.\(provider.id)")
                    if saved {
                        Button(tr("settings.music.key.remove")) { state.setKey(nil, for: provider.id) }.buttonStyle(SecondaryButtonStyle()).fixedSize()
                            .testID("settings.music.remove.\(provider.id)")
                    }
                }
                HStack(spacing: 10) {
                    Label(tr(saved ? "settings.music.key.saved" : "settings.music.key.none"),
                          systemImage: saved ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.system(size: 11)).foregroundStyle(saved ? Theme.success : Theme.textTertiary)
                        .testID("settings.music.status.\(provider.id)")
                    Button { NSWorkspace.shared.open(provider.signupURL) } label: {
                        Text(verbatim: tr("settings.music.key.get") + " ↗").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain).help(provider.signupURL.absoluteString)
                }
            }
        }
    }

    func save() {
        let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        state.setKey(v, for: provider.id)
        text = ""
    }
}
