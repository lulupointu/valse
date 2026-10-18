import SwiftUI
import AppKit
import MontageCore
import MontageEngine

public enum SettingsTab: String, CaseIterable, Sendable {
    case general, project, edit, performance, export, shortcuts, about
    var nameKey: String { "settings.tab.\(rawValue)" }
}

/// Settings dialog (UX.md §2.5, [06]–[09]): CapCut's modal with a segmented tab bar and [Cancel] [Save]. Every edit is
/// staged in a draft (settings + keymap copy) and applied on Save — language switches live, no relaunch.
struct SettingsView: View {
    @Bindable var app: AppModel
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

    var width: CGFloat { tab == .shortcuts ? 760 : 580 }
    var dirty: Bool {
        draft != app.preferences.settings || language != L10n.shared.languagePreference
            || keymap.preset != Keymap.shared.preset || keymap.overrides != Keymap.shared.overrides
    }

    var body: some View {
        DialogCard(title: tr("menu.settings"), width: width, onClose: close) {
            VStack(spacing: 14) {
                SettingsTabBar(selection: $tab)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch tab {
                        case .general: GeneralSettings(draft: $draft, language: $language)
                        case .project: ProjectSettingsTab(draft: $draft, sizes: cacheSizes, editing: app.screen == .editor, clear: clear)
                        case .edit: EditSettings(draft: $draft)
                        case .performance: PerformanceSettings(draft: $draft, sizes: cacheSizes, editing: app.screen == .editor, clear: clear)
                        case .export: ExportDefaultsSettings(draft: $draft)
                        case .shortcuts: ShortcutList(keymap: keymap, compact: true)
                        case .about: AboutPanel()
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: tab == .shortcuts ? 470 : 440)
                .background(Theme.inset.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .testID("settings.body")
                if tab == .shortcuts { ShortcutFooterControls(keymap: keymap) }
                DialogFooter(okEnabled: dirty, onCancel: close, onOK: save)
            }
            .padding(16)
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

    func close() { if dirty { confirmClose = true } else { app.modal = nil } }

    func save() {
        app.preferences.update(draft)
        Keymap.shared.adopt(keymap)
        let lang = language
        app.modal = nil
        if lang != L10n.shared.languagePreference { L10n.shared.setLanguagePreference(lang) }
        app.store.showToast(tr("settings.saved"))
        app.refreshSoon()
    }

    func reloadSizes() {
        Task {
            cacheSizes = await Task.detached(priority: .utility) { CacheManager().sizes() }.value
        }
    }

    func clear(_ c: CacheManager.Category?) {
        if let c { CacheCleaner.clear(c) } else {
            for c in CacheManager.Category.allCases where app.screen == .home || CacheCleaner.safeWhileEditing.contains(c) { CacheCleaner.clear(c) }
        }
        reloadSizes()
    }
}

struct SettingsTabBar: View {
    @Binding var selection: SettingsTab
    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases, id: \.self) { t in
                Button { selection = t } label: {
                    Text(verbatim: tr(t.nameKey))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(selection == t ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(selection == t ? Theme.segmentSelected : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .testID("settings.tab.\(t.rawValue)")
            }
        }
        .padding(2)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
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

struct SettingsDivider: View {
    var body: some View { Rectangle().fill(Theme.separator).frame(height: 1).padding(.vertical, 10) }
}

struct CheckLine: View {
    let label: String
    @Binding var isOn: Bool
    var id: String
    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3).fill(isOn ? Theme.accent : Theme.stepper)
                    if isOn { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white) }
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

struct SwitchButton: View {
    @Binding var isOn: Bool
    var id: String
    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.12)) { isOn.toggle() } } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Theme.accent : Theme.stepper).frame(width: 36, height: 20)
                Circle().fill(Color.white).frame(width: 14, height: 14).padding(.horizontal, 3)
            }
            .frame(width: 36, height: 20)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .testID("settings.switch.\(id)")
        .accessibilityValue(Text(verbatim: isOn ? "1" : "0"))
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
        HStack(spacing: 6) {
            TextField("", text: $text)
                .textFieldStyle(.plain).font(Theme.Fonts.numeric).multilineTextAlignment(.center)
                .frame(width: 64, height: 28)
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 4))
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, f in if !f { commit() } }
                .testID("settings.field.\(id)")
            Text(verbatim: unit).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            VStack(spacing: 1) {
                Button { set(value + step) } label: { Image(systemName: "chevron.up").font(.system(size: 7, weight: .bold)).frame(width: 18, height: 12) }
                Button { set(value - step) } label: { Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).frame(width: 18, height: 12) }
            }
            .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
            .background(Theme.stepper, in: RoundedRectangle(cornerRadius: 4))
        }
        .onAppear { text = format(value) }
        .onChange(of: value) { _, v in if !focused { text = format(v) } }
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

struct SmallSquareButton: View {
    let symbol: String
    let help: String
    var id: String
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Theme.textPrimary.opacity(enabled ? 0.9 : 0.35))
                .frame(width: 28, height: 28).background(Theme.stepper, in: RoundedRectangle(cornerRadius: 4)).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).disabled(!enabled)
        .testID("settings.button.\(id)")
    }
}

