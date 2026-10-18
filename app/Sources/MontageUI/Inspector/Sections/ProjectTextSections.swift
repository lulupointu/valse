import SwiftUI
import AppKit
import MontageCore
import MontageEffects
import MontageEngine

// MARK: - Details (no selection)

/// No selection → "Details" (UX.md §5 / [10]): project info rows and a [Modify] footer opening Project settings.
struct DetailsSection: View {
    @Bindable var store: EditorStore
    var body: some View {
        let s = store.projectSettings   // observation slice: not re-rendered by clip edits
        VStack(alignment: .leading, spacing: 4) {
            DetailRow(label: tr("details.name"), value: store.projectName)
            DetailRow(label: tr("details.saved"), value: store.packageURL?.path ?? tr("details.notSaved"))
            DetailRow(label: tr("details.importMaterial"), value: tr("details.importMaterial.keep"))
            DetailRow(label: tr("details.proxy"), value: tr("details.proxy.\(ProxyManager.shared.policy.rawValue)"))
            Rectangle().fill(Theme.separator).frame(height: 1).padding(.vertical, 8)
            DetailRow(label: tr("details.ratio"), value: ProjectSettingsSheet.ratioTitle(s.aspectPreset))
            DetailRow(label: tr("details.resolution"), value: "\(Int(s.canvasSize.width))×\(Int(s.canvasSize.height))")
            DetailRow(label: tr("details.frameRate"), value: String(format: "%.2ffps", s.frameRate.fps))
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: label + " :").font(.system(size: 12)).foregroundStyle(IStyle.caption).frame(width: 128, alignment: .leading)
            Text(verbatim: value).font(.system(size: 12)).foregroundStyle(Theme.textPrimary).lineLimit(2).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 30)
    }
}

struct ModifyProjectButton: View {
    @Bindable var store: EditorStore
    @State private var presented = false
    var body: some View {
        PillButton(title: tr("details.modify")) { presented = true }
            .sheet(isPresented: $presented) { ProjectSettingsSheet(store: store, isPresented: $presented) }
    }
}

/// Project settings dialog (UX.md §2.4, [108]): Name, Save to, Ratio, Resolution, Frame rate; Cancel / Save.
struct ProjectSettingsSheet: View {
    @Bindable var store: EditorStore
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var ratio = "16:9"
    @State private var short = 1080
    @State private var fps = FrameRate.fps30
    @State private var tab = "details"

    static let ratios = ["original", "16:9", "4:3", "2.35:1", "2:1", "1.85:1", "9:16", "3:4", "1:1", "4:5", "21:9"]
    static let resolutions = [480, 720, 1080, 1440, 2160]

    static func ratioTitle(_ id: String) -> String { id == "original" ? tr("player.ratio.original") : id }

    static func size(ratio: String, short: Int, original: Size2?) -> Size2 {
        var a: Double
        if ratio == "original", let o = original, o.width > 0, o.height > 0 { a = o.width / o.height }
        else {
            let parts = ratio.split(separator: ":").compactMap { Double($0) }
            a = parts.count == 2 && parts[1] > 0 ? parts[0] / parts[1] : 16.0 / 9
        }
        let s = Double(short)
        func even(_ v: Double) -> Double { (v / 2).rounded() * 2 }
        return a >= 1 ? Size2(even(s * a), s) : Size2(s, even(s / a))
    }

