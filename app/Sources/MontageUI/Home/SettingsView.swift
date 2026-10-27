import SwiftUI
import AppKit
import MontageCore
import MontageEngine
import Perception

public enum SettingsTab: String, CaseIterable, Sendable {
    case general, project, edit, audio, performance, export, music, shortcuts, about
    var nameKey: String { "settings.tab.\(rawValue)" }
}

/// Settings dialog (UX.md §2.5, [06]–[09]): CapCut's modal with a segmented tab bar and [Cancel] [Save]. Every edit is
/// staged in a draft (settings + keymap copy) and applied on Save — language switches live, no relaunch.
struct SettingsView: View {
    @Perception.Bindable var app: AppModel
    @State private var tab: SettingsTab
    @State private var draft = AppSettings()
    @State private var language = "system"
    @State private var keymap = Keymap(url: nil)
    @State private var cacheSizes: [CacheManager.Category: Int64] = [:]
    @State private var confirmClose = false

    init(app: AppModel, initialTab: SettingsTab) {
        self.app = app
        _tab = State(initialValue: initialTab)
    }

    var width: CGFloat { tab == .shortcuts ? 760 : 640 }
    var dirty: Bool {
        draft != app.preferences.settings || language != L10n.shared.languagePreference
            || keymap.preset != Keymap.shared.preset || keymap.overrides != Keymap.shared.overrides
    }

    var body: some View {
        WithPerceptionTracking {
            DialogCard(title: tr("settings.title"), width: width, onClose: close, bodyScrolls: false) {
                VStack(spacing: 14) {
                    SettingsTabBar(selection: $tab)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            switch tab {
                            case .general: GeneralSettings(draft: $draft, language: $language)
                            case .project: ProjectSettingsTab(draft: $draft, sizes: cacheSizes, editing: app.screen == .editor, clear: clear)
                            case .edit: EditSettings(draft: $draft)
                            case .audio: AudioSettings(draft: $draft)
                            case .performance: PerformanceSettings(draft: $draft, sizes: cacheSizes, editing: app.screen == .editor, clear: clear)
                            case .export: ExportDefaultsSettings(draft: $draft)
                            case .music: MusicSettings()
                            case .shortcuts: ShortcutList(keymap: keymap, compact: true)
                            case .about: AboutPanel()
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lockHorizontalScroll()   // U1-2: vertical only
                    }
                    .horizontalBounceBasedOnSize()
                    // BUG-OVERSIZED-SHEETS: shrinks (down to 120 pt) when the window is smaller than the dialog
                    .frame(minHeight: 120, idealHeight: tab == .shortcuts ? 470 : 440, maxHeight: tab == .shortcuts ? 470 : 440)
                    .background(Theme.inset.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    .testID("settings.body")
                    if tab == .shortcuts { ShortcutFooterControls(keymap: keymap) }
                }
                .padding([.top, .horizontal], 16)
            } footer: {
                DialogFooter(okEnabled: dirty, onCancel: close, onOK: save)
            }
            .testID("settings")
            .onAppear {
                draft = app.preferences.settings
                language = L10n.shared.languagePreference
                keymap = Keymap.shared.copy()
                reloadSizes()
            }
            .alert(tr("settings.unsaved.title"), isPresented: $confirmClose) {
                Button(tr("common.close"), role: .destructive) { app.modal = nil }
                Button(tr("common.save")) { save() }
            } message: { Text(loc: "settings.unsaved.message") }
        }
    }

    func close() { if dirty { confirmClose = true } else { app.modal = nil } }

    func save() {
        app.preferences.update(draft)
        Keymap.shared.adopt(keymap)
        let lang = language
        app.modal = nil
        // also when only the session language differs (`--lang`, UI tests): the choice must take effect now
        if lang != L10n.shared.languagePreference || L10n.resolveLanguage(lang) != L10n.shared.language {
            L10n.shared.setLanguagePreference(lang)
        }
        app.store.showToast(tr("settings.saved"))
        app.refreshSoon()
    }

    /// UI tests: fixed cache sizes (the real cache folder isn't sandboxed and its size varies between runs/machines,
    /// which broke the Settings screenshot baselines); "clear" then zeroes them instead of deleting the user's caches.
    static let uitestCacheSizes: [CacheManager.Category: Int64] = [.proxies: 1_250_000_000, .thumbs: 48_000_000,
                                                                   .waveforms: 3_200_000, .render: 420_000_000]

    func reloadSizes() {
        if TestAnchors.isEnabled {
            if cacheSizes.isEmpty { cacheSizes = Self.uitestCacheSizes }
            return
        }
        Task {
            cacheSizes = await Task.detached(priority: .utility) { CacheManager().sizes() }.value
        }
    }

    func clear(_ c: CacheManager.Category?) {
        if TestAnchors.isEnabled {
            for k in cacheSizes.keys where c == nil || k == c { cacheSizes[k] = 0 }
            return
        }
        if let c { CacheCleaner.clear(c) } else {
            for c in CacheManager.Category.allCases where app.screen == .home || CacheCleaner.safeWhileEditing.contains(c) { CacheCleaner.clear(c) }
        }
        reloadSizes()
    }
}

struct SettingsTabBar: View {
    @Binding var selection: SettingsTab
    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 0) {
                ForEach(SettingsTab.allCases, id: \.self) { t in
                    WithPerceptionTracking {
                        Button { selection = t } label: {
                            // the editor's tab sticker (round 10: the raised segment looked off); fixed weight, so the
                            // selection never shifts the other tabs
                            // 9 tabs: every label keeps its natural width (the sticker hugs it), the cells share
                            // what is left; en and fr both fit the 640 pt dialog
                            ValseTabLabel(active: selection == t) {
                                Text(verbatim: tr(t.nameKey))
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1).fixedSize()
                                    .frame(minHeight: 20)
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .testID("settings.tab.\(t.rawValue)")
                    }
                }
            }
            // room for the sticker's lift and its hard block; no inset track (the sticker carries the selection)
            .padding(.top, 1).padding(.bottom, 3)
        }
    }
}

