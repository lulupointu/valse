import SwiftUI
import AppKit
import MontageCore
import MontageEngine
import MontageAI

// Video ▸ Basic ▸ ☐ Relight / Ajout de lumière (UX_AI §4.10, AI-024 / CL-020). Ticking applies the Facial preset and
// starts the depth pass in the background ("Applying relight... %1%" on the clip and in the section; untick or ⌘Z
// cancels). Lights render immediately (flat) and gain relief when the depth matte lands. Every control after that is
// real time (shader uniforms, no job). Lights can be dragged on the player ("Adjust on canvas").
enum RelightInspector {
    @MainActor static let sections: [InspectorSection] = [
        InspectorSection(id: "video.relight", tab: "video", subTab: "basic", order: 50, titleKey: "relight.title",
                         appliesTo: { $0.isMediaVideo || $0.asset?.kind == .image }, chrome: { ctx in
            InspectorSectionChrome(isEnabled: Binding(get: {
                ctx.clip?.relight != nil
            }, set: { on in
                guard let id = ctx.clip?.id else { return }
                ctx.store.setRelight(id, on: on)
            }))
        }) { AnyView(RelightSection(ctx: $0)) },
    ]
}

@MainActor @Observable final class RelightUIState {
    static let shared = RelightUIState()
    /// Index of the light being edited.
    var selectedLight = 0
    /// Depth / person-matte passes (clip → job).
    var jobs: [ClipID: JobID] = [:]
    var tool: RelightLightTool?
}

struct RelightSection: View {
    let ctx: InspectorContext

