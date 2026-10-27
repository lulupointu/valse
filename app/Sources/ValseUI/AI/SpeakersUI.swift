import SwiftUI
import ValseCore
import ValseEngine
import ValseAI
import Perception

// Speaker ID in captions (AI-005 / TX-038). Text ▸ Auto captions ▸ ☐ Identify speakers (+ number of speakers) tags
// and splits the generated captions per speaker; Inspector ▸ Captions ▸ Speakers lists them: rename, colour per
// speaker, apply the selected caption's style to all captions of its speaker, identify speakers on existing captions
// (background job with progress / cancel, one undo step), remove the labels.

enum SpeakersInspector {
    @MainActor static let sections: [InspectorSection] = [
        InspectorSection(id: "captions.speakers", tab: "captions", order: -1, titleKey: "speakers.title") { AnyView(SpeakersSection(ctx: $0)) },
    ]

    /// Number-of-speakers choices (nil = Auto).
    static var countItems: [(id: Int?, title: String)] {
        [(nil, tr("speakers.count.auto"))] + (2...6).map { (Optional($0), "\($0)") }
    }
}

/// Speaker display name ("Speaker 2" / "Intervenant 2" or the user's name).
func speakerName(_ id: String, in p: Project) -> String {
    if let n = p.speakers?.first(where: { $0.id == id })?.name { return n }
    return tr("speakers.default", Int(id) ?? 0)
}

struct SpeakersSection: View {
    let ctx: InspectorContext
    var body: some View {
        WithPerceptionTracking {
            let store = ctx.store
            let p = store.project
            let ids = SpeakerCaptions.speakerIDs(in: p.timeline)
            let selectedSpeaker = store.singleSelectedClip.flatMap { CaptionOps.text($0)?.caption?.speaker }
            VStack(alignment: .leading, spacing: 8) {
                if store.ai.speakerJob != nil {
                    JobProgressLine(text: tr("speakers.progress", Int(store.ai.speakerProgress * 100)), progress: store.ai.speakerProgress) {
                        store.cancelSpeakerIdentification()
                    }
                    .testID("speakers.progress")
                }
                if ids.isEmpty {
                    HintText(text: tr("speakers.hint"))
                    HStack(spacing: 8) {
                        Dropdown(items: SpeakersInspector.countItems, selection: store.ai.speakerCount) { store.ai.speakerCount = $0 }
                            .frame(width: 110)
                        PillButton(title: tr("speakers.identify"), symbol: "person.2.wave.2", accent: true,
                                   enabled: store.ai.speakerJob == nil) { store.identifySpeakers() }
                            .testID("speakers.identify")
                    }
                } else {
                    ForEach(ids, id: \.self) { id in
                        WithPerceptionTracking {
                            SpeakerRow(store: store, id: id, count: count(id, p), isSelected: selectedSpeaker == id)
                        }
                    }
                    HStack(spacing: 8) {
                        if let s = selectedSpeaker {
                            PillButton(title: tr("speakers.applyStyle", speakerName(s, in: p))) { store.applyCaptionLookToSpeaker() }
                                .help(tr("speakers.applyStyle.help"))
                                .testID("speakers.applyStyle")
                        }
                        Spacer()
                        SmallIconButton(symbol: "arrow.clockwise", help: tr("speakers.reidentify"), enabled: store.ai.speakerJob == nil) { store.identifySpeakers() }
                            .testID("speakers.reidentify")
                        SmallIconButton(symbol: "trash", help: tr("speakers.remove")) { store.clearSpeakers() }
                            .testID("speakers.remove")
                    }
                }
            }
            .testID("speakers.section")
        }
    }

    func count(_ id: String, _ p: Project) -> Int {
        SpeechCaptions.captions(in: p.timeline).filter { CaptionOps.text($0)?.caption?.speaker == id }.count
    }
}

