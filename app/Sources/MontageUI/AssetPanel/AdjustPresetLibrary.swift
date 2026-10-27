import SwiftUI
import Perception
import MontageCore

// Adjustment asset tab ▸ "My presets" (UX.md §3.10 `Yours`, CL-013): the grades saved from the Adjust footer
// ("Save as preset", AdjustPresets.shared) as cards. ⊕ / double-click adds an adjustment layer carrying the grade at
// the playhead; right-click ▸ Apply to selected clip replaces the selected clips' grade; right-click ▸ Delete.

extension AdjustTools {
    /// An adjustment layer (3 s at `start`) carrying a fresh copy of `preset`'s grade and mask.
    nonisolated static func presetLayerClip(_ preset: AdjustPreset, start: Time) -> Clip {
        var c = Clip(content: .adjustment, start: start, duration: Time(3))
        replaceGrading(&c, with: preset.effects, mask: preset.mask)
        return c
    }

    /// Selected clips a preset can grade: video / image clips and adjustment layers on unlocked tracks.
    nonisolated static func presetTargets(_ p: Project, selection: Set<ClipID>) -> [ClipID] {
        p.timeline.tracks.filter { $0.kind.isVisual && !$0.isLocked }.flatMap(\.clips).filter { c in
            guard selection.contains(c.id) else { return false }
            if c.content == .adjustment { return true }
            guard let m = c.mediaID, let a = p.asset(m) else { return false }
            return a.kind != .audio
        }.map(\.id)
    }
}

extension EditorStore {
    /// "My presets" ⊕: adds an adjustment layer with the preset's grade at the playhead and selects it (Adjust tab).
    @discardableResult
    func addAdjustmentLayer(preset: AdjustPreset, at time: Time? = nil) -> ClipID? {
        exitPreview()
        let c = AdjustTools.presetLayerClip(preset, start: time ?? transport.playhead)
        guard perform(InsertClip(c, target: .automatic, nameKey: "cmd.adjustmentLayer")) else { return nil }
        selection = [c.id]
        inspectorTab = "adjust"
        return c.id
    }

    /// "My presets" ▸ Apply to selected clip: the preset replaces the grade of every gradable selected clip (one undo
    /// step); nothing gradable selected → a hint toast.
    @discardableResult
    func applyAdjustPresetToSelection(_ preset: AdjustPreset) -> Bool {
        let targets = AdjustTools.presetTargets(project, selection: selection)
        guard !targets.isEmpty else { showToast(tr("adjust.preset.noTarget")); return false }
        return perform(Edit("cmd.adjust.preset") { p in
            for id in targets {
                if var c = p.timeline.clip(id) { AdjustTools.replaceGrading(&c, with: preset.effects, mask: preset.mask); p.timeline[clip: id] = c }
            }
        })
    }
}

/// Grid of "My presets" cards, or an empty state pointing at the Adjust footer.
struct AdjustPresetGrid: View {
    let store: EditorStore
    @Binding var pickedID: String?
    @State private var presets = AdjustPresets.shared

    var body: some View {
        WithPerceptionTracking {
            if presets.all.isEmpty {
                EmptyState(symbol: "slider.horizontal.3", title: tr("adjust.preset.empty")).testID("asset.presets.empty")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 78, maximum: 96), spacing: 12)], spacing: 14) {
                        ForEach(Array(presets.all.enumerated()), id: \.element.id) { i, p in
                            WithPerceptionTracking {
                                AdjustPresetCard(preset: p, index: i, isPicked: pickedID == p.id.uuidString,
                                                 select: { pickedID = p.id.uuidString },
                                                 add: { pickedID = p.id.uuidString; store.addAdjustmentLayer(preset: p) },
                                                 apply: { store.applyAdjustPresetToSelection(p) },
                                                 delete: { presets.remove(p.id) })
                                    .testID("asset.preset.\(i)")
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 12)
                }
            }
        }
    }
}

/// One saved grade: slider glyph card + name; hover / selected shows ⊕.
struct AdjustPresetCard: View {
    let preset: AdjustPreset
    let index: Int
    let isPicked: Bool
    let select: () -> Void
    let add: () -> Void
    let apply: () -> Void
    let delete: () -> Void
    @State private var hover = false

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 5) {
                ZStack(alignment: .bottomTrailing) {
                    Button {
                        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { add() } else { select() }
                    } label: {
                        RoundedRectangle(cornerRadius: 6).fill(Theme.segmentSelected)
                            .overlay {
                                Image(systemName: "slider.horizontal.3").font(.system(size: 24)).foregroundStyle(Theme.textPrimary.opacity(0.85))
                            }
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(isPicked ? Theme.accent : (hover ? Theme.hoverRing : .clear),
                                                                               lineWidth: isPicked ? 2 : 1.5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if hover || isPicked {
                        RoundBadge(symbol: "plus", tint: .white, fill: Theme.accent, help: tr("asset.addToTrack"), action: add)
                            .padding(4)
                            .testID("asset.preset.\(index).add")
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                Text(verbatim: preset.name).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .contextMenu {
                Button(tr("asset.addToTrack"), action: add)
                Button(tr("adjust.preset.applyToSelected"), action: apply)
                Divider()
                Button(tr("adjust.preset.delete"), action: delete)
            }
            .help(tr("adjust.preset.cardHelp"))
        }
    }
}
