import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MontageCore
import MontageEngine

/// Dimmed backdrop + dialog (hit-testing blocked behind it).
struct ExportModal: View {
    @Bindable var store: EditorStore
    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea().contentShape(Rectangle()).onTapGesture {}
            if let model = store.exports.dialog {
                ExportSheet(store: store, model: model)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08)))
                    .shadow(color: .black.opacity(0.5), radius: 24)
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { SnapshotRegistry.shared.modalFrame = g.frame(in: .global) }
                            .onChange(of: g.frame(in: .global)) { _, f in SnapshotRegistry.shared.modalFrame = f }
                    })
            }
        }
        .onAppear { if store.exports.dialog == nil { store.openExport(scope: store.exports.requestedScope) } }
        .onDisappear { SnapshotRegistry.shared.modalFrame = nil }
    }
}

/// Export dialog (UX.md §7.1, screenshots 110/112/113/114): 720×663 "Export-<name>" window. Left: cover preview with
/// "Edit cover". Right (scrolls): Title, Export to, range, ☑ Video exporting (preset, resolution, bit rate, codec,
/// format, frame rate, colour space…), ☐ Export audio, ☐ Export GIF, ☐ Caption exporting. Footer: "Duration | Size
/// (estimated)", Cancel, Export. Export turns the window into the progress / share view; closing it keeps the export
/// running in the background queue (title-bar indicator).
struct ExportSheet: View {
    @Bindable var store: EditorStore
    @Bindable var model: ExportDialogModel
    @State private var coverPopover = false
    var jobs: [ExportJobItem] { store.exports.shownJobs }

