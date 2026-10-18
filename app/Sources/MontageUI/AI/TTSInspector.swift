import SwiftUI
import AVFoundation
import MontageCore
import MontageEngine
import MontageAI

/// Text clip ▸ Text to speech (UX_AI §7, [131], AU-030/TX-016): search, language pills, voice tiles (click = preview),
/// Speed / Pitch, ☐ Update speech according to script, footer [Generate speech] (+ Apply to all).
enum TTSInspector {
    @MainActor static let tabs: [InspectorTab] = [
        InspectorTab(id: "tts", titleKey: "inspector.tab.tts", order: 6, footer: { ctx, _ in AnyView(TTSFooter(ctx: ctx)) },
                     appliesTo: { $0.kind == .text }),
    ]
    @MainActor static let sections: [InspectorSection] = [
        InspectorSection(id: "tts.voices", tab: "tts", order: 0, titleKey: nil) { AnyView(TTSVoicesSection(ctx: $0)) },
    ]
}

@MainActor @Observable final class TTSUIState {
    static let shared = TTSUIState()
    var voice: String?
    var rate: Double = 1
    var pitch: Double = 1
    var autoUpdate = true
    var language = "auto"
    var query = ""
    var generating: Set<ClipID> = []
    let preview = AVSpeechSynthesizer()
}

struct TTSVoicesSection: View {
    let ctx: InspectorContext
    var body: some View {
        let st = TTSUIState.shared
        let langs = st.language == "auto" ? ["fr", "en"] : [st.language]
        let voices = SpeechSynthesis.voices(languages: langs).filter { st.query.isEmpty || $0.name.localizedCaseInsensitiveContains(st.query) }
        let current = st.voice ?? existing?.voice ?? SpeechSynthesis.defaultVoice(L10n.shared.language)?.id
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(IStyle.caption)
                TextField(tr("tts.search"), text: Binding(get: { st.query }, set: { st.query = $0 })).textFieldStyle(.plain).font(Theme.Fonts.row)
            }
            .padding(.horizontal, 8).frame(height: 28).background(IStyle.field, in: RoundedRectangle(cornerRadius: 4))
            HStack(spacing: 8) {
                ForEach([("auto", tr("tts.lang.all")), ("fr", tr("tts.lang.fr")), ("en", tr("tts.lang.en"))], id: \.0) { id, title in
                    Text(verbatim: title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 28)
                        .background(st.language == id ? Theme.accentDim : Theme.buttonSecondary, in: Capsule())
                        .onTapGesture { st.language = id }
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 96), spacing: 10)], spacing: 10) {
                ForEach(voices) { v in
                    VStack(spacing: 4) {
                        Text(verbatim: v.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).multilineTextAlignment(.center)
                            .lineLimit(2)
                        Text(verbatim: v.language + (v.quality >= 1 ? " ✦" : "")).font(.system(size: 10)).foregroundStyle(IStyle.caption)
                    }
                    .frame(width: 84, height: 64)
                    .background(IStyle.tile, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(current == v.id ? Theme.accent : .clear, lineWidth: 2))
                    .contentShape(Rectangle())
                    .onTapGesture { st.voice = v.id; sample(v) }
                    .help(tr(v.quality >= 1 ? "tts.voice.hq" : "tts.voice.compact"))
                }
            }
            GroupCaption(title: tr("tts.adjust"))
            SliderRowView(label: tr("tts.speed"), unit: (st.rate - 0.5) / 1.5, originUnit: 0, gradient: nil, ticks: [], display: Fmt.speed(st.rate),
                          enabled: true, labelAccessory: nil, parse: NumberParse.number, onBegin: {}, onChange: { st.rate = 0.5 + $0 * 1.5 }, onEnd: {},
                          commit: { st.rate = min(max($0, 0.5), 2) }, step: { st.rate = min(max(st.rate + Double($0) * 0.1, 0.5), 2) }, triplet: nil)
            SliderRowView(label: tr("tts.pitch"), unit: (st.pitch - 0.5) / 1.5, originUnit: 1.0 / 3, gradient: nil, ticks: [], display: Fmt.speed(st.pitch),
                          enabled: true, labelAccessory: nil, parse: NumberParse.number, onBegin: {}, onChange: { st.pitch = 0.5 + $0 * 1.5 }, onEnd: {},
                          commit: { st.pitch = min(max($0, 0.5), 2) }, step: { st.pitch = min(max(st.pitch + Double($0) * 0.1, 0.5), 2) }, triplet: nil)
            ToggleLine(label: tr("tts.updateWithScript"), isOn: Binding(get: { st.autoUpdate }, set: { st.autoUpdate = $0 }))
        }
    }

    var existing: TTSInfo? { ctx.clip.flatMap { TTSOps.speechClip(for: $0.id, in: ctx.store.project.timeline)?.tts } }

    func sample(_ v: TTSVoice) {
        let st = TTSUIState.shared
        st.preview.stopSpeaking(at: .immediate)
        var text = tr("tts.sample")
        if case .text(let t)? = ctx.clip?.content, !t.string.isEmpty { text = String(t.string.prefix(80)) }
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(identifier: v.id)
        u.rate = Float(Double(AVSpeechUtteranceDefaultSpeechRate) * st.rate)
        u.pitchMultiplier = Float(st.pitch)
        st.preview.speak(u)
    }
}

