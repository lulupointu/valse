import SwiftUI
import MontageCore
import MontageEngine

/// "Remove filler words" bar of `TranscriptWorkspace` (C4): the one-click action with its scope ("Everywhere" /
/// "In the 2 selected clips"), the kinds and minimum pause (options), and while a review is open what was found.
struct FillerBar: View {
    let store: EditorStore
    var body: some View {
        let ai = store.ai
        let f = ai.fillers
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if f.reviewing {
                    let n = f.candidates.count
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: tr("fillers.found", n)).font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.textPrimary)
                        Text(verbatim: tr(f.style == .inline ? "fillers.inlineHint" : "fillers.reviewHint"))
                            .font(Theme.Fonts.hint).foregroundStyle(IStyle.caption).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Button { store.removeFillerWords() } label: {
                        HStack(spacing: 6) {
                            if ai.fillers.pendingRemove { ProgressView().controlSize(.small).scaleEffect(0.7) }
                            else { Image(systemName: "wand.and.stars").font(.system(size: 12, weight: .semibold)) }
                            Text(loc: "transcript.removeFillers").font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundStyle(.white).padding(.horizontal, 12).frame(height: 28)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(store.transcriptStatus == .noMedia || ai.fillers.pendingRemove)
                    .help(tr(FillerRemovalStyle.current.hintKey))
                    .testID("fillers.remove")
                    Text(verbatim: scopeText).font(Theme.Fonts.hint).foregroundStyle(IStyle.caption).lineLimit(1)
                        .testID("fillers.scope")
                }
                Spacer(minLength: 4)
                SmallIconButton(symbol: "slider.horizontal.3", help: tr("fillers.options"), active: f.showOptions) { f.showOptions.toggle() }
                    .testID("fillers.options")
            }
            if f.showOptions { options }
        }
        .padding(10)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
    }

    var scopeText: String {
        if let s = store.fillerScope { return tr("fillers.scope.selected", s.count) }
        return tr("fillers.scope.all")
    }

    @ViewBuilder var options: some View {
        let ai = store.ai
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                check("pause", on: ai.cleanupPauses) { ai.cleanupPauses.toggle() }
                ForEach([FillerWords.Kind.hesitation, .filler, .repetition], id: \.self) { k in
                    check(k.rawValue, on: ai.cleanupKinds.contains(k)) {
                        if ai.cleanupKinds.contains(k) { ai.cleanupKinds.remove(k) } else { ai.cleanupKinds.insert(k) }
                    }
                }
            }
            HStack(spacing: 6) {
                Text(loc: "transcript.minPause").font(Theme.Fonts.row).foregroundStyle(IStyle.label)
                StepperButton { d in
                    ai.minPause = min(5, max(0.2, ((ai.minPause + Double(d) * 0.1) * 10).rounded() / 10))
                    store.refreshFillerReview()
                }
                Text(verbatim: Fmt.num(ai.minPause, 1) + " s").font(Theme.Fonts.numeric).foregroundStyle(Theme.textPrimary)
                    .testID("fillers.minPause")
            }
        }
    }

    func check(_ kind: String, on: Bool, toggle: @escaping () -> Void) -> some View {
        Button { toggle(); store.refreshFillerReview() } label: {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3).fill(on ? Theme.accent : Theme.stepper)
                    if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white) }
                }
                .frame(width: 16, height: 16)
                Text(loc: "transcript.kind.\(kind)").font(Theme.Fonts.row).foregroundStyle(IStyle.label)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .testID("fillers.kind.\(kind)")
    }
}

/// Style B: one row per filler / pause with a checkbox (checked = removed), its context and time; a click on the
/// row plays from there.
struct FillerChecklist: View {
    let store: EditorStore
    var body: some View {
        let ai = store.ai
        let f = ai.fillers
        let words = TranscriptEditing.placedWords(transcripts: ai.transcripts, timeline: store.project.timeline)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(f.candidates.enumerated()), id: \.element.id) { i, c in
                    row(i, c, words)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .testID("fillers.list")
    }

