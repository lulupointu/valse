import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ValseCore
import ValseEffects
import ValseEngine
import Perception

// Cover editor (TL-045 + TX-036, UX.md §6.3): opened by the main-track "Cover" button. Pick a frame of the video
// (filmstrip + slider) or import a local image, add text layers in the cover styles (drag them on the preview), save.
// The cover is stored in `Project.cover` (one undo step) and feeds the export artwork / prepended cover frame.

/// Renders a `ProjectCover` through the regular compositor (off the main actor).
enum CoverRenderer {
    static func image(project: Project, cover: ProjectCover, asset: MediaAsset?, shortSide: Int) async throws -> CGImage {
        let (p, t) = cover.compositionProject(base: project, image: asset)
        return try await StillFrameExporter.image(project: p, at: t, shortSide: shortSide)
    }

    /// Probes the imported cover image (nil when it's gone or unreadable).
    static func asset(for cover: ProjectCover) async -> MediaAsset? {
        guard let path = cover.imagePath, FileManager.default.fileExists(atPath: path) else { return nil }
        return try? await MediaProbe.probe(URL(fileURLWithPath: path))
    }

    /// Full render as JPEG (export artwork / prepended frame).
    static func jpeg(project: Project, cover: ProjectCover) async -> Data? {
        let asset = await asset(for: cover)
        if cover.imagePath != nil && asset == nil && cover.texts.isEmpty { return nil }
        let short = min(project.settings.canvasSize.width, project.settings.canvasSize.height)
        guard let img = try? await image(project: project, cover: cover, asset: asset, shortSide: Int(min(short, 1080))) else { return nil }
        return try? StillFrameExporter.encode(img, format: .jpeg, quality: 0.9)
    }
}

@MainActor @Perceptible
final class CoverEditorModel {
    enum Source: String { case frame, image }

    var cover: ProjectCover
    var source: Source
    var selectedText: Int?
    var preview: CGImage?
    var filmstrip: [CGImage?] = []
    var imageAsset: MediaAsset?
    var isRendering = false
    let project: Project

    @PerceptionIgnored private var renderTask: Task<Void, Never>?
    static let filmstripCount = 10

    init(project: Project) {
        self.project = project
        let c = project.cover ?? ProjectCover(time: .zero)
        cover = c
        source = c.imagePath != nil ? .image : .frame
    }

    var duration: Time { project.duration }
    var canvasAspect: CGFloat {
        let s = project.settings.canvasSize
        return s.height > 0 ? CGFloat(s.width / s.height) : 16 / 9
    }

    func start() {
        Task {
            if cover.imagePath != nil { imageAsset = await CoverRenderer.asset(for: cover) }
            render(debounce: false)
            await loadFilmstrip()
        }
    }