struct SpeakerRow: View {
    let store: EditorStore
    let id: String
    let count: Int
    let isSelected: Bool
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        WithPerceptionTracking {
            let p = store.project
            let color = p.speakers?.first { $0.id == id }?.color ?? SpeakerCaptions.defaultColor((Int(id) ?? 1) - 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(Color(color)).frame(width: 12, height: 12)
                    TextField(tr("speakers.default", Int(id) ?? 0), text: $name)
                        .textFieldStyle(.plain).font(Theme.Fonts.row).focused($focused)
                        .padding(.horizontal, 8).frame(height: 26).background(Theme.inset, in: RoundedRectangle(cornerRadius: 4))
                        .onSubmit { commit() }
                        .onValueChange(of: focused) { _, f in if !f { commit() } }
                        .testID("speakers.name.\(id)")
                    Text(verbatim: tr("speakers.captions", count)).font(Theme.Fonts.hint).foregroundStyle(IStyle.caption).fixedSize()
                }
                HStack(spacing: 6) {
                    ForEach(Array(SpeakerCaptions.palette.enumerated()), id: \.offset) { k, c in
                        WithPerceptionTracking {
                            Circle().fill(Color(c))
                                .frame(width: 14, height: 14)
                                .overlay(Circle().strokeBorder(c == color ? Theme.accent : Color.black.opacity(0.4), lineWidth: c == color ? 2 : 1))
                                .contentShape(Circle())
                                .onTapGesture { store.setSpeakerColor(id, c) }
                                .testID("speakers.color.\(id).\(k)")
                        }
                    }
                }
                .padding(.leading, 20)
            }
            .padding(8)
            .background(isSelected ? Theme.accentDim.opacity(0.28) : IStyle.field.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
            .onAppear { name = p.speakers?.first { $0.id == id }?.name ?? "" }
            .onValueChange(of: p.speakers) { _, s in if !focused { name = s?.first { $0.id == id }?.name ?? "" } }
        }
    }

    func commit() {
        let current = store.project.speakers?.first { $0.id == id }?.name ?? ""
        if name != current { store.renameSpeaker(id, to: name) }
    }
}

/// Small speaker label on a caption row (Inspector ▸ Captions list).
struct SpeakerChip: View {
    let store: EditorStore
    let speaker: String
    var body: some View {
        WithPerceptionTracking {
            let p = store.project
            let color = p.speakers?.first { $0.id == speaker }?.color ?? SpeakerCaptions.defaultColor((Int(speaker) ?? 1) - 1)
            HStack(spacing: 4) {
                Circle().fill(Color(color)).frame(width: 7, height: 7)
                Text(verbatim: speakerName(speaker, in: p)).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .padding(.horizontal, 6).frame(height: 16)
            .background(Theme.control.opacity(0.6), in: Capsule())
        }
    }
}

extension EditorStore {
    /// Inspector ▸ Captions ▸ Identify speakers: diarizes the audio under the existing captions in the background and
    /// tags each caption with its speaker (one undo step). Cancel = the ✕ on the progress line.
    public func identifySpeakers() {
        guard ai.speakerJob == nil, !SpeechCaptions.captions(in: project.timeline).isEmpty else { return }
        let project = self.project
        let count = ai.speakerCount
        let box = CommandBox()
        ai.speakerProgress = 0
        Task {
            let id = await JobQueue.shared.enqueue(titleKey: "speakers.job", priority: 1, heavy: true) { [weak self] progress in
                box.command = try await SpeakerIdentification.run(project: project, speakerCount: count) { f in
                    progress.report(f)
                    Task { @MainActor in self?.ai.speakerProgress = f }
                }
            }
            ai.speakerJob = id
            let st = await JobQueue.shared.wait(id)
            if ai.speakerJob == id { ai.speakerJob = nil }
            switch st {
            case .done:
                if let cmd = box.command, perform(cmd) {
                    showToast(tr("speakers.done", SpeakerCaptions.speakerIDs(in: self.project.timeline).count))
                }
            case .failed: showToast(tr("speakers.failed"), error: true)
            case .cancelled: showToast(tr("speakers.cancelled"))
            default: break
            }
        }
    }

    public func cancelSpeakerIdentification() {
        if let id = ai.speakerJob { Task { await JobQueue.shared.cancel(id) } }
    }

    public func renameSpeaker(_ id: String, to name: String) {
        perform(Edit("cmd.speakerRename") { p in SpeakerCaptions.rename(id, to: name, in: &p) })
    }

    public func setSpeakerColor(_ id: String, _ color: RGBA) {
        perform(Edit("cmd.speakerColor") { p in SpeakerCaptions.setColor(id, color, in: &p) })
    }

    /// Copies the selected caption's look to every caption of the same speaker.
    public func applyCaptionLookToSpeaker() {
        guard let c = singleSelectedClip, CaptionOps.text(c)?.caption?.speaker != nil else { return }
        let id = c.id
        if perform(Edit("cmd.speakerStyle") { p in SpeakerCaptions.applyLookToSpeaker(from: id, in: &p) }) {
            showToast(tr("speakers.styleApplied"))
        }
    }

    public func clearSpeakers() {
        perform(Edit("cmd.speakerRemove") { p in SpeakerCaptions.clear(in: &p) })
    }
}