/// "219.65 MB 🗑"
struct CacheSizeRow: View {
    let size: Int64?
    var enabled = true
    var id: String
    let onClear: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: size.map(CacheManager.format) ?? "…").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
            SmallSquareButton(symbol: "trash", help: tr("cache.clear"), id: "clear.\(id)", enabled: enabled && (size ?? 0) > 0, action: onClear)
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
        SettingsRow(tr("settings.language")) {
            VStack(spacing: 0) {
                ForEach(["system", "en", "fr"], id: \.self) { l in
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

struct ProjectSettingsTab: View {
    @Binding var draft: AppSettings
    let sizes: [CacheManager.Category: Int64]
    let editing: Bool
    let clear: (CacheManager.Category?) -> Void
    var body: some View {
        SettingsRow(tr("settings.saveTo"), hint: tr("settings.saveTo.hint")) {
            PathSetting(path: draft.projectsDirectory ?? MontagePaths.defaultDraftsDirectory.path,
                        onChoose: editing ? nil : { if let p = chooseFolder(tr("settings.saveTo"), start: draft.projectsDirectory) { draft.projectsDirectory = p } },
                        onReset: draft.projectsDirectory == nil || editing ? nil : { draft.projectsDirectory = nil }, id: "saveTo")
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
                    if let s = sizes[c], s > 0 {
                        HStack {
                            Text(verbatim: tr(c.nameKey)).font(Theme.Fonts.hint).foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Text(verbatim: CacheManager.format(s)).font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary).monospacedDigit()
                        }
                        .frame(maxWidth: 260)
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

struct EditSettings: View {
    @Binding var draft: AppSettings
    var body: some View {
        SettingsRow(tr("settings.stepFrames"), hint: tr("settings.stepFrames.hint")) {
            NumberSetting(value: Binding(get: { Double(draft.stepFrames) }, set: { draft.stepFrames = Int($0) }), range: 2...100,
                          unit: tr("settings.unit.frames"), id: "stepFrames")
        }
        SettingsRow(tr("settings.imageDuration")) {
            NumberSetting(value: $draft.imageDuration, range: 0.1...60, step: 0.1, decimals: 1, unit: tr("settings.unit.seconds"), id: "imageDuration")
        }
        SettingsRow(tr("settings.freezeDuration")) {
            NumberSetting(value: $draft.freezeDuration, range: 0.1...60, step: 0.1, decimals: 1, unit: tr("settings.unit.seconds"), id: "freezeDuration")
        }
        SettingsRow(tr("settings.transitionDuration"), hint: draft.transitionDuration == nil ? tr("settings.transitionDuration.hint") : nil) {
            HStack(spacing: 10) {
                CheckLine(label: tr("settings.transitionDuration.custom"), isOn: Binding(get: { draft.transitionDuration != nil },
                                                                                    set: { draft.transitionDuration = $0 ? 0.5 : nil }), id: "transitionCustom")
                if draft.transitionDuration != nil {
                    NumberSetting(value: Binding(get: { draft.transitionDuration ?? 0.5 }, set: { draft.transitionDuration = $0 }),
                                  range: 0.1...10, step: 0.1, decimals: 1, unit: tr("settings.unit.seconds"), id: "transitionDuration")
                }
            }
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

struct PerformanceSettings: View {
    @Binding var draft: AppSettings
    let sizes: [CacheManager.Category: Int64]
    let editing: Bool
    let clear: (CacheManager.Category?) -> Void
    var cache: URL { MontagePaths.cacheDirectory }
    var body: some View {
        SettingsRow(tr("settings.encode")) {
            CheckLine(label: tr("settings.hwEncode"), isOn: $draft.hardwareEncoding, id: "hwEncode")
            HintText(text: tr("settings.hwDecode.hint"))
        }
        SettingsDivider()
        SettingsRow(tr("player.quality"), hint: tr("settings.previewQuality.hint", MemoryBudget.isLowMemoryMachine ? "720p" : "1080p")) {
            Dropdown(items: PreviewQuality.allCases.map { ($0.rawValue, tr($0.nameKey)) }, selection: draft.previewQuality) { draft.previewQuality = $0 }
                .frame(width: 200)
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
            SwitchButton(isOn: $draft.autoRender, id: "autoRender")
        }
        SettingsDivider()
        SettingsRow(tr("settings.cacheLocation"), hint: tr("settings.cacheLocation.hint")) {
            PathSetting(path: draft.cacheDirectory ?? MontagePaths.defaultCacheDirectory.path,
                        onChoose: { if let p = chooseFolder(tr("settings.cacheLocation"), start: draft.cacheDirectory) { draft.cacheDirectory = p } },
                        onReset: draft.cacheDirectory == nil ? nil : { draft.cacheDirectory = nil }, id: "cacheLocation")
        }
    }
}

struct ExportDefaultsSettings: View {
    @Binding var draft: AppSettings
    var body: some View {
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