    /// Re-renders the preview (debounced: drags and typing coalesce).
    func render(debounce: Bool = true) {
        renderTask?.cancel()
        let p = project, c = effectiveCover, a = source == .image ? imageAsset : nil
        renderTask = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(90)) }
            guard !Task.isCancelled else { return }
            self?.isRendering = true
            let img = try? await Task.detached(priority: .userInitiated) {
                try await CoverRenderer.image(project: p, cover: c, asset: a, shortSide: 540)
            }.value
            guard !Task.isCancelled, let self else { return }
            if let img { self.preview = img }
            self.isRendering = false
        }
    }

    /// The cover as it will be saved (an image source without a readable image falls back to the frame).
    var effectiveCover: ProjectCover {
        var c = cover
        if source == .frame || imageAsset == nil { c.imagePath = nil }
        return c
    }

    func loadFilmstrip() async {
        let p = project, d = duration.seconds, n = Self.filmstripCount
        guard d > 0 else { return }
        filmstrip = Array(repeating: nil, count: n)
        for i in 0..<n {
            let t = Time(d * (Double(i) + 0.5) / Double(n))
            let img = try? await Task.detached(priority: .utility) { try await StillFrameExporter.image(project: p, at: t, shortSide: 72) }.value
            if i < filmstrip.count { filmstrip[i] = img }
        }
    }

    func setTime(_ t: Time) {
        cover.time = min(max(t, .zero), duration)
        source = .frame
        render()
    }

    func importImage(_ url: URL) {
        Task {
            var c = cover
            c.imagePath = url.path
            guard let a = await CoverRenderer.asset(for: c), a.kind == .image || a.hasVideo else { return }
            cover.imagePath = url.path
            imageAsset = a
            source = .image
            render(debounce: false)
        }
    }

    // MARK: Text

    func addText() {
        var t = TextContent(string: tr("cover.text.default"))
        t.fontSize = 0.11
        t.bold = true
        Registries.textStyles["valse.text.outline"]?.restyle(&t)
        var c = Clip(content: .text(t), start: .zero, duration: Time(1))
        c.transform.position = Vec2(0, 0.28 - 0.1 * Double(cover.texts.count % 4))
        cover.texts.append(c)
        selectedText = cover.texts.count - 1
        render(debounce: false)
    }

    func deleteSelectedText() {
        guard let i = selectedText, cover.texts.indices.contains(i) else { return }
        cover.texts.remove(at: i)
        selectedText = cover.texts.isEmpty ? nil : min(i, cover.texts.count - 1)
        render(debounce: false)
    }

    func textContent(_ i: Int) -> TextContent? {
        guard cover.texts.indices.contains(i), case .text(let t) = cover.texts[i].content else { return nil }
        return t
    }

    func updateText(_ i: Int, _ body: (inout TextContent) -> Void) {
        guard var t = textContent(i) else { return }
        body(&t)
        cover.texts[i].content = .text(t)
        render()
    }

    func moveText(_ i: Int, to position: Vec2) {
        guard cover.texts.indices.contains(i) else { return }
        cover.texts[i].transform.position = Vec2(min(max(position.x, -0.5), 0.5), min(max(position.y, -0.5), 0.5))
        render()
    }

    /// Text box of layer `i` in canvas fractions (centre offset, size), for the selection outline and hit-testing.
    func textBox(_ i: Int) -> (center: Vec2, size: CGSize)? {
        guard let t = textContent(i) else { return nil }
        let cs = project.settings.canvasSize
        let s = TextMetrics.size(of: t, canvasHeight: cs.height, canvasWidth: cs.width)
        let k = cover.texts[i].transform.scale.x
        return (cover.texts[i].transform.position, CGSize(width: s.width * k / max(cs.width, 1), height: s.height * k / max(cs.height, 1)))
    }

    func textIndex(at p: Vec2) -> Int? {
        cover.texts.indices.reversed().first { i in
            guard let b = textBox(i) else { return false }
            return abs(p.x - b.center.x) <= b.size.width / 2 + 0.01 && abs(p.y - b.center.y) <= b.size.height / 2 + 0.01
        }
    }
}

extension EditorStore {
    /// Opens the cover editor (main-track "Cover" button).
    public func openCoverEditor() {
        let m = CoverEditorModel(project: project)
        timelineUI.coverEditor = m
        m.start()
    }

    public func closeCoverEditor() { timelineUI.coverEditor = nil }

    /// Sets (nil = resets) the project cover as one undo step.
    public func setCover(_ cover: ProjectCover?) {
        if edit("cmd.cover", { $0.cover = cover }) { showToast(tr(cover == nil ? "toast.coverReset" : "toast.coverSaved")) }
    }
}

/// In-window modal like Export: dimmed editor, centred dialog.
struct CoverEditorModal: View {
    let store: EditorStore
    @Perception.Bindable var model: CoverEditorModel

    var body: some View {
        WithPerceptionTracking {
            ZStack {
                Color.black.opacity(0.45).ignoresSafeArea().onTapGesture {}
                CoverEditorView(store: store, model: model)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .modalHoverShield()   // FB-07
                    .background(GeometryReader { g in
                        WithPerceptionTracking {
                            // offscreen snapshots redraw the modal above the Metal views (see SnapshotRegistry.modalFrame)
                            Color.clear
                                .onAppear { SnapshotRegistry.shared.modalFrame = g.frame(in: .global) }
                                .onValueChange(of: g.frame(in: .global)) { _, f in SnapshotRegistry.shared.modalFrame = f }
                        }
                    })
                    .valseFloatingCard(radius: 10)
            }
            .onDisappear { SnapshotRegistry.shared.modalFrame = nil }
            .onExitCommand { store.closeCoverEditor() }

        }
    }
}

struct CoverEditorView: View {
    let store: EditorStore
    @Perception.Bindable var model: CoverEditorModel
    @State private var dragOrigin: Vec2?

