import SwiftUI
import AppKit
import MontageCore
import MontageEngine

/// Export dialog (FEATURES §24.15): one compact sheet with sensible defaults (1080p / 30 fps / Recommended), a size
/// estimate, background export with progress, and a finish screen (Open folder / Done).
struct ExportSheet: View {
    @Bindable var store: EditorStore
    @State private var settings = ExportSettings()
    @State private var name = ""
    @State private var folder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(loc: "export.title").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            switch store.exportState {
            case .idle, .failed: form
            case .running(let p): progress(p)
            case .done(let url): done(url)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Theme.panel)
        .onAppear {
            name = store.projectName
            settings.frameRate = store.project.settings.frameRate
            settings.resolution = ExportSettings.Resolution.allCases.last { Double($0.rawValue) <= min(store.project.settings.canvasSize.width, store.project.settings.canvasSize.height) } ?? .p1080
        }
    }

    var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            row(tr("export.name")) { TextField("", text: $name).textFieldStyle(.roundedBorder) }
            row(tr("export.location")) {
                HStack {
                    Text(verbatim: folder.path).font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button(tr("export.choose")) {
                        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                        if p.runModal() == .OK, let u = p.url { folder = u }
                    }.buttonStyle(SecondaryButtonStyle())
                }
            }
            Rectangle().fill(Theme.separator).frame(height: 1)
            row(tr("export.resolution")) {
                Picker("", selection: $settings.resolution) {
                    ForEach(ExportSettings.Resolution.allCases, id: \.self) { Text(verbatim: $0.label).tag($0) }
                }.labelsHidden()
            }
            row(tr("export.bitrate")) {
                Picker("", selection: $settings.bitrateMode) {
                    ForEach(ExportSettings.BitrateMode.allCases, id: \.self) { Text(loc: $0.nameKey).tag($0) }
                }.labelsHidden().disabled(settings.codec.isProRes)
            }
            if settings.bitrateMode == .custom && !settings.codec.isProRes {
                row(tr("export.mbps")) {
                    HStack { Slider(value: $settings.customBitrateMbps, in: 1...150); Text(verbatim: "\(Int(settings.customBitrateMbps)) Mbps").font(Theme.Fonts.numeric).frame(width: 64) }
                }
            }
            row(tr("export.codec")) {
                Picker("", selection: $settings.codec) {
                    ForEach(ExportSettings.Codec.allCases, id: \.self) { Text(loc: $0.nameKey).tag($0) }
                }.labelsHidden()
            }
            row(tr("export.frameRate")) {
                Picker("", selection: $settings.frameRate) {
                    ForEach(FrameRate.common, id: \.self) { Text(verbatim: "\($0.description) fps").tag($0) }
                }.labelsHidden()
            }
            row(tr("export.audio")) { Toggle("", isOn: $settings.includeAudio).labelsHidden().toggleStyle(.switch).tint(Theme.accent) }
            if case .failed(let msg) = store.exportState {
                Text(verbatim: msg).font(Theme.Fonts.hint).foregroundStyle(.red)
            }
            HStack {
                let bytes = settings.estimatedBytes(duration: store.project.duration, canvas: store.project.settings.canvasSize)
                Text(loc: "export.estimate", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
                Spacer()
                Button(tr("common.cancel")) { store.isExportSheetPresented = false; store.exportState = .idle }
                    .buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button(tr("export.export")) {
                    let url = folder.appendingPathComponent(name.isEmpty ? "Montage" : name).appendingPathExtension(settings.codec.fileExtension)
                    store.startExport(settings: settings, to: url)
                }
                .buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
    }

    func progress(_ p: Double) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc: "export.exporting", Int(p * 100)).font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary)
            ProgressView(value: p).tint(Theme.accent)
            HStack { Spacer(); Button(tr("common.cancel")) { store.cancelExport() }.buttonStyle(SecondaryButtonStyle()) }
        }
    }

    func done(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(tr("export.done"), systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accent)
            Text(verbatim: url.lastPathComponent).font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary)
            HStack {
                Spacer()
                Button(tr("export.openFolder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(SecondaryButtonStyle())
                Button(tr("common.done")) { store.isExportSheetPresented = false; store.exportState = .idle }.buttonStyle(AccentButtonStyle())
            }
        }
    }

    func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack {
            Text(verbatim: label).font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary).frame(width: 110, alignment: .leading)
            content()
        }
    }
}
