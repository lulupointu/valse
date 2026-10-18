import SwiftUI
import AppKit
import MontageCore
import MontageEngine
import MontageAI

/// EditPilot (AI-048): chat with an on-device editing agent. Replaces the asset panel (like Transcript), opened from the
/// title bar ✦ button / ⌘J. Each request becomes a plan card: the steps (untick to drop one), what each changed, a diff
/// of the project, and Preview (shows the result live) · Discard · Apply (one undo step "EditPilot", with Undo).
struct EditPilotPanel: View {
    let store: EditorStore
    @FocusState private var inputFocused: Bool

    static let suggestionKeys = ["pilot.suggest.silences", "pilot.suggest.captions", "pilot.suggest.vertical",
                                 "pilot.suggest.fades", "pilot.suggest.boring", "pilot.suggest.title"]

    var body: some View {
        let pilot = store.ai.pilot
        Panel {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                Text(loc: "pilot.title").font(Theme.Fonts.panelTitle).foregroundStyle(Theme.textPrimary)
                EngineBadge(engine: store.pilotEngine)
                Spacer()
                SmallIconButton(symbol: "square.and.pencil", help: tr("pilot.newChat"), enabled: !pilot.messages.isEmpty) { store.newPilotChat() }
                    .testID("pilot.new")
                SmallIconButton(symbol: "xmark", help: tr("pilot.close")) { store.endPilotPreview(apply: false); pilot.isOpen = false }
                    .testID("pilot.close")
            }
            .padding(.horizontal, 12)
        } content: {
            VStack(spacing: 0) {
                // basic mode: no local LLM (and no Apple Intelligence, which UI tests on the sandbox ignore)
                if !LlamaRuntime.isAvailable && (!OnDeviceLLM.hasFoundationModels || !store.pilotUsesModel) { modelBanner }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if pilot.messages.isEmpty { empty }
                            ForEach(pilot.messages) { m in
                                MessageView(store: store, message: m).id(m.id)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: pilot.messages.count) { _, _ in
                        if let last = pilot.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
                inputBar
            }
        }
        .testID("pilot.panel")
    }

    var modelBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HintText(text: tr("pilot.basicMode"))
            ModelStateControls(spec: ModelCatalog.qwen3_4b)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.inset)
    }

    var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 20)).foregroundStyle(Theme.accent)
                Text(loc: "pilot.emptyTitle").font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.textPrimary)
            }
            HintText(text: tr("pilot.emptyHint"))
            Text(loc: "pilot.tryThese").font(Theme.Fonts.hint).foregroundStyle(IStyle.caption).padding(.top, 4)
            ForEach(Array(Self.suggestionKeys.enumerated()), id: \.offset) { i, key in
                Button { store.sendPilot(tr(key)) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "text.bubble").font(.system(size: 11)).foregroundStyle(Theme.accent)
                        Text(verbatim: tr(key)).font(Theme.Fonts.row).foregroundStyle(Theme.textPrimary).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Theme.control.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .testID("pilot.suggestion.\(i)")
            }
        }
    }

    var inputBar: some View {
        let pilot = store.ai.pilot
        return HStack(alignment: .bottom, spacing: 8) {
            TextField(tr("pilot.placeholder"), text: Binding(get: { pilot.input }, set: { pilot.input = $0 }), axis: .vertical)
                .textFieldStyle(.plain).font(Theme.Fonts.row).lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit { store.sendPilot() }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(IStyle.field, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(inputFocused ? Theme.accent.opacity(0.7) : Theme.separator))
                .testID("pilot.input")
            DictateButton(text: Binding(get: { pilot.input }, set: { pilot.input = $0 }), testID: "pilot.dictate")
            Button { store.sendPilot() } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
                    .foregroundStyle(pilot.input.trimmingCharacters(in: .whitespaces).isEmpty || pilot.isBusy ? Theme.textTertiary : Theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(pilot.input.trimmingCharacters(in: .whitespaces).isEmpty || pilot.isBusy)
            .help(tr("pilot.send"))
            .testID("pilot.send")
        }
        .padding(10)
        .overlay(alignment: .top) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }
}

private struct EngineBadge: View {
    let engine: EditPilotPlanner.Engine
    var body: some View {
        Text(verbatim: tr(engine.nameKey))
            .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.control, in: Capsule())
            .help(tr("pilot.engine.help"))
            .testID("pilot.engine")
    }
}

private struct MessageView: View {
    let store: EditorStore
    let message: PilotState.Message
    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(verbatim: message.text).font(Theme.Fonts.row).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Theme.accentDim, in: RoundedRectangle(cornerRadius: 10))
                    .textSelection(.enabled)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(Theme.accent).padding(.top, 2)
                    Text(verbatim: message.text).font(Theme.Fonts.row).foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let card = message.card { PlanCardView(store: store, id: message.id, card: card) }
            }
        }
    }
}

private struct PlanCardView: View {
    let store: EditorStore
    let id: UUID
    let card: PilotState.Card