// MARK: - Rows

/// Label column (150 pt) + control, CapCut settings row.
struct SettingsRow<C: View>: View {
    let label: String
    var hint: String?
    let content: C
    init(_ label: String, hint: String? = nil, @ViewBuilder _ content: () -> C) { self.label = label; self.hint = hint; self.content = content() }
    var body: some View {
        WithPerceptionTracking {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(verbatim: label).font(.system(size: 12.5)).foregroundStyle(IStyle.label).frame(width: 170, alignment: .leading)
                VStack(alignment: .leading, spacing: 5) {
                    content
                    if let hint { HintText(text: hint) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6)
        }
    }
}

struct SettingsDivider: View {
    var body: some View { WithPerceptionTracking { Rectangle().fill(Theme.separator).frame(height: 1).padding(.vertical, 10) } }
}

struct CheckLine: View {
    let label: String
    @Binding var isOn: Bool
    var id: String
    var body: some View {
        WithPerceptionTracking {
            Button { isOn.toggle() } label: {
                HStack(alignment: .top, spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 3).fill(isOn ? Theme.accent : Theme.stepper)
                        if isOn { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.onAccent) }
                    }
                    .frame(width: 16, height: 16)
                    Text(verbatim: label).font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .testID("settings.check.\(id)")
        }
    }
}