    static let size = CGSize(width: 720, height: 663)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: tr("export.window", model.title)).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 16).frame(height: 36)
            Rectangle().fill(ExportStyle.separator).frame(height: 1)
            if jobs.isEmpty { form } else { ExportProgressView(store: store, jobs: jobs, cover: model.coverPreview, onClose: close) }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(ExportStyle.background)
        .testID("export.dialog")
        .task {
            model.mp3Available = await MP3Encoder.isAvailable()
            await model.refreshCover()
        }
        .onChange(of: model.coverTime) { Task { await model.refreshCover() } }
    }

    func close() { store.closeExportDialog() }

    // MARK: Form

    var form: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                cover
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        general
                        separator
                        videoSection
                        separator
                        audioSection
                        separator
                        gifSection
                        separator
                        captionSection
                    }
                    .padding(.trailing, 14)
                }
                .scrollIndicators(.automatic)
            }
            .padding(.leading, 16).padding(.top, 16).padding(.trailing, 8)
            Spacer(minLength: 0)
            Rectangle().fill(ExportStyle.separator).frame(height: 1)
            footer
        }
    }

    var separator: some View { Rectangle().fill(ExportStyle.separator).frame(height: 1).padding(.vertical, 4) }

    var cover: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let img = model.coverPreview {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .accessibilityLabel(Text(verbatim: tr("ax.exportPreview")))   // SE-017
                } else { Color.black }
            }
            .frame(width: 320, height: 180)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Button { coverPopover = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "pencil.line").font(.system(size: 11))
                    Text(loc: "export.editCover").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white).padding(.horizontal, 7).frame(height: 22)
                .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain).padding(8).testID("export.editCover")
            .popover(isPresented: $coverPopover, arrowEdge: .bottom) { CoverEditor(model: model, store: store) }
        }
        .frame(width: 320, height: 180)
    }

    // MARK: General

    var general: some View {
        VStack(alignment: .leading, spacing: 6) {
            ExportRow(label: tr("export.titleField")) {
                TextField("", text: $model.title).textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(.white)
                    .padding(.horizontal, 8).frame(height: 24).background(ExportStyle.field, in: RoundedRectangle(cornerRadius: 4))
                    .testID("export.title")
            }
            ExportRow(label: tr("export.location")) {
                HStack(spacing: 6) {
                    Text(verbatim: model.folder.path).font(.system(size: 12.5)).foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                        .background(ExportStyle.field, in: RoundedRectangle(cornerRadius: 4))
                    Button { chooseFolder() } label: {
                        Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(.white).frame(width: 26, height: 24)
                            .background(ExportStyle.field, in: RoundedRectangle(cornerRadius: 4))
                    }.buttonStyle(.plain).help(tr("export.choose")).testID("export.folder")
                }
            }
            if model.isAvailable(.inOut) || model.isAvailable(.selectedClips) {
                ExportRow(label: tr("export.scope")) {
                    ExportDropdown(items: ExportScope.allCases.map { s in
                        ExportMenuItem(id: s, title: scopeTitle(s), enabled: model.isAvailable(s))
                    }, selection: model.scope) { model.scope = $0 }
                }
                if model.scope == .selectedClips {
                    HStack(spacing: 8) {
                        ExportCheckbox(isOn: $model.includeAllLayers)
                        Text(loc: "export.includeAll").font(.system(size: 12)).foregroundStyle(ExportStyle.label)
                    }.padding(.leading, ExportStyle.labelWidth + 12)
                }
            }
        }
    }

    func scopeTitle(_ s: ExportScope) -> String {
        switch s {
        case .project: return tr(s.nameKey)
        case .inOut:
            guard let r = model.inOutRange else { return tr(s.nameKey) }
            let rate = model.project.settings.frameRate
            return tr("export.scope.inOutRange", Timecode.string(r.start, rate: rate), Timecode.string(r.end, rate: rate))
        case .selectedClips: return tr("export.scope.selectedCount", model.selectedClipIDs.count)
        }
    }

    func chooseFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.directoryURL = model.folder
        if p.runModal() == .OK, let u = p.url { model.folder = u }
    }

    func expandedBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { model.expanded.contains(key) }, set: { if $0 { model.expanded.insert(key) } else { model.expanded.remove(key) } })
    }

    // MARK: Video

    var videoSection: some View {
        let v = model.remembered.video
        let on = model.remembered.videoEnabled
        let hdr = model.colorSpace.isHDR
        return VStack(alignment: .leading, spacing: 4) {
            ExportSectionHeader(id: "video", title: tr("export.video"), isOn: $model.remembered.videoEnabled, expanded: expandedBinding("video"))
            if model.expanded.contains("video") {
                ExportRow(label: tr("export.preset"), enabled: on) {
                    ExportDropdown(items: [ExportMenuItem<String>(id: "", title: tr("export.preset.custom"))]
                                   + ExportPreset.all.map { ExportMenuItem(id: $0.id, title: tr($0.nameKey)) },
                                   selection: model.remembered.presetID ?? "", enabled: on) { model.applyPreset($0.isEmpty ? nil : $0) }
                }
                ExportRow(label: tr("export.resolution"), enabled: on) {
                    ExportDropdown(items: ExportSettings.Resolution.allCases.map { ExportMenuItem(id: $0, title: $0.label) },
                                   selection: v.resolution, enabled: on) { r in model.editVideo { $0.resolution = r } }
                }
                ExportRow(label: tr("export.bitrate"), enabled: on && !v.codec.isProRes) {
                    ExportDropdown(items: ExportSettings.BitrateMode.allCases.map { ExportMenuItem(id: $0, title: tr($0.nameKey)) },
                                   selection: v.bitrateMode, enabled: on && !v.codec.isProRes) { m in model.editVideo { $0.bitrateMode = m } }
                }
                if v.bitrateMode == .custom && !v.codec.isProRes {
                    ExportRow(label: tr("export.kbps"), enabled: on) {
                        HStack(spacing: 8) {
                            TextField("", value: Binding(get: { Int(model.remembered.video.customBitrateMbps * 1000) },
                                                         set: { k in model.editVideo { $0.customBitrateMbps = min(800, max(0.5, Double(k) / 1000)) } }),
                                      format: .number)
                                .textFieldStyle(.plain).font(Theme.Fonts.numeric).foregroundStyle(.white)
                                .padding(.horizontal, 8).frame(width: 90, height: 22).background(ExportStyle.field, in: RoundedRectangle(cornerRadius: 4))
                            Text(verbatim: "kbps").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                            Spacer()
                            ExportDropdown(items: ExportSettings.RateControl.allCases.map { ExportMenuItem(id: $0, title: tr($0.nameKey)) },
                                           selection: v.rateControl, enabled: on) { rc in model.editVideo { $0.rateControl = rc } }
                                .frame(width: 80)
                        }
                    }
                }
                ExportRow(label: tr("export.codec"), enabled: on) {
                    ExportDropdown(items: ExportSettings.Codec.menuOrder.map { c in
                        ExportMenuItem(id: c, title: tr(c.nameKey), subtitle: c.hintKey.map { tr($0) })
                    }, selection: v.effectiveCodec(for: model.colorSpace), enabled: on) { c in model.editVideo { $0.codec = c } }
                }
                ExportRow(label: tr("export.format"), enabled: on) {
                    ExportDropdown(items: ExportSettings.Container.allCases.map { ExportMenuItem(id: $0, title: $0.rawValue, enabled: !v.codec.isProRes || $0 == .mov) },
                                   selection: v.effectiveContainer, enabled: on) { f in model.editVideo { $0.container = f } }
                }
                ExportRow(label: tr("export.frameRate"), enabled: on) {
                    ExportDropdown(items: ExportSettings.frameRates.map { ExportMenuItem(id: $0, title: tr("export.fps", Self.fpsLabel($0))) },
                                   selection: v.frameRate, enabled: on) { r in model.editVideo { $0.frameRate = r } }
                }
                if v.codec.supportsBitDepthChoice && !hdr && !v.alpha {
                    ExportRow(label: tr("export.bitDepth"), enabled: on) {
                        ExportDropdown(items: ExportSettings.BitDepth.allCases.map { ExportMenuItem(id: $0, title: tr("export.bits", $0.rawValue)) },
                                       selection: v.bitDepth, enabled: on) { d in model.editVideo { $0.bitDepth = d } }
                    }
                }
                ExportRow(label: tr("export.colorSpace"), enabled: false) {
                    Text(verbatim: tr(v.outputColorSpace(for: model.colorSpace).exportLabelKey)).font(.system(size: 12.5))
                        .foregroundStyle(on ? ExportStyle.label : ExportStyle.disabledLabel)
                }
                if hdr {
                    toggleRow(tr("export.hdrToSDR"), detail: tr("export.hdrToSDR.hint"), isOn: Binding(
                        get: { model.remembered.video.toneMapToSDR }, set: { b in model.editVideo { $0.toneMapToSDR = b } }), enabled: on)
                }
                if v.codec.supportsAlpha {
                    toggleRow(tr("export.alpha"), detail: tr("export.alpha.hint"), isOn: Binding(
                        get: { model.remembered.video.alpha }, set: { b in model.editVideo { $0.alpha = b } }), enabled: on)
                }
                if model.hasBurnableCaptions {
                    toggleRow(tr("export.burnCaptions"), detail: nil, isOn: Binding(
                        get: { model.remembered.video.burnCaptions }, set: { b in model.editVideo { $0.burnCaptions = b } }), enabled: on)
                }
                // EX-025: motion blur rendered by frame accumulation (Times 2× / 4× / 6×)
                toggleRow(tr("export.motionBlur"), detail: tr("export.motionBlur.hint"), isOn: Binding(
                    get: { model.remembered.video.motionBlur != .off },
                    set: { b in model.editVideo { $0.motionBlur = b ? .medium : .off } }), enabled: on)
                    .testID("export.motionBlur")
                if v.motionBlur != .off {
                    ExportRow(label: tr("export.motionBlur.strength"), enabled: on) {
                        ExportDropdown(items: [ExportSettings.MotionBlurLevel.low, .medium, .high].map { ExportMenuItem(id: $0, title: tr($0.nameKey)) },
                                       selection: v.motionBlur, enabled: on) { l in model.editVideo { $0.motionBlur = l } }
                    }
                }
                // EX-018: AI ultra HD (on-device super resolution of low-resolution clips before rendering)
                toggleRow(tr("export.aiUltraHD"), detail: tr("export.aiUltraHD.hint"), isOn: Binding(
                    get: { model.remembered.video.aiUltraHD }, set: { b in model.editVideo { $0.aiUltraHD = b } }), enabled: on)
                    .testID("export.aiUltraHD")
            }
        }
    }

    func toggleRow(_ label: String, detail: String?, isOn: Binding<Bool>, enabled: Bool) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: label).font(.system(size: 12.5)).foregroundStyle(enabled ? ExportStyle.label : ExportStyle.disabledLabel)
                if let detail { Text(verbatim: detail).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary) }
            }
            Spacer()
            ExportToggle(isOn: isOn, enabled: enabled, label: label)
        }
        .frame(minHeight: ExportStyle.rowHeight)
    }

    static func fpsLabel(_ r: FrameRate) -> String {
        r.denominator == 1 ? "\(r.numerator)" : String(format: "%.3f", r.fps).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
    }

    // MARK: Audio / GIF / captions

    var audioSection: some View {
        let a = model.remembered.audio
        let on = model.remembered.audioEnabled
        return VStack(alignment: .leading, spacing: 4) {
            ExportSectionHeader(id: "audio", title: tr("export.audio"), isOn: $model.remembered.audioEnabled, expanded: expandedBinding("audio"))
            if model.expanded.contains("audio") {
                ExportRow(label: tr("export.format"), enabled: on) {
                    ExportDropdown(items: AudioOutputSettings.Format.menuOrder.map { f in
                        ExportMenuItem(id: f, title: f.label, subtitle: f == .mp3 && !model.mp3Available ? tr("export.mp3.unavailable") : nil,
                                       enabled: f != .mp3 || model.mp3Available)
                    }, selection: a.format, enabled: on) { model.remembered.audio.format = $0 }
                }
                if a.format.isLossy {
                    ExportRow(label: tr("export.bitrate"), enabled: on) {
                        ExportDropdown(items: AudioOutputSettings.bitrates.map { ExportMenuItem(id: $0, title: tr("export.kbpsValue", $0)) },
                                       selection: a.bitrateKbps, enabled: on) { model.remembered.audio.bitrateKbps = $0 }
                    }
                }
                if a.format == .wav {
                    ExportRow(label: tr("export.audioBits"), enabled: on) {
                        ExportDropdown(items: [16, 24].map { ExportMenuItem(id: $0, title: tr("export.bits", $0)) },
                                       selection: a.bitDepth, enabled: on) { model.remembered.audio.bitDepth = $0 }
                    }
                }
                if a.format == .mp3 {
                    ExportRow(label: tr("export.sampleRate"), enabled: on) {
                        ExportDropdown(items: AudioOutputSettings.sampleRates.map { ExportMenuItem(id: $0, title: tr("export.hz", Double($0) / 1000)) },
                                       selection: a.sampleRate, enabled: on) { model.remembered.audio.sampleRate = $0 }
                    }
                }
                if on && !model.audioFormatUsable {
                    Text(loc: "export.mp3.unavailable").font(Theme.Fonts.hint).foregroundStyle(.orange)
                }
            }
        }
    }

    var gifSection: some View {
        let on = model.remembered.gifEnabled
        return VStack(alignment: .leading, spacing: 4) {
            ExportSectionHeader(id: "gif", title: tr("export.gif"), isOn: $model.remembered.gifEnabled, expanded: expandedBinding("gif"))
            if model.expanded.contains("gif") {
                ExportRow(label: tr("export.resolution"), enabled: on) {
                    ExportDropdown(items: GIFSettings.Resolution.allCases.map { ExportMenuItem(id: $0, title: $0.label) },
                                   selection: model.remembered.gif.resolution, enabled: on) { model.remembered.gif.resolution = $0 }
                }
            }
        }
    }

    var captionSection: some View {
        let available = model.hasCaptions
        let on = model.remembered.captionsEnabled && available
        return VStack(alignment: .leading, spacing: 4) {
            ExportSectionHeader(id: "captions", title: tr("export.captions"), isOn: Binding(get: { on }, set: { model.remembered.captionsEnabled = $0 }),
                                expanded: expandedBinding("captions"), enabled: available)
            if model.expanded.contains("captions") {
                ExportRow(label: tr("export.format"), enabled: on) {
                    ExportDropdown(items: CaptionExport.Format.allCases.map { ExportMenuItem(id: $0, title: $0.label) },
                                   selection: model.remembered.captionFormat, enabled: on) { model.remembered.captionFormat = $0 }
                }
                ExportRow(label: tr("export.encoding"), enabled: on) {
                    Text(verbatim: "Unicode / UTF-8").font(.system(size: 12.5)).foregroundStyle(on ? ExportStyle.label : ExportStyle.disabledLabel)
                }
                if !available { Text(loc: "export.captions.none").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary) }
            }
        }
    }

    // MARK: Footer

    var footer: some View {
        let pre = model.preflight
        return HStack(spacing: 10) {
            Image(systemName: "film").font(.system(size: 14)).foregroundStyle(ExportStyle.label)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: model.footerText).font(.system(size: 12.5)).foregroundStyle(.white).testID("export.estimate")
                if !pre.missingMedia.isEmpty {
                    Text(verbatim: tr("export.error.missingMedia", pre.missingMedia.joined(separator: ", "))).font(Theme.Fonts.hint).foregroundStyle(.red).lineLimit(1)
                } else if !pre.hasEnoughSpace {
                    Text(loc: "export.error.space").font(Theme.Fonts.hint).foregroundStyle(.red)
                }
            }
            Spacer()
            Button(tr("common.cancel")) { close() }
                .buttonStyle(ExportButtonStyle(accent: false)).keyboardShortcut(.cancelAction).testID("export.cancel")
            Button(tr("export.export")) { startExport() }
                .buttonStyle(ExportButtonStyle(accent: true)).keyboardShortcut(.defaultAction)
                .disabled(!model.canExport).testID("export.confirm")
        }
        .padding(.horizontal, 16).frame(height: 60)
    }

    func startExport() { store.confirmExport() }
}

