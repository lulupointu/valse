import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO
import MontageCore
import MontageEngine
import MontageAI
import Perception

// Adjust ▸ Basic ▸ ☐ Auto adjust · ☐ Color match · ☐ Color correction (UX_AI §4.12, CL-007/008/009, AI-055).
// Ticking runs a short background job (frame statistics → generated LUT look on the clip); unticking removes it.
// Strength is the look's own keyframeable param.

enum ColorLookInspector {
    static func look(_ c: Clip?, _ k: ColorLooks.Kind) -> EffectInstance? { c?.effects.first { ColorLooks.kind(of: $0) == k } }
    static func visual(_ ctx: InspectorContext) -> Bool { ctx.kind != .adjustment && (ctx.asset?.kind == .video || ctx.asset?.kind == .image) }

    @MainActor static let sections: [InspectorSection] = [
        InspectorSection(id: "adjust.auto", tab: "adjust", subTab: "basic", order: 1, titleKey: "look.auto",
                         appliesTo: visual, chrome: { ctx in chrome(ctx, .auto) }) { AnyView(LookStrengthSection(ctx: $0, kind: .auto)) },
        InspectorSection(id: "adjust.colorMatch", tab: "adjust", subTab: "basic", order: 2, titleKey: "look.match",
                         appliesTo: visual, chrome: { ctx in chrome(ctx, .match) }) { AnyView(ColorMatchSection(ctx: $0)) },
        InspectorSection(id: "adjust.colorCorrect", tab: "adjust", subTab: "basic", order: 3, titleKey: "look.correct",
                         appliesTo: visual, chrome: { ctx in chrome(ctx, .correct) }) { AnyView(LookStrengthSection(ctx: $0, kind: .correct)) },
    ]

    @MainActor static func chrome(_ ctx: InspectorContext, _ k: ColorLooks.Kind) -> InspectorSectionChrome {
        let store = ctx.store
        return InspectorSectionChrome(isEnabled: Binding.perceived(get: {
            guard let c = ctx.clip else { return false }
            return look(c, k) != nil || store.ai.lookJobs[ColorLookUI.key(c.id, k)] != nil || (k == .match && ColorLookUI.shared.matchOpen == c.id)
        }, set: { on in
            guard let id = ctx.clip?.id else { return }
            if on {
                if k == .match { ColorLookUI.shared.matchOpen = id } else { store.applyAutoLook(id, kind: k) }
            } else {
                if k == .match { ColorLookUI.shared.matchOpen = nil }
                store.removeLook(id, kind: k)
            }
        }), reset: { if let id = ctx.clip?.id { store.removeLook(id, kind: k) } }, keyframeKeys: look(ctx.clip, k).map { [ParamKey.effect($0.id, "intensity")] })
    }
}

@MainActor @Perceptible final class ColorLookUI {
    static let shared = ColorLookUI()
    /// Clip whose Color match section is open before a look exists.
    var matchOpen: ClipID?
    /// Chosen reference: another clip, or an imported image.
    var referenceClip: ClipID?
    var referenceImage: URL?
    static func key(_ id: ClipID, _ k: ColorLooks.Kind) -> String { "\(id.description).\(k.rawValue)" }
}

struct LookStrengthSection: View {
    let ctx: InspectorContext
    let kind: ColorLooks.Kind
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: Theme.Metrics.rowSpacing) {
                if let id = ctx.clip?.id, let job = ctx.store.ai.lookJobs[ColorLookUI.key(id, kind)] {
                    let p = ctx.store.jobProgress(job) ?? 0
                    JobProgressLine(text: tr(kind == .match ? "look.matching" : "look.applying"), progress: p) { ctx.store.removeLook(id, kind: kind) }
                }
                if let inst = ColorLookInspector.look(ctx.clip, kind) {
                    Bind.row(ctx, tr("fx.param.strength"), key: ParamKey.effect(inst.id, "intensity"),
                             spec: RowSpec(range: 0...100, format: Fmt.percentValue), toUI: { $0 * 100 }, fromUI: { $0 / 100 },
                             gestureName: "cmd.effect")
                }
            }
        }
    }
}