    var body: some View {
        let pilot = store.ai.pilot
        VStack(alignment: .leading, spacing: 8) {
            switch card.state {
            case .planning:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(loc: "pilot.planning").font(Theme.Fonts.hint).foregroundStyle(IStyle.caption)
                    Spacer()
                    Button(tr("ai.cancel")) { store.cancelPilotWork() }.buttonStyle(.link).font(Theme.Fonts.hint)
                }
            case .empty:
                ForEach(Array(EditPilotPanel.suggestionKeys.prefix(3).enumerated()), id: \.offset) { _, key in
                    Button { store.sendPilot(tr(key)) } label: {
                        Text(verbatim: "› " + tr(key)).font(Theme.Fonts.hint).foregroundStyle(Theme.accent)
                    }.buttonStyle(.plain)
                }
            default:
                steps
                if card.state == .preparing {
                    JobProgressLine(text: tr(pilot.phase?.titleKey ?? "pilot.phase.applying", Int(pilot.progress * 100)),
                                    progress: pilot.progress) { store.cancelPilotWork() }
                        .testID("pilot.progress")
                }
                if !card.diff.isEmpty && card.state != .discarded { diff }
                if let e = card.error { HintText(text: e, color: IStyle.warning) }
                footer
            }
        }
        .padding(10)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(pilot.previewing == id ? Theme.accent : Theme.separator))
        .opacity(card.state == .discarded ? 0.55 : 1)
        .testID("pilot.card")
    }

    var steps: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(card.actions.enumerated()), id: \.offset) { i, a in
                let on = !card.disabled.contains(i)
                let result = card.results.first { $0.id == i }
                HStack(alignment: .top, spacing: 8) {
                    if card.state == .ready || card.state == .preparing {
                        CapCheckbox(isOn: Binding(get: { on }, set: { store.setPilotStep(id, index: i, enabled: $0) }),
                                    enabled: card.state == .ready)
                            .testID("pilot.step.\(i)")
                    } else {
                        Image(systemName: card.state == .applied && (result?.changed ?? false) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 13)).foregroundStyle(card.state == .applied ? Theme.accent : IStyle.caption)
                    }
                    Image(systemName: a.symbol).font(.system(size: 11)).foregroundStyle(IStyle.icon).frame(width: 16).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: a.summary).font(Theme.Fonts.row).foregroundStyle(on ? Theme.textPrimary : IStyle.caption)
                            .strikethrough(!on)
                            .fixedSize(horizontal: false, vertical: true)
                        if let r = result, on, card.state != .preparing {
                            Text(verbatim: r.detail ?? tr("pilot.result.nothing")).font(Theme.Fonts.hint)
                                .foregroundStyle(r.changed ? Theme.accent : IStyle.caption)
                        }
                    }
                }
            }
        }
    }

    var diff: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(loc: "pilot.diff.title").font(Theme.Fonts.hint).foregroundStyle(IStyle.caption)
            ForEach(card.diff) { row in
                HStack(spacing: 6) {
                    Text(verbatim: tr(row.key)).font(Theme.Fonts.hint).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(verbatim: row.before).font(Theme.Fonts.numeric).foregroundStyle(IStyle.caption)
                    Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(IStyle.caption)
                    Text(verbatim: row.after).font(Theme.Fonts.numeric).foregroundStyle(Theme.textPrimary)
                }
            }
        }
        .padding(8)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
        .testID("pilot.diff")
    }

    @ViewBuilder var footer: some View {
        let pilot = store.ai.pilot
        HStack(spacing: 8) {
            switch card.state {
            case .ready:
                let hasChanges = !card.diff.isEmpty || card.results.contains(where: \.changed)
                PillButton(title: tr(pilot.previewing == id ? "pilot.stopPreview" : "pilot.preview"),
                           symbol: pilot.previewing == id ? "eye.slash" : "eye", enabled: hasChanges) { store.togglePilotPreview(id) }
                    .testID("pilot.preview")
                Spacer()
                Button(tr("pilot.discard")) { store.discardPilot(id) }.buttonStyle(SecondaryButtonStyle()).testID("pilot.discard")
                Button(tr("pilot.apply")) { store.applyPilot(id) }.buttonStyle(AccentButtonStyle()).disabled(!hasChanges)
                    .testID("pilot.apply")
            case .applied:
                Label(tr("pilot.appliedLabel"), systemImage: "checkmark.circle.fill").font(Theme.Fonts.hint).foregroundStyle(Theme.accent)
                Spacer()
                if store.canUndoPilot {
                    PillButton(title: tr("pilot.undo"), symbol: "arrow.uturn.backward") { store.undoPilot(id) }.testID("pilot.undo")
                }
            case .discarded:
                Text(loc: "pilot.discarded").font(Theme.Fonts.hint).foregroundStyle(IStyle.caption)
            default:
                EmptyView()
            }
        }
    }
}