extension ProjectColorSpace {
    /// CapCut read-only label: "Rec. 709 SDR", "Rec. 2020 HLG", "Rec. 2020 PQ".
    var exportLabelKey: String { "export.colorSpace.\(rawValue)" }
}

struct ExportButtonStyle: ButtonStyle {
    let accent: Bool
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
            .frame(minWidth: 72).padding(.horizontal, 12).frame(height: 28)
            .background((accent ? Theme.accent : Theme.buttonSecondary).opacity(configuration.isPressed ? 0.75 : (isEnabled ? 1 : 0.4)),
                        in: RoundedRectangle(cornerRadius: 4))
    }
}

/// "Edit cover": pick the cover frame (slider + live preview, or the playhead) or import an image; optionally prepend
/// it as the first frame of the video (EX-019). The cover is embedded as the file's artwork.
struct CoverEditor: View {
    @Bindable var model: ExportDialogModel
    let store: EditorStore
    @State private var seconds: Double = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc: "export.cover.title").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            Group {
                if let img = model.coverPreview { Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).accessibilityLabel(Text(verbatim: tr("ax.cover", model.title))) } else { Color.black }
            }
            .frame(width: 288, height: 162).background(Color.black).clipShape(RoundedRectangle(cornerRadius: 6))
            Slider(value: $seconds, in: 0...max(0.01, model.project.duration.seconds)) { editing in
                if !editing { model.usesProjectCover = false; model.coverImage = nil; model.coverTime = Time(seconds) }
            }
            .controlSize(.small)
            HStack {
                Button(tr("export.cover.playhead")) {
                    model.usesProjectCover = false; model.coverImage = nil; seconds = store.transport.playhead.seconds; model.coverTime = store.transport.playhead
                }.buttonStyle(SecondaryButtonStyle())
                Button(tr("export.cover.import")) { importImage() }.buttonStyle(SecondaryButtonStyle())
            }
            HStack(spacing: 8) {
                ExportCheckbox(isOn: Binding(get: { model.remembered.video.prependCover }, set: { b in model.editVideo { $0.prependCover = b } }))
                Text(loc: "export.cover.prepend").font(.system(size: 12)).foregroundStyle(ExportStyle.label)
            }
        }
        .padding(14).frame(width: 316)
        .background(Theme.menu)
        .onAppear { seconds = model.coverTime.seconds }
    }

    func importImage() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.image]
        guard p.runModal() == .OK, let u = p.url, let img = NSImage(contentsOf: u), let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return }
        model.usesProjectCover = false; model.coverImage = jpeg
        model.coverPreview = img
    }
}