    var body: some View {
        let st = RelightUIState.shared
        let _ = ModelManager.shared.states   // re-render when the depth model download finishes (`hasModel` is a disk check)
        let r = ctx.clip?.relight ?? RelightSettings.preset(.facial)
        let sel = min(st.selectedLight, max(r.lights.count - 1, 0))
        VStack(alignment: .leading, spacing: 6) {
            Color.clear.frame(maxWidth: .infinity).frame(height: 1).testID("relight.top")   // UI tests: header is just above
            if let id = ctx.clip?.id, let job = st.jobs[id] {
                let p = ctx.store.jobProgress(job) ?? 0
                JobProgressLine(text: tr("relight.applying", JobInfo.percent(p)), progress: p) { ctx.store.setRelight(id, on: false) }
                    .testID("relight.progress")
            }
            if !RelightDepth.hasModel {
                HintText(text: tr("relight.betterDepth")).testID("relight.needsModel")
                ModelStateControls(spec: ModelCatalog.depthAnything)
            }
            // presets
            HStack(spacing: 4) {
                ForEach(RelightSettings.Preset.allCases, id: \.self) { p in
                    let on = r.preset == p
                    Button { applyPreset(p) } label: {
                        Text(loc: p.nameKey).font(.system(size: 11, weight: on ? .semibold : .regular)).lineLimit(1)
                            .foregroundStyle(on ? Theme.accent : Theme.textPrimary)
                            .padding(.horizontal, 6).frame(maxWidth: .infinity).frame(height: 26)
                            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on ? Theme.accent : Color.clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .testID("relight.preset.\(p.rawValue)")
                }
            }
            InlineRow(label: tr("relight.target")) {
                Dropdown(items: RelightSettings.Target.allCases.map { ($0, tr($0.nameKey)) }, selection: r.target) { v in
                    edit("cmd.relight") { $0.target = v }
                    if let id = ctx.clip?.id { ctx.store.ensureRelightPass(id) }
                }
            }
            row("relight.ambient", get: { $0.ambientDarkening }, set: { $0.ambientDarkening = $1 })
            row("relight.relief", get: { $0.relief }, set: { $0.relief = $1 })
            // lights list
            HStack(spacing: 6) {
                Text(loc: "relight.lights").font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.textPrimary)
                Spacer()
                ForEach(r.lights.indices, id: \.self) { i in
                    Button { st.selectedLight = i } label: {
                        Text(verbatim: tr("relight.light", i + 1)).font(.system(size: 11))
                            .foregroundStyle(i == sel ? Theme.accent : Theme.textSecondary)
                            .padding(.horizontal, 6).frame(height: 22)
                            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain).testID("relight.light.\(i)")
                }
                SmallIconButton(symbol: "plus", help: tr("relight.addLight"), enabled: r.lights.count < RelightSettings.maxLights) {
                    edit("cmd.relight") { s in
                        var l = s.lights.last ?? RelightLight()
                        l.x = 1 - l.x
                        s.lights.append(l)
                    }
                    st.selectedLight = r.lights.count
                }.testID("relight.addLight")
                SmallIconButton(symbol: "trash", help: tr("relight.removeLight"), enabled: r.lights.count > 1) {
                    edit("cmd.relight") { s in if s.lights.indices.contains(sel), s.lights.count > 1 { s.lights.remove(at: sel) } }
                    st.selectedLight = max(0, sel - 1)
                }.testID("relight.removeLight")
            }
            .padding(.top, 4)
            if r.lights.indices.contains(sel) {
                let l = r.lights[sel]
                InlineRow(label: tr("relight.type")) {
                    Dropdown(items: RelightLight.Kind.allCases.map { ($0, tr($0.nameKey)) }, selection: l.kind) { v in
                        light(sel) { $0.kind = v }
                    }
                }
                InlineRow(label: tr("relight.color")) {
                    HStack {
                        ColorSwatchButton(color: l.color) { c in light(sel) { $0.color = c } }
                        Spacer()
                        let active = st.tool != nil && ctx.store.playerUI.canvasTool === st.tool
                        PillButton(title: tr(active ? "relight.canvasDone" : "relight.canvas"), symbol: "hand.point.up.left",
                                   accent: active) { toggleTool() }
                            .testID("relight.canvas")
                    }
                }
                lightRow(sel, "relight.brightness", \.brightness)
                lightRow(sel, "relight.intensity", \.intensity)
                if l.kind == .point { lightRow(sel, "relight.radius", \.radius) }
                lightRow(sel, "relight.distance", \.distance)
                lightRow(sel, "relight.highlights", \.highlights)
                lightRow(sel, "relight.positionX", \.x)
                lightRow(sel, "relight.positionY", \.y)
                GroupCaption(title: tr("relight.animation"))
                lightRow(sel, "relight.moving", \.movingSpeed)
                lightRow(sel, "relight.blinking", \.blinkingSpeed)
                lightRow(sel, "relight.colorChanging", \.colorChanging)
            }
            HintText(text: tr("relight.hint"))
        }
        .onDisappear { if let t = st.tool, ctx.store.playerUI.canvasTool === t { ctx.store.playerUI.canvasTool = nil; st.tool = nil } }
    }

    func edit(_ name: String, _ body: @escaping (inout RelightSettings) -> Void) {
        guard let id = ctx.clip?.id else { return }
        Bind.apply(ctx.store, id, name) { c in if var r = c.relight { body(&r); c.relight = r } }
    }

    func light(_ i: Int, _ body: @escaping (inout RelightLight) -> Void) {
        edit("cmd.relight") { s in
            guard s.lights.indices.contains(i) else { return }
            body(&s.lights[i])
            s.preset = .custom
        }
    }

    func applyPreset(_ p: RelightSettings.Preset) {
        guard let id = ctx.clip?.id else { return }
        let target = ctx.clip?.relight?.target
        Bind.apply(ctx.store, id, "cmd.relight") { c in
            var s = RelightSettings.preset(p)
            if p == .custom, let old = c.relight { s = old; s.preset = .custom }
            if p == .custom, let target { s.target = target }
            c.relight = s
        }
        RelightUIState.shared.selectedLight = 0
        ctx.store.ensureRelightPass(id)
    }