struct SwitchButton: View {
    @Binding var isOn: Bool
    var id: String
    /// SE-017: what VoiceOver says (the row's label).
    var label = ""
    var body: some View {
        WithPerceptionTracking {
            Button { withAnimation(.easeOut(duration: 0.12)) { isOn.toggle() } } label: {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? Theme.accent : Theme.stepper).frame(width: 36, height: 20)
                    Circle().fill(Color.white).frame(width: 14, height: 14).padding(.horizontal, 3)
                }
                .frame(width: 36, height: 20)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            // U1-2: no text inside, so in a `SettingsRow` (first-baseline aligned) the switch sat ABOVE its label; align the
            // label's first line with the switch's middle instead.
            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
            .accessibilityLabel(Text(verbatim: label.isEmpty ? tr("ax.switch") : label))
            .accessibilityValue(Text(verbatim: tr(isOn ? "ax.on" : "ax.off")))
            .testID("settings.switch.\(id)")
            .accessibilityValue(Text(verbatim: isOn ? "1" : "0"))
        }
    }
}

/// Number field + unit with a stepper (CapCut "[10] frames", "[5.0] s").
struct NumberSetting: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var decimals = 0
    let unit: String
    var id: String
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 6) {
                TextField("", text: $text)
                    .textFieldStyle(.plain).font(Theme.Fonts.numeric).multilineTextAlignment(.center)
                    .frame(width: 64, height: 28)
                    .background(Theme.inset, in: RoundedRectangle(cornerRadius: 4))
                    .focused($focused)
                    .onSubmit(commit)
                    .onValueChange(of: focused) { _, f in if !f { commit() } }
                    .testID("settings.field.\(id)")
                Text(verbatim: unit).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                // FB-09: same height as the field, each half a full 22 × 14 pt hit target (was the 7 pt glyph only)
                StepperButton(width: 22, halfHeight: 14, testID: "settings.field.\(id)") { d in set(value + Double(d) * step) }
            }
            .onAppear { text = format(value) }
            .onValueChange(of: value) { _, v in if !focused { text = format(v) } }
        }
    }
    func format(_ v: Double) -> String { String(format: "%.\(decimals)f", locale: L10n.shared.locale, v) }
    func set(_ v: Double) { value = min(max((v / step).rounded() * step, range.lowerBound), range.upperBound); text = format(value) }
    func commit() {
        if let v = NumberParse.number(text) { set(v) }
        text = format(value)
    }
}

struct PathSetting: View {
    let path: String
    var onChoose: (() -> Void)?
    var onReset: (() -> Void)?
    var id: String
    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 6) {
                Text(verbatim: (path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .background(IStyle.dropdown, in: RoundedRectangle(cornerRadius: 4))
                    .help(path)
                if let onChoose {
                    SmallSquareButton(symbol: "folder", help: tr("settings.choose"), id: "\(id).choose", action: onChoose)
                }
                if let onReset {
                    SmallSquareButton(symbol: "arrow.counterclockwise", help: tr("settings.resetDefault"), id: "\(id).reset", action: onReset)
                }
            }
        }
    }
}

struct SmallSquareButton: View {
    let symbol: String
    let help: String
    var id: String
    var enabled = true
    let action: () -> Void
    var body: some View {
        WithPerceptionTracking {
            Button(action: action) {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Theme.textPrimary.opacity(enabled ? 0.9 : 0.35))
                    .frame(width: 28, height: 28).background(Theme.stepper, in: RoundedRectangle(cornerRadius: 4)).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(help).disabled(!enabled)
            .testID("settings.button.\(id)")
        }
    }
}

/// "219.65 MB 🗑"
struct CacheSizeRow: View {
    let size: Int64?
    var enabled = true
    var id: String
    let onClear: () -> Void
    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 8) {
                Text(verbatim: size.map(HomeFormat.bytes) ?? "…").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
                SmallSquareButton(symbol: "trash", help: tr("cache.clear"), id: "clear.\(id)", enabled: enabled && (size ?? 0) > 0, action: onClear)
            }
        }
    }
}

func chooseFolder(_ message: String, start: String?) -> String? {
    let p = NSOpenPanel()
    p.canChooseDirectories = true
    p.canChooseFiles = false
    p.canCreateDirectories = true
    p.message = message
    if let start { p.directoryURL = URL(fileURLWithPath: start) }
    return p.runModal() == .OK ? p.url?.path : nil
}