    func row(_ i: Int, _ c: FillerCleanup.Candidate, _ words: [TranscriptEditing.PlacedWord]) -> some View {
        let on = store.ai.fillers.dropped.contains(c.id)
        return HStack(spacing: 8) {
            Button { store.toggleFiller(c.id) } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 3).fill(on ? Theme.accent : Theme.stepper)
                    if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white) }
                }
                .frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .testID("fillers.check.\(i)")
            FillerKindBadge(kind: c.kind)
            context(c, words).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text(verbatim: Fmt.num(c.seconds, 1) + " s").font(.system(size: 11).monospacedDigit()).foregroundStyle(IStyle.caption)
            Text(verbatim: CaptionRow.stamp(c.range.start)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 8).frame(height: 30)
        .background(on ? IStyle.field : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { store.seek(to: c.range.start) }
        .opacity(on ? 1 : 0.6)
        .testID("fillers.row.\(i)")
    }

    /// "… je pense **euh** que …" / "… nouvelles. ⏸ Si on …"
    func context(_ c: FillerCleanup.Candidate, _ words: [TranscriptEditing.PlacedWord]) -> Text {
        func w(_ k: Int) -> String? { k >= 0 && k < words.count && !words[k].isDeleted ? words[k].word.text : nil }
        let grey = Theme.textSecondary
        if c.kind == .pause {
            let before = w(c.anchor - 1).map { "… \($0) " } ?? ""
            let after = w(c.anchor).map { " \($0) …" } ?? ""
            let label = tr("fillers.pause.\(c.edge?.rawValue ?? "middle")")
            return Text(verbatim: before).foregroundColor(grey) + Text(verbatim: "⏸ " + label).foregroundColor(Theme.textPrimary).bold()
                + Text(verbatim: after).foregroundColor(grey)
        }
        let before = w(c.anchor - 1).map { "… \($0) " } ?? ""
        let after = w(c.anchor + 1).map { " \($0) …" } ?? ""
        return Text(verbatim: before).foregroundColor(grey) + Text(verbatim: c.text).foregroundColor(Theme.textPrimary).bold()
            + Text(verbatim: after).foregroundColor(grey)
    }
}

struct FillerKindBadge: View {
    let kind: FillerCleanup.Kind
    var body: some View {
        Text(loc: "fillers.badge.\(kind.rawValue)")
            .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.black.opacity(0.8))
            .padding(.horizontal, 5).frame(height: 15)
            .background(Self.color(kind), in: RoundedRectangle(cornerRadius: 3))
    }
    static func color(_ k: FillerCleanup.Kind) -> Color {
        switch k {
        case .pause: return Color(hex: 0x9AA3AD)
        case .hesitation: return IStyle.warning
        case .filler: return Color(hex: 0xF08A5D)
        case .repetition: return Color(hex: 0xB59CF0)
        }
    }
}

/// Style C: a filler word in the transcript. Dropped = red, struck through; kept = outlined. Click toggles.
struct FillerWordChip: View {
    let text: String
    let dropped: Bool
    let kind: FillerCleanup.Kind
    let toggle: () -> Void
    var body: some View {
        Button(action: toggle) {
            Text(verbatim: text)
                .font(.system(size: 13, weight: .medium))
                .strikethrough(dropped, color: .white.opacity(0.85))
                .foregroundStyle(dropped ? Color.white : FillerKindBadge.color(kind))
                .padding(.horizontal, 3).padding(.vertical, 1)
                .background(dropped ? Color(hex: 0xC24040).opacity(0.85) : .clear, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(dropped ? .clear : FillerKindBadge.color(kind).opacity(0.8), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tr(dropped ? "fillers.clickToKeep" : "fillers.clickToRemove"))
    }
}

/// Style C: a pause chip in the transcript (same keep / drop toggle).
struct FillerPauseChip: View {
    let seconds: Double
    let dropped: Bool
    let toggle: () -> Void
    var body: some View {
        Button(action: toggle) {
            Text(verbatim: String(format: "%.2fs", seconds)).font(.system(size: 10, weight: .semibold).monospacedDigit())
                .strikethrough(dropped, color: .white)
                .foregroundStyle(dropped ? .white : Theme.textSecondary)
                .padding(.horizontal, 6).frame(height: 17)
                .background(dropped ? Color(hex: 0xC24040).opacity(0.85) : Theme.buttonSecondary, in: Capsule())
                .overlay(Capsule().strokeBorder(dropped ? .clear : Color(hex: 0x9AA3AD), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tr(dropped ? "fillers.clickToKeep" : "fillers.clickToRemove"))
    }
}

/// Review footer: "Keep all / Remove all", what will go (count + seconds), Cancel, Remove N / Apply.
struct FillerReviewFooter: View {
    let store: EditorStore
    var body: some View {
        let f = store.ai.fillers
        let chosen = f.candidates.filter { f.dropped.contains($0.id) }
        let seconds = FillerCleanup.totalDuration(chosen).seconds
        HStack(spacing: 8) {
            Button(tr(chosen.count == f.candidates.count ? "fillers.keepAll" : "fillers.removeAll")) {
                f.dropped = chosen.count == f.candidates.count ? [] : Set(f.candidates.map(\.id))
            }
            .buttonStyle(.link).font(Theme.Fonts.hint).testID("fillers.toggleAll")
            Text(verbatim: tr("fillers.saves", Fmt.num(seconds, 1))).font(Theme.Fonts.hint).foregroundStyle(IStyle.caption).lineLimit(1)
            Spacer()
            PillButton(title: tr("common.cancel")) { store.cancelFillerReview() }.testID("fillers.cancel")
            PillButton(title: tr(f.style == .inline ? "fillers.applyN" : "fillers.removeN", chosen.count), accent: true, enabled: !chosen.isEmpty) {
                store.applyFillerReview()
            }
            .testID("fillers.apply")
        }
        .padding(10)
        .background(Theme.panelHeader.opacity(0.6))
    }
}