struct ColorMatchSection: View {
    let ctx: InspectorContext
    var body: some View {
        WithPerceptionTracking {
            let st = ColorLookUI.shared
            let others = referenceClips
            VStack(alignment: .leading, spacing: Theme.Metrics.rowSpacing) {
                HintText(text: tr("look.match.hint"))
                InlineRow(label: tr("look.match.source")) {
                    Dropdown(items: [(nil, tr("look.match.select"))] + others.map { (Optional($0.id), $0.title) },
                             selection: st.referenceImage == nil ? st.referenceClip : nil) { st.referenceClip = $0; st.referenceImage = nil }
                }
                HStack {
                    if let u = st.referenceImage { Text(verbatim: u.lastPathComponent).font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary).lineLimit(1) }
                    Spacer()
                    PillButton(title: tr("look.match.import"), symbol: "photo") { importImage() }
                    PillButton(title: tr("look.match.apply"), accent: true, enabled: st.referenceClip != nil || st.referenceImage != nil) { apply() }
                        .testID("look.match.apply")
                }
                LookStrengthSection(ctx: ctx, kind: .match)
            }
        }
    }

    /// Other visual clips (title = name + start time).
    var referenceClips: [(id: ClipID, title: String)] {
        let p = ctx.store.project
        return p.timeline.allClips.compactMap { c -> (id: ClipID, title: String)? in
            guard c.id != ctx.clip?.id, let a = c.mediaID.flatMap(p.asset), a.kind == .video || a.kind == .image else { return nil }
            return (c.id, "\(a.name) · \(String(format: "%d:%02d", Int(c.start.seconds) / 60, Int(c.start.seconds) % 60))")
        }
    }

    func importImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let u = panel.url else { return }
        ColorLookUI.shared.referenceImage = u
        ColorLookUI.shared.referenceClip = nil
        apply()
    }

    func apply() {
        guard let id = ctx.clip?.id else { return }
        let st = ColorLookUI.shared
        if let u = st.referenceImage { ctx.store.applyColorMatch(id, reference: .image(u)) }
        else if let r = st.referenceClip { ctx.store.applyColorMatch(id, reference: .clip(r)) }
    }
}

enum ColorReference: Sendable { case clip(ClipID), image(URL) }

extension EditorStore {
    /// Auto adjust / Color correction: background job → one undo step ("Auto adjust").
    public func applyAutoLook(_ clipID: ClipID, kind: ColorLooks.Kind) {
        let project = self.project
        runLookJob(clipID, kind) { try await ColorLooks.autoAdjust(project: project, clipID: clipID, kind: kind) }
    }

    func applyColorMatch(_ clipID: ClipID, reference: ColorReference) {
        let project = self.project
        let playhead = transport.playhead
        runLookJob(clipID, .match) {
            let px: [SIMD3<Float>]
            switch reference {
            case .image(let u):
                guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
                      let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceThumbnailMaxPixelSize: 320,
                                                                             kCGImageSourceCreateThumbnailFromImageAlways: true] as CFDictionary)
                else { throw AIToolError.noInput }
                px = ColorLooks.pixels(of: img)
            case .clip(let rid):
                guard let r = project.timeline.clip(rid), let a = r.mediaID.flatMap(project.asset) else { throw AIToolError.noInput }
                // the frame under the playhead when it is inside the reference clip, else the clip's middle frame
                let t = playhead >= r.start && playhead < r.end ? playhead : r.start + r.duration / 2.0
                let s = r.sourceTime(at: t)
                px = try await ColorLooks.pixels(a, range: TimeRange(start: s, duration: Time(0.04)), count: 1)
            }
            return try await ColorLooks.match(project: project, clipID: clipID, reference: px)
        }
    }

    func runLookJob(_ clipID: ClipID, _ kind: ColorLooks.Kind, _ work: @escaping @Sendable () async throws -> any EditCommand) {
        let key = ColorLookUI.key(clipID, kind)
        if let j = ai.lookJobs[key] { Task { await JobQueue.shared.cancel(j) } }
        let box = CommandBox()
        Task {
            let id = await JobQueue.shared.enqueue(titleKey: kind == .match ? "look.matching" : "look.applying", priority: 1,
                                                   subject: clipID.description) { progress in
                progress.report(0.2)
                box.command = try await work()
            }
            ai.lookJobs[key] = id
            let st = await JobQueue.shared.wait(id)
            if ai.lookJobs[key] == id { ai.lookJobs[key] = nil }
            switch st {
            case .done:
                if let cmd = box.command, perform(cmd), kind == .match { ColorLookUI.shared.matchOpen = nil }
            case .failed(let e) where kind == .card: showToast(tr(e.contains("notFound") ? "colorCard.notFound" : "look.failed"), error: true)
            case .failed: showToast(tr("look.failed"), error: true)
            default: break
            }
        }
    }

    public func removeLook(_ clipID: ClipID, kind: ColorLooks.Kind) {
        let key = ColorLookUI.key(clipID, kind)
        if let j = ai.lookJobs[key] { ai.lookJobs[key] = nil; Task { await JobQueue.shared.cancel(j) } }
        guard ColorLookInspector.look(project.timeline.clip(clipID), kind) != nil else { return }
        perform(Edit(kind == .card ? "cmd.colorCard" : kind == .match ? "cmd.colorMatch" : (kind == .auto ? "cmd.autoAdjust" : "cmd.colorCorrect")) { p in
            ColorLooks.remove(kind, from: clipID, in: &p)
        })
    }
}
