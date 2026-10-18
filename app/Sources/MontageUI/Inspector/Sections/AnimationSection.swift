import SwiftUI
import MontageCore
import MontageEffects

/// Animation ▸ In · Out · Combo (Loop for text/stickers): search, 62 pt tiles that play the animation on hover, None
/// first; clicking applies and previews once in the player; then a Duration slider (UX.md §5.1 Animation, [31]).
/// Content comes from `Registries.animations` (W5).
struct AnimationPickerSection: View {
    let ctx: InspectorContext
    let phase: AnimationPhaseKind

    var target: AnimationTargets {
        switch ctx.kind {
        case .text: return .text
        case .sticker: return .sticker
        default: return .video
        }
    }

    func current(_ c: Clip?) -> AnimationInstance? {
        switch phase {
        case .in: return c?.animations.inAnim
        case .out: return c?.animations.outAnim
        case .combo: return c?.animations.combo
        }
    }

    var body: some View {
        let ui = InspectorUIState.shared
        let cur = current(ctx.clip)
        let query = ui.animationSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let items = Registries.animations(phase, for: target).filter { query.isEmpty || tr($0.nameKey).lowercased().contains(query) }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(IStyle.caption)
                TextField(tr("inspector.animation.search"), text: Binding(get: { ui.animationSearch }, set: { ui.animationSearch = $0 }))
                    .textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(IStyle.field, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.08)))
            TileGrid {
                if query.isEmpty {
                    Tile(title: tr("anim.none"), selected: cur == nil) { apply(nil) } content: {
                        Image(systemName: "nosign").font(.system(size: 26, weight: .light)).foregroundStyle(Color(white: 0.75))
                    }
                }
                ForEach(items) { d in
                    AnimationTile(descriptor: d, selected: cur?.typeID == d.id) { apply(d) }
                }
            }
            if items.isEmpty && !query.isEmpty { HintText(text: tr("inspector.animation.noResults")) }
            if cur != nil, let clip = ctx.clip {
                let other: Double = {
                    switch self.phase {
                    case .in: return clip.animations.outAnim?.duration.seconds ?? 0
                    case .out: return clip.animations.inAnim?.duration.seconds ?? 0
                    case .combo: return 0
                    }
                }()
                let maxD = max(0.1, clip.duration.seconds - other)
                let ph = self.phase
                ClipParamRow(ctx: ctx, label: tr("inspector.duration"), spec: RowSpec(range: 0.1...maxD, step: 0.1, format: Fmt.seconds),
                             get: { c, _ in current(c)?.duration.seconds ?? 0.5 },
                             set: { c, v, _ in
                                 switch ph {
                                 case .in: c.animations.inAnim?.duration = Time(v)
                                 case .out: c.animations.outAnim?.duration = Time(v)
                                 case .combo: c.animations.combo?.duration = Time(v)
                                 }
                             }, gestureName: "cmd.animation")
            }
        }
    }

    func apply(_ d: AnimationDescriptor?) {
        guard let clip = ctx.clip else { return }
        let phase = self.phase
        // Video combos span the whole clip (CapCut default); sticker/text loops repeat with the preset's period.
        let wholeClip = phase == .combo && target == .video
        ctx.store.perform(UpdateClip(clip.id, nameKey: "cmd.animation") { c in
            let inst = d.map { AnimationInstance(typeID: $0.id, duration: wholeClip ? c.duration
                                                    : phase == .combo ? min($0.defaultDuration, c.duration)
                                                    : min($0.defaultDuration, c.duration * 0.5)) }
            switch phase {
            case .in: c.animations.inAnim = inst; if inst != nil { c.animations.combo = nil }
            case .out: c.animations.outAnim = inst; if inst != nil { c.animations.combo = nil }
            case .combo: c.animations.combo = inst; if inst != nil { c.animations.inAnim = nil; c.animations.outAnim = nil }
            }
        })
        if let d { preview(clip, d) }
    }

    /// Plays the animated part of the clip once in the player (CapCut previews right after applying).
    func preview(_ clip: Clip, _ d: AnimationDescriptor) {
        let store = ctx.store
        let dur = phase == .combo && target == .video ? clip.duration
            : min(d.defaultDuration, phase == .combo ? clip.duration : clip.duration * 0.5)
        let start = phase == .out ? clip.end - dur : clip.start
        store.seek(to: start)
        if !store.transport.isPlaying { store.togglePlay() }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(dur.seconds, 0.3) + 0.05))
            if store.transport.isPlaying { store.togglePlay() }
        }
    }
}

/// Tile that animates its glyph with the descriptor's own `apply` while hovered (a cheap, faithful preview).
struct AnimationTile: View {
    let descriptor: AnimationDescriptor
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    @State private var start = Date()

    var body: some View {
        Tile(title: tr(descriptor.nameKey), selected: selected, action: action) {
          if descriptor.glyph != nil {
            // per-glyph text animation (text engine, W7)
            GlyphAnimationPreview(descriptor: descriptor, playing: hover, start: start)
          } else {
            SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !hover)) { tl in
                let state = state(at: tl.date)
                ZStack {
                    LinearGradient(colors: [Color(hex: 0x2C5364), Color(hex: 0x203A43)], startPoint: .top, endPoint: .bottom)
                    RoundedRectangle(cornerRadius: 4).fill(Color(hex: 0x57BECB).opacity(0.85))
                        .frame(width: 30, height: 22)
                        .overlay(Image(systemName: descriptor.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white))
                        .mask(alignment: .topLeading) {
                            GeometryReader { g in
                                let r = state.reveal
                                Rectangle().frame(width: g.size.width * max(0, 1 - r.left - r.right),
                                                  height: g.size.height * max(0, 1 - r.top - r.bottom))
                                    .offset(x: g.size.width * r.left, y: g.size.height * r.top)
                            }
                        }
                        .scaleEffect(x: state.transform.scale.x, y: state.transform.scale.y)
                        .rotationEffect(.degrees(state.transform.rotation))
                        .offset(x: state.transform.position.x * 62, y: state.transform.position.y * 62)
                        .opacity(state.opacity)
                        .blur(radius: state.blur * 62)
                }
            }
          }
        }
        .onHover { h in hover = h; if h { start = Date() } }
    }

    /// Hover loops the animation (with a short hold at the end); idle shows the clip's resting state.
    func state(at date: Date) -> AnimatedLayerState {
        var s = AnimatedLayerState(transform: Transform(), opacity: 1)
        guard hover else { return s }
        let d = max(descriptor.defaultDuration.seconds, 0.3)
        let cycle = d + 0.4
        let t = date.timeIntervalSince(start).truncatingRemainder(dividingBy: cycle)
        let p = min(t / d, 1)
        descriptor.apply(descriptor.phase == .combo ? (t / d).truncatingRemainder(dividingBy: 1) : p, &s)
        return s
    }
}