    func row(_ key: String, get: @escaping (RelightSettings) -> Double, set: @escaping (inout RelightSettings, Double) -> Void) -> some View {
        ClipParamRow(ctx: ctx, label: tr(key), spec: RowSpec(range: 0...100, format: Fmt.percentValue),
                     get: { c, _ in (c.relight.map(get) ?? 0) * 100 },
                     set: { c, v, _ in if var r = c.relight { set(&r, v / 100); c.relight = r } },
                     keyframeKeys: nil, gestureName: "cmd.relight", testID: key.replacingOccurrences(of: "relight.", with: "relight.slider."))
    }

    func lightRow(_ i: Int, _ key: String, _ kp: WritableKeyPath<RelightLight, Double>) -> some View {
        ClipParamRow(ctx: ctx, label: tr(key), spec: RowSpec(range: 0...100, format: Fmt.percentValue),
                     get: { c, _ in c.relight.flatMap { $0.lights.indices.contains(i) ? $0.lights[i][keyPath: kp] : nil }.map { $0 * 100 } ?? 0 },
                     set: { c, v, _ in
                         guard var r = c.relight, r.lights.indices.contains(i) else { return }
                         r.lights[i][keyPath: kp] = v / 100
                         r.preset = .custom
                         c.relight = r
                     },
                     keyframeKeys: nil, gestureName: "cmd.relight", testID: key.replacingOccurrences(of: "relight.", with: "relight.slider."))
    }

    func toggleTool() {
        let st = RelightUIState.shared
        if let t = st.tool, ctx.store.playerUI.canvasTool === t {
            ctx.store.playerUI.canvasTool = nil; st.tool = nil
        } else if let id = ctx.clip?.id {
            let t = RelightLightTool(clipID: id, store: ctx.store)
            st.tool = t
            ctx.store.playerUI.canvasTool = t
        }
    }
}

/// Drag the lights of the relit clip on the player (handles = light positions in the layer's 0…1 space).
@MainActor public final class RelightLightTool: CanvasTool {
    public let clipID: ClipID
    public private(set) var revision = 0
    @ObservationIgnored weak var store: EditorStore?
    private var dragging: Int?

    init(clipID: ClipID, store: EditorStore) { self.clipID = clipID; self.store = store }

    var geometry: LayerGeometry? {
        guard let store else { return nil }
        return CanvasLayers.at(store.transport.playhead, project: store.project).first { $0.clipID == clipID }?.geometry
    }

    func canvasPoint(_ l: RelightLight, _ g: LayerGeometry) -> Vec2 {
        let x = (l.x - 0.5) * 2 * g.halfSize.x, y = (l.y - 0.5) * 2 * g.halfSize.y
        let c = cos(g.rotation), s = sin(g.rotation)
        return Vec2(g.center.x + x * c - y * s, g.center.y + x * s + y * c)
    }

    func layerPoint(_ p: Vec2, _ g: LayerGeometry) -> Vec2 {
        let d = p - g.center
        let c = cos(-g.rotation), s = sin(-g.rotation)
        let x = d.x * c - d.y * s, y = d.x * s + d.y * c
        return Vec2(min(max(x / max(2 * g.halfSize.x, 1) + 0.5, -0.2), 1.2), min(max(y / max(2 * g.halfSize.y, 1) + 0.5, -0.2), 1.2))
    }

    var lights: [RelightLight] { store?.project.timeline.clip(clipID)?.relight?.lights ?? [] }

    public func mouseDown(at p: Vec2) {
        guard let store, let g = geometry else { return }
        let ls = lights
        guard let i = ls.indices.min(by: { (canvasPoint(ls[$0], g) - p).length < (canvasPoint(ls[$1], g) - p).length }) else { return }
        dragging = i
        RelightUIState.shared.selectedLight = i
        store.beginGesture("cmd.relight")
        mouseDragged(at: p)
    }

    public func mouseDragged(at p: Vec2) {
        guard let store, let i = dragging, let g = geometry else { return }
        let q = layerPoint(p, g)
        Bind.apply(store, clipID, "cmd.relight") { c in
            guard var r = c.relight, r.lights.indices.contains(i) else { return }
            r.lights[i].x = q.x; r.lights[i].y = q.y
            r.preset = .custom
            c.relight = r
        }
        revision += 1
    }

