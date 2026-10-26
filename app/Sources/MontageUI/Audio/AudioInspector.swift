import SwiftUI
import MontageCore
import MontageEngine
import MontageAI
import Perception

/// Observable bridge for background audio renders (voice changer, noise reduction…): drives "Processing…" rows.
@MainActor @Perceptible
final class AudioProcessingMonitor {
    static let shared = AudioProcessingMonitor()
    var revision = 0
    private init() {
        AudioRenderCache.shared.onProgress = { [weak self] in self?.revision &+= 1 }
    }
}

/// Audio inspector sections (W8), registered into the inspector shell (UX.md §5.1 Audio, §5.8 audio clip):
/// video clip → Audio [Basic · Voice changer]; audio clip → Basic · Voice changer · Speed.
@MainActor
enum AudioInspector {
    typealias Ctx = InspectorContext

    /// Voice changer as a sub-tab of the video clip's Audio tab.
    static let voiceSubTab = InspectorSubTab(id: "voice", titleKey: "audio.tab.voiceChanger", order: 1)

    static let tabs: [InspectorTab] = [
        InspectorTab(id: "audioVoice", titleKey: "audio.tab.voiceChanger", order: 3, appliesTo: { $0.kind == .audio }),
    ]

    /// Same section on the video clip's Audio ▸ Basic and the audio clip's Basic tab.
    static func both(_ id: String, order: Int, titleKey: String?, appliesTo: @escaping @MainActor (Ctx) -> Bool = { _ in true },
                     chrome: (@MainActor (Ctx) -> InspectorSectionChrome)? = nil,
                     content: @escaping @MainActor (Ctx) -> AnyView) -> [InspectorSection] {
        [InspectorSection(id: "audio.\(id)", tab: "audio", subTab: "basic", order: order, titleKey: titleKey, appliesTo: appliesTo, chrome: chrome, content: content),
         InspectorSection(id: "audioBasic.\(id)", tab: "audioBasic", order: order, titleKey: titleKey, appliesTo: appliesTo, chrome: chrome, content: content)]
    }

    static var sections: [InspectorSection] {
        var s: [InspectorSection] = []
        s += both("processing", order: 1, titleKey: nil, appliesTo: { pending($0) != nil }) { AnyView(ProcessingRow(ctx: $0)) }
        s += both("loudness", order: 10, titleKey: "audio.loudness", chrome: { ctx in
            InspectorSectionChrome(isEnabled: Binding.perceived(get: { ctx.clip?.audio.loudness != nil }, set: { ctx.store.setLoudnessNormalization($0) }))
        }) { AnyView(LoudnessSection(ctx: $0)) }
        s += both("enhance", order: 20, titleKey: "audio.enhance", chrome: { strengthChrome($0, \.enhanceVoice, 0.7, "cmd.audioEffect") }) {
            AnyView(StrengthRow(ctx: $0, path: \.enhanceVoice, defaultValue: 0.7, hint: "audio.enhance.hint"))
        }
        s += both("denoise", order: 30, titleKey: "audio.denoise", chrome: { strengthChrome($0, \.noiseReduction, 0.6, "cmd.audioEffect") }) {
            AnyView(StrengthRow(ctx: $0, path: \.noiseReduction, defaultValue: 0.6, hint: "f4ai.denoise.hint"))   // AI-009: strength in dB
        }
        s += both("separation", order: 40, titleKey: "audio.separation", chrome: { ctx in
            InspectorSectionChrome(isEnabled: clipBinding(ctx, "cmd.separation", get: { $0.audio.separation != nil }, set: { c, v in c.audio.separation = v ? .keepVocals : nil }))
        }) { AnyView(SeparationSection(ctx: $0)) }
        s += both("beats", order: 50, titleKey: "audio.beats", chrome: { ctx in
            InspectorSectionChrome(isEnabled: Binding.perceived(get: { ctx.clip?.beats?.isEmpty == false }, set: { ctx.store.autoBeats(level: $0 ? 1 : nil) }))
        }) { AnyView(BeatsSection(ctx: $0)) }
        s += both("ducking", order: 60, titleKey: "audio.ducking", chrome: { ctx in
            InspectorSectionChrome(isEnabled: clipBinding(ctx, "cmd.ducking", get: { $0.audio.ducking != nil }, set: { c, v in c.audio.ducking = v ? AudioDucking() : nil }))
        }) { AnyView(DuckingSection(ctx: $0)) }
        s += both("tone", order: 70, titleKey: "audio.tone", chrome: { ctx in
            InspectorSectionChrome(reset: {
                guard let id = ctx.clip?.id else { return }
                ctx.store.performInspector(UpdateClip(id, nameKey: "cmd.pitch") { $0.audio.pitch = 0; $0.audio.channels = .stereo })
            })
        }) { AnyView(ToneSection(ctx: $0)) }
        s += both("eq", order: 80, titleKey: "audio.eq", chrome: { ctx in
            InspectorSectionChrome(isEnabled: clipBinding(ctx, "cmd.eq", get: { $0.audio.eq != nil }, set: { c, v in c.audio.eq = v ? AudioEQ() : nil }),
                                   reset: { if let id = ctx.clip?.id { ctx.store.performInspector(UpdateClip(id, nameKey: "cmd.eq") { $0.audio.eq = AudioEQ() }) } },
                                   startsCollapsed: true)
        }) { AnyView(EQEditor(ctx: $0)) }
        s.append(InspectorSection(id: "audio.voice", tab: "audio", subTab: "voice", order: 0, titleKey: nil) { AnyView(VoiceChangerView(ctx: $0)) })
        s.append(InspectorSection(id: "audioVoice.voice", tab: "audioVoice", order: 0, titleKey: nil) { AnyView(VoiceChangerView(ctx: $0)) })
        return s
    }