    static let size = CGSize(width: 860, height: 600)
    static let previewSize = CGSize(width: 560, height: 315)

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                HStack {
                    Text(loc: "cover.title").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Button { store.closeCoverEditor() } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    }.buttonStyle(.plain).testID("cover.close")
                }
                .padding(.horizontal, 16).frame(height: 40)
                Rectangle().fill(Theme.separator).frame(height: 1)
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        SegmentedTabs([("frame", tr("cover.source.frame")), ("image", tr("cover.source.image"))],
                                      selection: Binding.perceived(get: { model.source.rawValue }, set: { v in
                                          if v == "image" && model.imageAsset == nil { pickImage() } else {
                                              model.source = CoverEditorModel.Source(rawValue: v) ?? .frame; model.render(debounce: false)
                                          }
                                      }))
                            .frame(width: 260).testID("cover.source")
                        preview
                        if model.source == .frame { framePicker } else { imageRow }
                    }
                    .padding(16)
                    Rectangle().fill(Theme.separator).frame(width: 1)
                    textPanel.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .scrollsWhenTight()   // BUG-OVERSIZED-SHEETS: footer stays pinned in a small window
                Rectangle().fill(Theme.separator).frame(height: 1)
                footer
            }
            .fittedFrame(Self.size)
            .background(Theme.panel)
            .testID("cover.dialog")
        }
    }

    // MARK: Preview (drag a text to move it; click one to select it)

    var preview: some View {
        let box = Self.fitted(aspect: model.canvasAspect, in: Self.previewSize)
        return ZStack(alignment: .topLeading) {
            Color.black
            if let img = model.preview {
                Image(decorative: img, scale: 1).resizable().interpolation(.high).frame(width: box.width, height: box.height)
            }
            if let i = model.selectedText, let b = model.textBox(i) {
                let w = max(b.size.width * box.width, 12), h = max(b.size.height * box.height, 12)
                Rectangle().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Theme.textPrimary)
                    .frame(width: w + 8, height: h + 8)
                    .position(x: (0.5 + b.center.x) * box.width, y: (0.5 + b.center.y) * box.height)
                    .allowsHitTesting(false)
            }
            if model.isRendering && model.preview == nil {
                ProgressView().controlSize(.small).frame(width: box.width, height: box.height)
            }
        }
        .frame(width: box.width, height: box.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            let start = Vec2(Double(v.startLocation.x / box.width) - 0.5, Double(v.startLocation.y / box.height) - 0.5)
            if dragOrigin == nil {
                model.selectedText = model.textIndex(at: start)
                dragOrigin = model.selectedText.map { model.cover.texts[$0].transform.position } ?? start
            }
            guard let i = model.selectedText, let o = dragOrigin else { return }
            model.moveText(i, to: Vec2(o.x + Double(v.translation.width / box.width), o.y + Double(v.translation.height / box.height)))
        }.onEnded { _ in dragOrigin = nil })
        .frame(width: Self.previewSize.width, height: Self.previewSize.height)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
        .testID("cover.preview")
    }

    static func fitted(aspect: CGFloat, in s: CGSize) -> CGSize {
        s.width / s.height > aspect ? CGSize(width: s.height * aspect, height: s.height) : CGSize(width: s.width, height: s.width / aspect)
    }

    var framePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(loc: "cover.frame.hint").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
            GeometryReader { geo in
                WithPerceptionTracking {
                    let n = max(model.filmstrip.count, 1)
                    let d = max(model.duration.seconds, 0.001)
                    ZStack(alignment: .leading) {
                        HStack(spacing: 0) {
                            ForEach(0..<n, id: \.self) { i in
                                WithPerceptionTracking {
                                    ZStack {
                                        Theme.menu
                                        if i < model.filmstrip.count, let img = model.filmstrip[i] {
                                            Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fill)
                                        }
                                    }
                                    .frame(width: geo.size.width / CGFloat(n), height: 48).clipped()
                                }
                            }
                        }
                        let x = CGFloat(model.cover.time.seconds / d) * geo.size.width
                        RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.accent, lineWidth: 2)
                            .frame(width: 30, height: 52)
                            .offset(x: min(max(x - 15, 0), geo.size.width - 30), y: 0)
                            .allowsHitTesting(false)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        model.setTime(Time(Double(min(max(v.location.x / geo.size.width, 0), 1)) * d))
                    })
                }
            }
            .frame(width: Self.previewSize.width, height: 52)
            .testID("cover.filmstrip")
            HStack(spacing: 8) {
                Text(verbatim: Timecode.string(model.cover.time, rate: model.project.settings.frameRate))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.accent)
                Spacer()
                Button(tr("cover.usePlayhead")) { model.setTime(store.transport.playhead) }
                    .buttonStyle(SecondaryButtonStyle()).testID("cover.playhead")
            }
            .frame(width: Self.previewSize.width)
        }
    }

    var imageRow: some View {
        HStack(spacing: 8) {
            Text(verbatim: model.cover.imagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? tr("cover.image.none"))
                .font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button(tr("cover.import")) { pickImage() }.buttonStyle(SecondaryButtonStyle()).testID("cover.import")
        }
        .frame(width: Self.previewSize.width)
    }

    func pickImage() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        guard p.runModal() == .OK, let u = p.url else { return }
        model.importImage(u)
    }

    // MARK: Text panel

    var textPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(loc: "cover.text").font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Button { model.addText() } label: {
                        Label(tr("cover.addText"), systemImage: "plus").font(.system(size: 12))
                    }.buttonStyle(SecondaryButtonStyle()).testID("cover.addText")
                }
                if model.cover.texts.isEmpty {
                    Text(loc: "cover.text.hint").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    layerChips
                    if let i = model.selectedText, let t = model.textContent(i) { textControls(i, t) }
                }
            }
            .padding(16)
        }
    }

    var layerChips: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(model.cover.texts.indices, id: \.self) { i in
                WithPerceptionTracking {
                    let sel = model.selectedText == i
                    Text(verbatim: model.textContent(i)?.string.replacingOccurrences(of: "\n", with: " ") ?? "")
                        .font(.system(size: 11)).lineLimit(1).frame(maxWidth: 110)
                        .padding(.horizontal, 8).frame(height: 22)
                        .foregroundStyle(sel ? Theme.accent : Theme.textPrimary)
                        .background(Theme.control, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(sel ? Theme.accent : .clear, lineWidth: 1))
                        .onTapGesture { model.selectedText = i }
                        .testID("cover.textLayer.\(i)")
                }
            }
        }
    }

    @ViewBuilder
    func textControls(_ i: Int, _ t: TextContent) -> some View {
        TextField("", text: Binding.perceived(get: { model.textContent(i)?.string ?? "" }, set: { s in model.updateText(i) { $0.string = s } }),
                  axis: .vertical)
            .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
            .lineLimit(2...4)
            .padding(8).background(Theme.inset, in: RoundedRectangle(cornerRadius: 4))
            .testID("cover.textField")
        VStack(alignment: .leading, spacing: 4) {
            Text(loc: "cover.fontSize").font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary)
            HStack {
                Slider(value: Binding.perceived(get: { (model.textContent(i)?.fontSize ?? 0.1) * 250 },
                                      set: { v in model.updateText(i) { $0.fontSize = v / 250 } }), in: 5...80)
                    .controlSize(.small).valseSliderTint().testID("cover.fontSizeSlider")
                Text(verbatim: "\(Int(((model.textContent(i)?.fontSize ?? 0.1) * 250).rounded()))")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textPrimary).frame(width: 28)
                ColorSwatchButton(color: t.color) { c in model.updateText(i) { $0.color = c } }
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            Text(loc: "cover.position").font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 6) {
                ForEach([("top", -0.32), ("middle", 0.0), ("bottom", 0.32)], id: \.0) { item in
                    WithPerceptionTracking {
                        Button(tr("cover.position.\(item.0)")) {
                            model.moveText(i, to: Vec2(0, item.1))
                        }.buttonStyle(SecondaryButtonStyle()).testID("cover.position.\(item.0)")
                    }
                }
            }
        }
        // Cover text templates: the text style presets rendered by the text engine.
        VStack(alignment: .leading, spacing: 6) {
            Text(loc: "cover.styles").font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(52), spacing: 6), count: 4), alignment: .leading, spacing: 6) {
                ForEach(Array(Registries.textStyles(.preset).prefix(16)), id: \.id) { d in
                    WithPerceptionTracking {
                        let sel = t.styleID == d.id
                        TextPreviewImage(key: "style:\(d.id)", content: TextPreviewImage.style(d, sample: "Aa"), padding: 6)
                            .frame(width: 52, height: 52)
                            .background(Theme.control, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(sel ? Theme.accent : .clear, lineWidth: 2))
                            .contentShape(Rectangle())
                            .onTapGesture { model.updateText(i) { d.restyle(&$0) } }
                            .help(d.displayName)
                            .testID("cover.style.\(d.id)")
                    }
                }
            }
        }
        Button(role: .destructive) { model.deleteSelectedText() } label: {
            Label(tr("cover.deleteText"), systemImage: "trash").font(.system(size: 12))
        }.buttonStyle(SecondaryButtonStyle()).testID("cover.deleteText")
    }

    // MARK: Footer

    var footer: some View {
        HStack(spacing: 10) {
            Button(tr("cover.reset")) { store.setCover(nil); store.closeCoverEditor() }
                .buttonStyle(SecondaryButtonStyle()).disabled(store.project.cover == nil).testID("cover.reset")
            Spacer()
            Button(tr("cover.cancel")) { store.closeCoverEditor() }.buttonStyle(SecondaryButtonStyle()).testID("cover.cancel")
            Button(tr("cover.save")) {
                store.setCover(model.effectiveCover)
                store.closeCoverEditor()
            }.buttonStyle(AccentButtonStyle()).testID("cover.save")
        }
        .padding(.horizontal, 16).frame(height: 52)
    }
}