    public func mouseUp(at p: Vec2) {
        guard dragging != nil else { return }
        dragging = nil
        store?.endGesture()
        revision += 1
    }

    public func draw(in ctx: CGContext, toView: (Vec2) -> CGPoint, scale: Double) {
        guard let g = geometry else { return }
        let sel = RelightUIState.shared.selectedLight
        for (i, l) in lights.enumerated() {
            let c = toView(canvasPoint(l, g))
            let r: CGFloat = i == sel ? 11 : 8
            ctx.setFillColor(CGColor(red: l.color.r, green: l.color.g, blue: l.color.b, alpha: 0.9))
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ctx.setStrokeColor(i == sel ? CGColor(red: 0.34, green: 0.75, blue: 0.8, alpha: 1) : CGColor(gray: 1, alpha: 0.9))
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            // rays
            for k in 0..<8 {
                let a = Double(k) * .pi / 4
                ctx.move(to: CGPoint(x: c.x + cos(a) * (r + 3), y: c.y + sin(a) * (r + 3)))
                ctx.addLine(to: CGPoint(x: c.x + cos(a) * (r + 7), y: c.y + sin(a) * (r + 7)))
            }
            ctx.strokePath()
        }
    }
}

extension EditorStore {
    /// Ticks / unticks Relight on a clip (one undo step) and starts the depth pass when it isn't cached yet.
    public func setRelight(_ clipID: ClipID, on: Bool) {
        let st = RelightUIState.shared
        if !on {
            if let j = st.jobs[clipID] { st.jobs[clipID] = nil; Task { await JobQueue.shared.cancel(j) } }
            if let t = st.tool, playerUI.canvasTool === t { playerUI.canvasTool = nil; st.tool = nil }
            guard project.timeline.clip(clipID)?.relight != nil else { return }
            perform(UpdateClip(clipID, nameKey: "cmd.relight") { $0.relight = nil })
            return
        }
        guard project.timeline.clip(clipID)?.relight == nil else { return }
        st.selectedLight = 0
        perform(UpdateClip(clipID, nameKey: "cmd.relight") { $0.relight = RelightSettings.preset(.facial) })
        ensureRelightPass(clipID)
    }

    /// Runs the missing depth / person-matte pass of a relit clip in the background (progress on the clip).
    public func ensureRelightPass(_ clipID: ClipID) {
        let st = RelightUIState.shared
        guard st.jobs[clipID] == nil, let clip = project.timeline.clip(clipID), let settings = clip.relight,
              let asset = clip.mediaID.flatMap(project.asset), !RelightDepth.isReady(asset, settings) else { return }
        Task {
            let id = await JobQueue.shared.enqueue(titleKey: "relight.job", priority: 0, subject: clipID.description) { progress in
                try await RelightJob.run(asset, settings: settings) { progress.report($0) }
            }
            st.jobs[clipID] = id
            let state = await JobQueue.shared.wait(id)
            if st.jobs[clipID] == id { st.jobs[clipID] = nil }
            switch state {
            case .done:
                MatteStore.shared.didWriteMatte(media: asset, kind: RelightOps.depthKind)
                engine.forceRebuild()
                if project.timeline.clip(clipID)?.relight != nil { showToast(tr("relight.done")) }
            case .failed:
                showToast(tr("relight.failed"), error: true)
            case .cancelled:
                showToast(tr("relight.cancelled"))
            default: break
            }
        }
    }

    /// Unticked / undone relights cancel their pass (called from `aiProjectDidChange`).
    func relightProjectDidChange() {
        let st = RelightUIState.shared
        for (clipID, job) in st.jobs where project.timeline.clip(clipID)?.relight == nil {
            st.jobs[clipID] = nil
            Task { await JobQueue.shared.cancel(job) }
        }
    }
}