    static func pending(_ ctx: Ctx) -> Double? {
        _ = AudioProcessingMonitor.shared.revision
        guard let c = ctx.clip, let a = ctx.asset else { return nil }
        return AudioPipeline.pendingRender(c, asset: a)
    }

    /// Stand-in read when the selected clip is gone (deleted / deselected): SwiftUI may re-evaluate a section's chrome
    /// with `ctx.clip == nil` before the panel drops the section, which used to crash on a force unwrap.
    static let placeholderClip = Clip(content: .adjustment, start: .zero, duration: Time(1))

    static func clipBinding<T>(_ ctx: Ctx, _ name: String, get: @escaping (Clip) -> T, set: @escaping (inout Clip, T) -> Void) -> Binding<T>
    where T: Equatable {
        let store = ctx.store, id = ctx.clip?.id
        let fallback = get(ctx.clip ?? placeholderClip)
        return Binding.perceived(get: { id.flatMap { store.project.timeline.clip($0) }.map(get) ?? fallback },
                       set: { v in if let id, store.project.timeline.clip(id) != nil { Bind.apply(store, id, name) { set(&$0, v) } } })
    }

    static func strengthChrome(_ ctx: Ctx, _ path: WritableKeyPath<AudioProps, Double?>, _ d: Double, _ name: String) -> InspectorSectionChrome {
        InspectorSectionChrome(isEnabled: clipBinding(ctx, name, get: { $0.audio[keyPath: path] != nil }, set: { c, v in c.audio[keyPath: path] = v ? d : nil }))
    }
}

struct ProcessingRow: View {
    let ctx: InspectorContext
    var body: some View {
        WithPerceptionTracking {
            let p = AudioInspector.pending(ctx) ?? 0
            HStack(spacing: 8) {
                ProgressView(value: p).progressViewStyle(.linear).tint(Theme.accent).frame(width: 90)
                Text(loc: "audio.processing").font(Theme.Fonts.hint).foregroundStyle(Theme.textSecondary)
                Spacer()
            }
        }
    }
}

struct LoudnessSection: View {
    let ctx: InspectorContext
    var body: some View {
        WithPerceptionTracking {
            let l = ctx.clip?.audio.loudness
            VStack(alignment: .leading, spacing: 8) {
                Text(loc: "audio.loudness.hint").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(loc: "audio.loudness.targetLabel").font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Picker(tr("audio.loudness.targetLabel"), selection: Binding.perceived(get: { l?.targetLUFS ?? -23 }, set: { ctx.store.setLoudnessTarget($0) })) {
                        ForEach(LoudnessNormalization.targets, id: \.self) { t in WithPerceptionTracking { Text(loc: "audio.loudness.target.\(Int(-t))").tag(t) } }
                    }
                    .labelsHidden().frame(width: 180)
                }
                if let m = l?.measuredLUFS, m.isFinite {
                    InfoRow(tr("audio.loudness.measured"), String(format: "%.1f LUFS", m))
                } else {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(loc: "audio.analyzing").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary) }
                }
            }
        }
    }
}

struct StrengthRow: View {
    let ctx: InspectorContext
    let path: WritableKeyPath<AudioProps, Double?>
    let defaultValue: Double
    let hint: String?
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 6) {
                if let hint { Text(loc: hint).font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true) }
                // the offline render restarts when the drag ends (one undo step per drag)
                ClipParamRow(ctx: ctx, label: tr("audio.strength"), spec: RowSpec(range: 0...100, step: 5, format: Fmt.int),
                             get: { [path, defaultValue] c, _ in (c.audio[keyPath: path] ?? defaultValue) * 100 },
                             set: { [path] c, v, _ in c.audio[keyPath: path] = (v / 5).rounded() * 5 / 100 },
                             gestureName: "cmd.audioEffect")
            }
        }
    }
}