// MARK: - Tabs

struct GeneralSettings: View {
    @Binding var draft: AppSettings
    @Binding var language: String
    var body: some View {
        WithPerceptionTracking {
            SettingsRow(tr("settings.language")) {
                VStack(spacing: 0) {
                    ForEach(["system", "en", "fr"], id: \.self) { l in
                        WithPerceptionTracking {
                            Button { language = l } label: {
                                HStack {
                                    Text(verbatim: tr("settings.language.\(l)")).font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    if language == l { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent) }
                                }
                                .padding(.horizontal, 12).frame(height: 32).contentShape(Rectangle())
                                .background(language == l ? Color.white.opacity(0.05) : .clear)
                            }
                            .buttonStyle(.plain)
                            .testID("settings.language.\(l)")
                        }
                    }
                }
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
                HintText(text: tr("settings.language.hint"))
            }
            SettingsDivider()
            SettingsRow(tr("settings.theme")) {
                Text(loc: "settings.theme.dark").font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
                HintText(text: tr("settings.theme.hint"))
            }
            SettingsDivider()
            SettingsRow(tr("settings.notifications")) {
                CheckLine(label: tr("settings.notifyExport"), isOn: $draft.notifyOnExport, id: "notifyExport")
                CheckLine(label: tr("settings.exportSound"), isOn: $draft.exportSound, id: "exportSound")
            }
        }
    }
}