struct TTSFooter: View {
    let ctx: InspectorContext
    var body: some View {
        let st = TTSUIState.shared
        HStack {
            PillButton(title: tr("inspector.applyToAll")) { ctx.store.generateSpeechForAllTexts() }
            Spacer()
            if let id = ctx.clip?.id, st.generating.contains(id) { ProgressView().controlSize(.small); Text(loc: "tts.generating").font(Theme.Fonts.hint) }
            PillButton(title: tr("tts.generate"), accent: true, enabled: ctx.clip.map { !st.generating.contains($0.id) } ?? false) {
                if let id = ctx.clip?.id { ctx.store.generateSpeech(for: id) }
            }
        }
    }
}

extension EditorStore {
    /// Generate speech for a text clip (replaces its previous speech clip; one undo step).
    public func generateSpeech(for textID: ClipID, silent: Bool = false, reuse: TTSInfo? = nil) {
        guard let c = project.timeline.clip(textID), case .text(let t) = c.content else { return }
        let text = t.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let st = TTSUIState.shared
        let lang = c.caption?.language ?? L10n.shared.language
        guard let voice = reuse?.voice ?? st.voice ?? TTSOps.speechClip(for: textID, in: project.timeline)?.tts?.voice ?? SpeechSynthesis.defaultVoice(lang)?.id else { return }
        let rate = reuse?.rate ?? st.rate, pitch = reuse?.pitch ?? st.pitch, auto = reuse?.autoUpdate ?? st.autoUpdate
        st.generating.insert(textID)
        Task {
            defer { st.generating.remove(textID) }
            do {
                let url = try await SpeechSynthesis.synthesize(text, voice: voice, rate: rate, pitch: pitch)
                let asset = try await MediaProbe.probe(url)
                let info = TTSInfo(sourceText: textID, voice: voice, rate: rate, pitch: pitch, text: t.string, autoUpdate: auto)
                if perform(Edit("cmd.tts") { p in
                    var a = asset
                    if let e = p.media.first(where: { $0.contentHash == asset.contentHash }) { a = e }
                    try TTSOps.placeSpeech(a, info: info, in: &p)
                }), !silent { showToast(tr("tts.added")) }
            } catch {
                showToast(tr("tts.failed"), error: true)
            }
        }
    }

    public func generateSpeechForAllTexts() {
        for c in project.timeline.allClips { if case .text = c.content { generateSpeech(for: c.id, silent: true) } }
    }

    /// "Update speech according to script": regenerate stale speech shortly after the text stops changing.
    func refreshStaleSpeech() {
        let stale = TTSOps.staleSpeech(in: project.timeline)
        guard !stale.isEmpty, !session.isInGesture else { return }
        for (t, s) in stale where !TTSUIState.shared.generating.contains(t.id) {
            generateSpeech(for: t.id, silent: true, reuse: s.tts)
        }
    }
}