struct SeparationSection: View {
    let ctx: InspectorContext
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 8) {
                Text(loc: "audio.separation.hint").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                SegmentedTabs(VocalSeparation.allCases.map { ($0.rawValue, tr($0.nameKey)) },
                              selection: AudioInspector.clipBinding(ctx, "cmd.separation", get: { $0.audio.separation?.rawValue ?? "keepVocals" },
                                                                    set: { c, v in c.audio.separation = VocalSeparation(rawValue: v) }))
                // AU-009 (F3): speech (Apple voice isolation) or singing over music (HTDemucs vocals)
                InlineRow(label: tr("audio.isolate.source")) {
                    SegmentedTabs(IsolateSource.allCases.map { ($0.rawValue, tr($0.nameKey)) },
                                  selection: AudioInspector.clipBinding(ctx, "cmd.separation", get: { ($0.audio.isolateSource ?? .speech).rawValue },
                                                                        set: { c, v in let s = IsolateSource(rawValue: v); c.audio.isolateSource = s == .music ? .music : nil }))
                    .testID("audio.isolate.source")
                }
                if ctx.clip?.audio.isolateSource == .music, !DemucsRuntime.isAvailable {
                    HStack(spacing: 8) {
                        Text(loc: "audio.isolate.music.needsModel").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        // OB-07: download prompt + progress, then the audio is re-planned with the stems model
                        Button(tr("audio.isolate.music.getModel")) { let s = ctx.store; s.requireModels([ModelCatalog.demucs4]) { s.engine.forceRebuild() } }
                            .buttonStyle(SecondaryButtonStyle()).testID("audio.isolate.getModel")
                    }
                }
            }
        }
    }
}

struct BeatsSection: View {
    let ctx: InspectorContext
    var body: some View {
        WithPerceptionTracking {
            let store = ctx.store
            VStack(alignment: .leading, spacing: 8) {
                Text(loc: "audio.beats.hint").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(tr("audio.beats.level1")) { store.autoBeats(level: 1) }.buttonStyle(SecondaryButtonStyle())
                    Button(tr("audio.beats.level2")) { store.autoBeats(level: 2) }.buttonStyle(SecondaryButtonStyle())
                    Spacer()
                    if let n = ctx.clip?.beats?.count { Text(verbatim: tr("audio.beats.count", n)).font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary) }
                }
            }
        }
    }
}

struct DuckingSection: View {
    let ctx: InspectorContext
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 6) {
                Text(loc: "audio.ducking.hint").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                ClipParamRow(ctx: ctx, label: tr("audio.ducking.amount"), spec: RowSpec(range: -30...(-3), step: 1, format: { Fmt.decibels($0, places: 0) }),
                             get: { c, _ in c.audio.ducking?.amountDB ?? -12 }, set: { c, v, _ in c.audio.ducking?.amountDB = v.rounded() },
                             gestureName: "cmd.ducking")
            }
        }
    }
}

struct ToneSection: View {
    let ctx: InspectorContext
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 6) {
                ClipParamRow(ctx: ctx, label: tr("audio.pitch"), spec: RowSpec(range: -12...12, origin: 0, step: 0.5, format: { ($0 > 0.04 ? "+" : "") + Fmt.num($0, 1) }),
                             get: { c, _ in c.audio.pitch }, set: { c, v, _ in c.audio.pitch = (v * 2).rounded() / 2 }, gestureName: "cmd.pitch")
                HStack {
                    Text(loc: "audio.channels").font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Picker(tr("audio.channels"), selection: AudioInspector.clipBinding(ctx, "cmd.channels", get: { $0.audio.channels }, set: { c, v in c.audio.channels = v })) {
                        ForEach(ChannelMode.allCases, id: \.self) { Text(loc: $0.nameKey).tag($0) }
                    }
                    .labelsHidden().frame(width: 180)
                }
            }
        }
    }
}