struct ProjectSettingsTab: View {
    @Binding var draft: AppSettings
    let sizes: [CacheManager.Category: Int64]
    let editing: Bool
    let clear: (CacheManager.Category?) -> Void
    var body: some View {
        WithPerceptionTracking {
            SettingsRow(tr("settings.saveTo"), hint: tr("settings.saveTo.hint")) {
                PathSetting(path: draft.projectsDirectory ?? MontagePaths.defaultDraftsDirectory.path,
                            onChoose: editing ? nil : { if let p = chooseFolder(tr("settings.saveTo"), start: draft.projectsDirectory) { draft.projectsDirectory = p } },
                            onReset: draft.projectsDirectory == nil || editing ? nil : { draft.projectsDirectory = nil }, id: "saveTo")
                // PM-009: external / network / disconnected drive warning
                if let p = draft.projectsDirectory, let w = StorageWarningText.settingsLine(StorageLocation.of(URL(fileURLWithPath: p))) {
                    StorageWarningLine(text: w)
                }
            }
            SettingsRow(tr("details.importMaterial"), hint: tr("settings.importMaterial.hint")) {
                HStack(spacing: 16) {
                    RadioLine(label: tr("details.importMaterial.copy"), selected: draft.copyMediaOnImport, id: "importCopy") { draft.copyMediaOnImport = true }
                    RadioLine(label: tr("details.importMaterial.keep"), selected: !draft.copyMediaOnImport, id: "importKeep") { draft.copyMediaOnImport = false }
                }
            }
            SettingsRow(tr("settings.subprojectMedia"), hint: tr("settings.subprojectMedia.hint")) {
                CheckLine(label: tr("settings.subprojectMedia.label"), isOn: $draft.showSubprojectMedia, id: "subprojectMedia")
            }
            SettingsDivider()
            SettingsRow(tr("settings.cacheManagement")) {
                RadioLine(label: tr("settings.cache.keep"), selected: draft.cacheAutoDeleteDays == nil, id: "keep") { draft.cacheAutoDeleteDays = nil }
                HStack(spacing: 8) {
                    RadioLine(label: tr("settings.cache.autoDelete"), selected: draft.cacheAutoDeleteDays != nil, id: "autoDelete") {
                        if draft.cacheAutoDeleteDays == nil { draft.cacheAutoDeleteDays = 30 }
                    }
                    Dropdown(items: [7, 15, 30, 60, 90].map { ($0, tr("settings.cache.days", $0)) }, selection: draft.cacheAutoDeleteDays ?? 30,
                             enabled: draft.cacheAutoDeleteDays != nil) { draft.cacheAutoDeleteDays = $0 }
                        .frame(width: 150)
                }
            }
            SettingsRow(tr("settings.cacheSize"), hint: editing ? tr("settings.cache.editingHint") : nil) {
                CacheSizeRow(size: sizes.isEmpty ? nil : sizes.values.reduce(0, +), id: "all") { clear(nil) }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(CacheManager.Category.allCases, id: \.self) { c in
                        WithPerceptionTracking {
                            if let s = sizes[c], s > 0 {
                                HStack {
                                    Text(verbatim: tr(c.nameKey)).font(Theme.Fonts.hint).foregroundStyle(Theme.textSecondary)
                                    Spacer()
                                    Text(verbatim: HomeFormat.bytes(s)).font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary).monospacedDigit()
                                }
                                .frame(maxWidth: 260)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct RadioLine: View {
    let label: String
    let selected: Bool
    var id: String
    let action: () -> Void
    var body: some View {
        WithPerceptionTracking {
            Button(action: action) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().stroke(selected ? Theme.accent : Theme.textTertiary, lineWidth: 1.5).frame(width: 14, height: 14)
                        if selected { Circle().fill(Theme.accent).frame(width: 7, height: 7) }
                    }
                    Text(verbatim: label).font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .testID("settings.radio.\(id)")
        }
    }
}

struct EditSettings: View {
    @Binding var draft: AppSettings
    var body: some View {
        WithPerceptionTracking {
            SettingsRow(tr("settings.stepFrames"), hint: tr("settings.stepFrames.hint")) {
                NumberSetting(value: Binding.perceived(get: { Double(draft.stepFrames) }, set: { draft.stepFrames = Int($0) }), range: 2...100,
                              unit: tr("settings.unit.frames"), id: "stepFrames")
            }
            SettingsRow(tr("settings.imageDuration")) {
                NumberSetting(value: $draft.imageDuration, range: 0.1...60, step: 0.1, decimals: 1, unit: tr("settings.unit.seconds"), id: "imageDuration")
            }
            SettingsRow(tr("settings.freezeDuration")) {
                NumberSetting(value: $draft.freezeDuration, range: 0.1...60, step: 0.1, decimals: 1, unit: tr("settings.unit.seconds"), id: "freezeDuration")
            }
            SettingsRow(tr("settings.linkFreeze"), hint: tr("settings.linkFreeze.hint")) {
                CheckLine(label: tr("settings.linkFreeze.label"), isOn: $draft.linkFreezeFrames, id: "linkFreeze")
            }
            SettingsRow(tr("settings.transitionDuration"), hint: draft.transitionDuration == nil ? tr("settings.transitionDuration.hint") : nil) {
                HStack(spacing: 10) {
                    CheckLine(label: tr("settings.transitionDuration.custom"), isOn: Binding.perceived(get: { draft.transitionDuration != nil },
                                                                                        set: { draft.transitionDuration = $0 ? 0.5 : nil }), id: "transitionCustom")
                    if draft.transitionDuration != nil {
                        NumberSetting(value: Binding.perceived(get: { draft.transitionDuration ?? 0.5 }, set: { draft.transitionDuration = $0 }),
                                      range: 0.1...10, step: 0.1, decimals: 1, unit: tr("settings.unit.seconds"), id: "transitionDuration")
                    }
                }
            }
            SettingsRow(tr("settings.timecode")) {
                Dropdown(items: TimecodeStyle.allCases.map { ($0.rawValue, tr($0.nameKey)) }, selection: draft.timecodeStyle) { draft.timecodeStyle = $0 }
                    .frame(width: 200)
                if draft.timecodeStyle == TimecodeStyle.frames.rawValue {
                    CheckLine(label: tr("settings.dropFrame"), isOn: $draft.dropFrame, id: "dropFrame")
                }
            }
            SettingsRow(tr("settings.scrubAudio"), hint: tr("settings.scrubAudio.hint")) {
                SwitchButton(isOn: $draft.scrubAudio, id: "scrubAudio", label: tr("settings.scrubAudio"))
            }
            SettingsDivider()
            SettingsRow(tr("settings.mouse.wheel")) {
                Dropdown(items: TimelineScrollMapping.WheelScroll.allCases.map { ($0.rawValue, tr($0.nameKey)) }, selection: draft.mouseWheelScroll) { draft.mouseWheelScroll = $0 }
                    .frame(width: 260).testID("settings.mouse.wheel")
            }
            SettingsRow(tr("settings.mouse.zoom"), hint: tr("settings.mouse.hint")) {
                Dropdown(items: TimelineScrollMapping.ZoomModifier.allCases.map { ($0.rawValue, tr($0.nameKey)) }, selection: draft.mouseZoomModifier) { draft.mouseZoomModifier = $0 }
                    .frame(width: 260).testID("settings.mouse.zoom")
            }
            SettingsDivider()
            Text(loc: "settings.newProjects").font(.system(size: 12, weight: .medium)).foregroundStyle(IStyle.caption).padding(.bottom, 4)
            SettingsRow(tr("details.frameRate")) {
                Dropdown(items: FrameRate.common.map { ($0, HomeFormat.fps($0)) }, selection: draft.defaultFrameRate) { draft.defaultFrameRate = $0 }
                    .frame(width: 200)
            }
            SettingsRow(tr("details.ratio"), hint: draft.defaultRatio == "original" ? tr("newProject.originalHint") : nil) {
                Dropdown(items: ProjectSettingsSheet.ratios.map { ($0, ProjectSettingsSheet.ratioTitle($0)) }, selection: draft.defaultRatio) { draft.defaultRatio = $0 }
                    .frame(width: 200)
            }
        }
    }
}

/// Settings ▸ Audio (SE-011 / AU-024): preview output device, default voice-over input, monitor volume, scrub audio,
/// export notification sound.
struct AudioSettings: View {
    @Binding var draft: AppSettings
    @State private var outputs: [AudioDevices.Device] = []
    @State private var inputs: [AudioDevices.Device] = []
    var body: some View {
        WithPerceptionTracking {
            SettingsRow(tr("settings.audio.output"), hint: tr("settings.audio.output.hint")) {
                Dropdown(items: [("", tr("settings.audio.systemDefault"))] + outputs.map { ($0.uid, $0.name) },
                         selection: draft.audioOutputDeviceUID ?? "") { draft.audioOutputDeviceUID = $0.isEmpty ? nil : $0 }
                    .frame(width: 280).testID("settings.audio.output")
            }
            SettingsRow(tr("settings.audio.input")) {
                Dropdown(items: [("", tr("settings.audio.systemDefault"))] + inputs.map { ($0.uid, $0.name) },
                         selection: draft.audioInputDeviceUID ?? "") { draft.audioInputDeviceUID = $0.isEmpty ? nil : $0 }
                    .frame(width: 280).testID("settings.audio.input")
            }
            SettingsDivider()
            SettingsRow(tr("settings.audio.monitor"), hint: tr("settings.audio.monitor.hint")) {
                NumberSetting(value: Binding.perceived(get: { (draft.monitorVolume * 100).rounded() }, set: { draft.monitorVolume = $0 / 100 }),
                              range: 0...100, unit: "%", id: "monitorVolume")
            }
            SettingsRow(tr("settings.scrubAudio"), hint: tr("settings.scrubAudio.hint")) {
                SwitchButton(isOn: $draft.scrubAudio, id: "scrubAudioAudio", label: tr("settings.scrubAudio"))
            }
            SettingsRow(tr("settings.notifications")) {
                CheckLine(label: tr("settings.exportSound"), isOn: $draft.exportSound, id: "exportSoundAudio")
                Button(tr("settings.audio.testSound")) { NotificationSounds.play(.success) }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small).testID("settings.button.testSound")
            }
            .onAppear {
                // UI tests: no machine-dependent device names in snapshots
                if !TestAnchors.isEnabled { outputs = AudioDevices.outputs(); inputs = AudioDevices.inputs() }
            }
        }
    }
}

struct PerformanceSettings: View {
    @Binding var draft: AppSettings
    let sizes: [CacheManager.Category: Int64]
    let editing: Bool
    let clear: (CacheManager.Category?) -> Void
    var cache: URL { MontagePaths.cacheDirectory }
    var body: some View {
        WithPerceptionTracking {
            SettingsRow(tr("settings.encode")) {
                HStack(spacing: 5) {
                    CheckLine(label: tr("settings.hwEncode"), isOn: $draft.hardwareEncoding, id: "hwEncode")
                    SettingsHelp(text: tr("ex.hw.encode.help"), id: "hwEncode")
                }
                // EX-016: CapCut's "Faster exporting, but may have color differences" (needs the hardware encoder)
                HStack(spacing: 5) {
                    CheckLine(label: tr("ex.hw.fastExport"), isOn: Binding.perceived(get: { draft.hardwareEncoding && draft.fastExport },
                                                                             set: { draft.fastExport = $0 }), id: "fastExport")
                    SettingsHelp(text: tr("ex.hw.fastExport.help"), id: "fastExport")
                }
                .padding(.leading, 24)
                .disabled(!draft.hardwareEncoding).opacity(draft.hardwareEncoding ? 1 : 0.45)
                // Apple silicon always decodes H.264 / HEVC / ProRes on the media engine: shown checked and locked (honest)
                HStack(spacing: 5) {
                    CheckLine(label: tr("ex.hw.decode"), isOn: .constant(true), id: "hwDecode").disabled(true).opacity(0.6)
                    SettingsHelp(text: tr("settings.hwDecode.hint"), id: "hwDecode")
                }
            }
            SettingsDivider()
            SettingsRow(tr("player.quality"), hint: tr("settings.previewQuality.hint", MemoryBudget.isLowMemoryMachine ? "720p" : "1080p")) {
                Dropdown(items: PreviewQuality.allCases.map { ($0.rawValue, tr($0.nameKey)) }, selection: draft.previewQuality) { draft.previewQuality = $0 }
                    .frame(width: 200)
            }
            SettingsRow(tr("settings.priority"), hint: tr(PlaybackPriority(rawValue: draft.playbackPriority)?.hintKey ?? "settings.priority.quality.hint")) {
                HStack(spacing: 16) {
                    ForEach(PlaybackPriority.allCases, id: \.self) { p in
                        WithPerceptionTracking {
                            RadioLine(label: tr(p.nameKey), selected: draft.playbackPriority == p.rawValue, id: "priority.\(p.rawValue)") { draft.playbackPriority = p.rawValue }
                        }
                    }
                }
            }
            SettingsRow(tr("settings.autoOptimization"), hint: tr("settings.autoOptimization.hint")) {
                Dropdown(items: AutoOptimization.allCases.map { ($0.rawValue, tr($0.nameKey)) }, selection: draft.autoOptimization) { draft.autoOptimization = $0 }
                    .frame(width: 200).testID("settings.autoOptimization")
            }
            SettingsDivider()
            SettingsRow(tr("settings.proxy")) {
                CheckLine(label: tr("settings.useProxies"), isOn: $draft.useProxies, id: "useProxies")
                HintText(text: tr("settings.useProxies.hint"))
            }
            SettingsRow(tr("settings.proxyCreation")) {
                Dropdown(items: ProxyManager.Policy.allCases.map { ($0.rawValue, tr("settings.proxyPolicy.\($0.rawValue)")) }, selection: draft.proxyPolicy) { draft.proxyPolicy = $0 }
                    .frame(width: 260)
            }
            SettingsRow(tr("settings.proxyResolution"), hint: tr("settings.proxyResolution.hint")) {   // MI-008 (F3)
                Dropdown(items: [540, 720, 1080].map { ($0, "\($0)p") }, selection: draft.proxyResolution) { draft.proxyResolution = $0 }
                    .frame(width: 260)
                CheckLine(label: tr("settings.proxyOnlyAbove"), isOn: $draft.proxyOnlyAbove, id: "proxyOnlyAbove")
            }
            SettingsRow(tr("settings.proxyLocation")) {
                PathSetting(path: cache.appendingPathComponent("proxies").path, onChoose: { NSWorkspace.shared.activateFileViewerSelecting([cache.appendingPathComponent("proxies")]) }, id: "proxyLocation")
            }
            SettingsRow(tr("settings.proxySize")) {
                CacheSizeRow(size: sizes[.proxies], enabled: !editing, id: "proxies") { clear(.proxies) }
            }
            SettingsDivider()
            SettingsRow(tr("settings.renderCacheSize")) {
                CacheSizeRow(size: sizes[.render], id: "render") { clear(.render) }
            }
            SettingsRow(tr("settings.autoClear"), hint: tr("settings.autoClear.hint", Int(draft.renderCacheLimitGB))) {
                NumberSetting(value: $draft.renderCacheLimitGB, range: 1...500, unit: "GB", id: "renderLimit")
            }
            SettingsRow(tr("settings.autoRender"), hint: tr("settings.autoRender.hint")) {
                SwitchButton(isOn: $draft.autoRender, id: "autoRender", label: tr("settings.autoRender"))
            }
            SettingsDivider()
            SettingsRow(tr("settings.cacheLocation"), hint: tr("settings.cacheLocation.hint")) {
                PathSetting(path: draft.cacheDirectory ?? MontagePaths.defaultCacheDirectory.path,
                            onChoose: { if let p = chooseFolder(tr("settings.cacheLocation"), start: draft.cacheDirectory) { draft.cacheDirectory = p } },
                            onReset: draft.cacheDirectory == nil ? nil : { draft.cacheDirectory = nil }, id: "cacheLocation")
            }
        }
    }
}

struct ExportDefaultsSettings: View {
    @Binding var draft: AppSettings
    var body: some View {
        WithPerceptionTracking {
            SettingsRow(tr("export.resolution")) {
                Dropdown(items: [(0, tr("settings.export.followProject"))] + ExportSettings.Resolution.allCases.map { ($0.rawValue, $0.label) },
                         selection: draft.exportResolution) { draft.exportResolution = $0 }.frame(width: 220)
            }
            SettingsRow(tr("export.frameRate")) {
                Dropdown(items: [(0.0, tr("settings.export.followProject"))] + FrameRate.common.map { ($0.fps, HomeFormat.fps($0)) },
                         selection: draft.exportFrameRate) { draft.exportFrameRate = $0 }.frame(width: 220)
            }
            SettingsRow(tr("export.codec")) {
                Dropdown(items: ExportSettings.Codec.allCases.map { ($0.rawValue, tr($0.nameKey)) }, selection: draft.exportCodec) { draft.exportCodec = $0 }
                    .frame(width: 220)
            }
            SettingsRow(tr("export.bitrate")) {
                Dropdown(items: ExportSettings.BitrateMode.allCases.filter { $0 != .custom }.map { ($0.rawValue, tr($0.nameKey)) },
                         selection: draft.exportBitrate) { draft.exportBitrate = $0 }.frame(width: 220)
            }
            SettingsRow(tr("export.location")) {
                PathSetting(path: draft.exportDirectory ?? (FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first?.path ?? "~/Movies"),
                            onChoose: { if let p = chooseFolder(tr("export.location"), start: draft.exportDirectory) { draft.exportDirectory = p } },
                            onReset: draft.exportDirectory == nil ? nil : { draft.exportDirectory = nil }, id: "exportLocation")
            }
            HintText(text: tr("settings.export.hint")).padding(.top, 6)
        }
    }
}