    var original: Size2? {
        store.project.timeline.mainTrack?.clips.first?.mediaID.flatMap { store.project.asset($0)?.pixelSize }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(loc: "settings.project.title").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .padding(16)
            Rectangle().fill(Theme.separator).frame(height: 1)
            VStack(alignment: .leading, spacing: 14) {
                SubTabBar(items: [("details", tr("settings.project.details")), ("performance", tr("settings.project.performance"))],
                          selection: tab) { tab = $0 }
                VStack(alignment: .leading, spacing: 12) {
                    if tab == "details" {
                        Text(loc: "settings.project.details").font(.system(size: 12, weight: .medium)).foregroundStyle(IStyle.caption)
                        row(tr("details.name")) {
                            TextField("", text: $name).textFieldStyle(.plain).font(.system(size: 12))
                                .padding(.horizontal, 8).frame(height: 28)
                                .background(IStyle.dropdown, in: RoundedRectangle(cornerRadius: 4))
                        }
                        row(tr("settings.project.saveTo")) {
                            Text(verbatim: store.packageURL?.path ?? MontagePaths.draftsDirectory.path)
                                .font(.system(size: 12)).foregroundStyle(IStyle.caption).lineLimit(2)
                        }
                        Rectangle().fill(Theme.separator).frame(height: 1)
                        Text(loc: "settings.project.timeline").font(.system(size: 12, weight: .medium)).foregroundStyle(IStyle.caption)
                        row(tr("details.ratio")) {
                            Dropdown(items: Self.ratios.map { ($0, Self.ratioTitle($0)) }, selection: ratio) { ratio = $0 }
                        }
                        row(tr("details.resolution")) {
                            Dropdown(items: Self.resolutions.map { r in
                                let sz = Self.size(ratio: ratio, short: r, original: original)
                                return (r, "\(r)p (\(Int(sz.width))×\(Int(sz.height)))")
                            }, selection: short) { short = $0 }
                        }
                        row(tr("details.frameRate")) {
                            Dropdown(items: FrameRate.common.map { ($0, String(format: "%.2f fps", $0.fps)) }, selection: fps) { fps = $0 }
                        }
                    } else {
                        row(tr("details.proxy")) {
                            Text(verbatim: tr("details.proxy.\(ProxyManager.shared.policy.rawValue)")).font(.system(size: 12)).foregroundStyle(.white)
                        }
                        HintText(text: tr("settings.project.proxyHint"))
                    }
                }
                .padding(16)
                .background(Theme.inset.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 12) {
                    Button { isPresented = false } label: {
                        Text(loc: "common.cancel").font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity, minHeight: 32)
                            .background(Theme.buttonSecondary, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                    Button { save() } label: {
                        Text(loc: "common.save").font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity, minHeight: 32)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain).keyboardShortcut(.defaultAction)
                }
                .foregroundStyle(.white)
            }
            .padding(16)
        }
        .frame(width: 512)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
        .onAppear {
            let s = store.project.settings
            name = store.projectName
            ratio = Self.ratios.contains(s.aspectPreset) ? s.aspectPreset : "16:9"
            short = Self.resolutions.min { abs(Double($0) - min(s.canvasSize.width, s.canvasSize.height)) < abs(Double($1) - min(s.canvasSize.width, s.canvasSize.height)) } ?? 1080
            fps = s.frameRate
        }
    }

    func row<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(alignment: .center, spacing: 0) {
            Text(verbatim: label).font(.system(size: 12)).foregroundStyle(IStyle.label).frame(width: 150, alignment: .leading)
            c()
        }
        .frame(minHeight: 30)
    }

    func save() {
        let size = Self.size(ratio: ratio, short: short, original: original)
        let n = name, r = ratio, f = fps
        store.perform(Edit("cmd.projectSettings") { p in
            p.name = n
            p.settings.canvasSize = size
            p.settings.aspectPreset = r
            p.settings.frameRate = f
        })
        isPresented = false
    }
}

// MARK: - Multi-selection

/// Several clips selected → "Properties": Scale and Position applied relatively to every selected visual clip (§5.9).
struct MultiTransformSection: View {
    let ctx: InspectorContext
    @State private var scaleUI = 100.0
    var body: some View {
        let store = ctx.store
        let canvas = store.project.settings.canvasSize
        let scale = SliderScale.linear(1...500)
        VStack(alignment: .leading, spacing: 6) {
            SliderRowView(label: tr("prop.scale"), unit: scale.toUnit(scaleUI), display: Fmt.percentValue(scaleUI),
                          parse: NumberParse.number,
                          onBegin: { store.beginGesture("cmd.transform") },
                          onChange: { u in scaleUI = scale.fromUnit(u).rounded(); applyScale(scaleUI) },
                          onEnd: { store.endGesture() },
                          commit: { v in scaleUI = min(max(v, 1), 1000); applyScale(scaleUI) },
                          step: { d in scaleUI = min(max(scaleUI + Double(d), 1), 1000); applyScale(scaleUI) })
            InlineRow(label: tr("prop.position")) {
                HStack(spacing: 14) {
                    NumericField(display: "0", prefix: "X", parse: NumberParse.number, commit: { nudge(dx: $0 / canvas.width, dy: 0) },
                                 step: { nudge(dx: Double($0) / canvas.width, dy: 0) })
                    NumericField(display: "0", prefix: "Y", parse: NumberParse.number, commit: { nudge(dx: 0, dy: -$0 / canvas.height) },
                                 step: { nudge(dx: 0, dy: -Double($0) / canvas.height) })
                }
            }
            HintText(text: tr("inspector.multi.hint"))
        }
    }

    /// Relative scale: every clip's scale is multiplied by scaleUI / 100 from where the gesture started.
    func applyScale(_ pct: Double) {
        let k = pct / 100
        let ids = visualIDs()
        let store = ctx.store
        if store.session.isInGesture {
            store.updateGesture { p in for id in ids { if var c = p.timeline.clip(id) { c.transform.scale = c.transform.scale * k; p.timeline[clip: id] = c } } }
        } else {
            store.perform(Edit("cmd.transform") { p in for id in ids { if var c = p.timeline.clip(id) { c.transform.scale = c.transform.scale * k; p.timeline[clip: id] = c } } })
            scaleUI = 100
        }
    }

    func nudge(dx: Double, dy: Double) {
        let ids = visualIDs()
        ctx.store.perform(Edit("cmd.transform") { p in
            for id in ids { if var c = p.timeline.clip(id) { c.transform.position = c.transform.position + Vec2(dx, dy); p.timeline[clip: id] = c } }
        })
    }

    func visualIDs() -> [ClipID] {
        ctx.store.selectedClips.filter { ctx.store.trackKind(of: $0).map { $0.isVisual } ?? false }.map(\.id)
    }
}

// Text clip sections live in MontageUI/Text/TextInspector.swift (text engine, W7).