/// 10-band graphic EQ: presets + vertical sliders (live: heard immediately, no rebuild).
struct EQEditor: View {
    let ctx: InspectorContext
    static let presets: [(id: String, gains: [Double])] = [
        ("flat", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ("voice", [-6, -4, -1, 0, 1, 2, 3, 3, 2, 1]),
        ("bass", [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        ("treble", [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
        ("warm", [2, 2, 2, 1, 0, -1, -1, -2, -2, -3]),
        ("bright", [-2, -1, 0, 0, 0, 1, 2, 3, 4, 4]),
        ("lofi", [-12, -8, -2, 0, 2, 2, 0, -4, -10, -12]),
    ]
    var body: some View {
        WithPerceptionTracking {
            let store = ctx.store
            let eq = ctx.clip?.audio.eq ?? AudioEQ()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(loc: "audio.eq.preset").font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Picker(tr("audio.eq.preset"), selection: Binding.perceived(get: { eq.presetID ?? "custom" }, set: { id in
                        guard let p = Self.presets.first(where: { $0.id == id }), let cid = ctx.clip?.id else { return }
                        Bind.apply(store, cid, "cmd.eq") { $0.audio.eq = AudioEQ(gains: p.gains, presetID: p.id) }
                    })) {
                        Text(loc: "audio.eq.custom").tag("custom")
                        ForEach(Self.presets, id: \.id) { Text(loc: "audio.eq.\($0.id)").tag($0.id) }
                    }
                    .labelsHidden().frame(width: 180)
                }
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0..<AudioEQ.frequencies.count, id: \.self) { i in
                        WithPerceptionTracking {
                            VStack(spacing: 4) {
                                Text(verbatim: String(format: "%+.0f", eq.gains[i])).font(.system(size: 9).monospacedDigit()).foregroundStyle(Theme.textTertiary)
                                Slider(value: Binding.perceived(get: { eq.gains[i] }, set: { v in
                                    guard let id = ctx.clip?.id else { return }
                                    Bind.apply(store, id, "cmd.eq") { c in
                                        if c.audio.eq == nil { c.audio.eq = AudioEQ() }
                                        c.audio.eq?.gains[i] = v.rounded(); c.audio.eq?.presetID = nil
                                    }
                                }), in: AudioEQ.gainRange) { editing in editing ? store.beginGesture("cmd.eq") : store.endGesture() }
                                    .controlSize(.mini).valseSliderTint()
                                    .frame(width: 84)
                                    .rotationEffect(.degrees(-90))
                                    .frame(width: 22, height: 84)
                                let f = AudioEQ.frequencies[i]
                                Text(verbatim: f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))").font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }
}

/// Voice changer (UX.md §5.1, [43]): ☐ Apply to all · search · pills Voice filters / Voice characters · tile grid.
struct VoiceChangerView: View {
    let ctx: InspectorContext
    @State private var category: String = VoiceCategory.filter.rawValue
    @State private var query = ""
    @State private var applyToAll = false

    var body: some View {
        WithPerceptionTracking {
            let store = ctx.store
            let current = ctx.clip?.audio.voice
            let pending = AudioInspector.pending(ctx)
            let items = VoiceEffects.all.filter { $0.category.rawValue == category }
                .filter { query.isEmpty || tr($0.nameKey).localizedCaseInsensitiveContains(query) }
            VStack(alignment: .leading, spacing: 12) {
                Toggle(tr("audio.voice.applyToAll"), isOn: Binding.perceived(get: { applyToAll }, set: { v in
                    applyToAll = v
                    if v { store.applyVoice(current, toAll: true) }
                }))
                .toggleStyle(.checkbox).font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
                    TextField(tr("audio.voice.search"), text: $query).textFieldStyle(.plain).font(Theme.Fonts.row)
                }
                .padding(.horizontal, 8).frame(height: 28)
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
                HStack(spacing: 8) {
                    ForEach(VoiceCategory.allCases, id: \.self) { c in
                        WithPerceptionTracking {
                            Text(loc: c.nameKey)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(category == c.rawValue ? Theme.textPrimary : Theme.textSecondary)
                                .padding(.horizontal, 12).frame(height: 26)
                                .background(category == c.rawValue ? Theme.segmentSelected : Theme.inset, in: Capsule())
                                .contentShape(Capsule())
                                .onTapGesture { category = c.rawValue }
                        }
                    }
                }
                if pending != nil { ProcessingRow(ctx: ctx) }
                Text(loc: "audio.voice.all").font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64, maximum: 78), spacing: 8)], spacing: 8) {
                    tile(nil, selected: current == nil)
                    ForEach(items) { d in WithPerceptionTracking { tile(d, selected: current?.typeID == d.id) } }
                }
                if let current, let d = VoiceEffects.descriptor(current.typeID) {
                    ForEach(d.params, id: \.key) { spec in
                        WithPerceptionTracking {
                            ClipParamRow(ctx: ctx, label: tr(spec.nameKey), spec: RowSpec(range: 0...100, step: 1, format: Fmt.int),
                                         get: { c, _ in c.audio.voice?.params[spec.key] ?? spec.defaultValue },
                                         set: { c, v, _ in c.audio.voice?.params[spec.key] = v.rounded() }, gestureName: "cmd.voice")
                        }
                    }
                }
            }
        }
    }

    func tile(_ d: VoiceEffectDescriptor?, selected: Bool) -> some View {
        Text(verbatim: d.map { tr($0.nameKey) } ?? tr("voice.original"))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(4)
            .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64)
            .background(Color(white: 0.23), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Theme.accent : .clear, lineWidth: 2))
            .contentShape(Rectangle())
            .onTapGesture { ctx.store.applyVoice(d?.makeEffect(), toAll: applyToAll) }
    }
}
