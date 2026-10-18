import SwiftUI
import Observation
import MontageCore
import MontageEngine
import MontageAI

/// EditPilot chat state (AI-048). Lives in `store.ai.pilot`.
@Observable
public final class PilotState {
    public enum CardState: Equatable { case planning, preparing, ready, applied, discarded, failed, empty }

    /// One plan proposed by the agent.
    public struct Card: Equatable {
        public var state: CardState = .planning
        public var engine: EditPilotPlanner.Engine = .rules
        public var actions: [PilotAction] = []
        /// Step indices (into `actions`) the user unticked.
        public var disabled: Set<Int> = []
        public var results: [PilotStepResult] = []
        public var diff: [PilotDiffRow] = []
        public var error: String?
        public var enabledActions: [PilotAction] { actions.enumerated().filter { !disabled.contains($0.offset) }.map(\.element) }
    }

    public struct Message: Identifiable, Equatable {
        public enum Role: Equatable { case user, assistant }
        public let id = UUID()
        public let role: Role
        public var text: String
        public var card: Card?
    }

    public var isOpen = false
    public var input = ""
    public var messages: [Message] = []
    public var phase: PilotPhase?
    public var progress: Double = 0
    /// Message whose plan is shown live in the player (a store gesture: discarded unless applied).
    public var previewing: UUID?
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var job: JobID?
    @ObservationIgnored var executions: [UUID: PilotExecution] = [:]
    public var isBusy: Bool { messages.last?.card.map { $0.state == .planning || $0.state == .preparing } ?? false }
    public init() {}
}

extension EditorStore {
    var pilot: PilotState { ai.pilot }

    /// Planner model used for this session: UI tests on the sandboxed (empty) models folder always use the rule-based
    /// planner so results don't depend on whether Apple Intelligence happens to be on.
    var pilotUsesModel: Bool { !ModelCatalog.isSandboxed }
    public var pilotEngine: EditPilotPlanner.Engine { pilotUsesModel ? EditPilotPlanner.engine : .rules }

    public func togglePilot() {
        pilot.isOpen.toggle()
        if pilot.isOpen { ai.transcriptOpen = false }
    }

    /// Sends a chat instruction: plan (language model / rules) → prepare (analyses as a background job, progress,
    /// cancel) → a plan card with the step results and the diff, ready to preview / apply as one undo step.
    public func sendPilot(_ text: String? = nil) {
        let request = (text ?? pilot.input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !pilot.isBusy else { return }
        endPilotPreview(apply: false)
        pilot.input = ""
        let history = pilot.messages.filter { $0.role == .user }.map(\.text)
        pilot.messages.append(.init(role: .user, text: request))
        pilot.messages.append(.init(role: .assistant, text: tr("pilot.thinking"), card: PilotState.Card()))
        let id = pilot.messages[pilot.messages.count - 1].id
        let project = self.project, selection = self.selection, useModel = pilotUsesModel
        pilot.task = Task {
            let box = PilotPlanBox()
            let jid = await JobQueue.shared.enqueue(titleKey: "pilot.job.plan", priority: 1) { _ in
                box.plan = await EditPilotPlanner.plan(request, project: project, selection: selection, history: history, useModel: useModel)
            }
            pilot.job = jid
            let st = await JobQueue.shared.wait(jid)
            pilot.job = nil
            guard st == .done, let plan = box.plan else { finishPilotCard(id, state: st == .cancelled ? .discarded : .failed); return }
            updateCard(id) { c in c.engine = plan.engine; c.actions = EditPilotExecutor.ordered(plan.actions) }
            guard !plan.actions.isEmpty else {
                setMessageText(id, tr("pilot.reply.none"))
                finishPilotCard(id, state: .empty)
                return
            }
            setMessageText(id, plan.actions.count == 1 ? tr("pilot.reply.plan1") : tr("pilot.reply.plan", plan.actions.count))
            await preparePilot(id)
        }
    }

    /// (Re)computes the plan's result on the current project (after a step was ticked/unticked, or before applying
    /// when the project changed since). Analyses are cached per media, so re-runs are quick.
    func preparePilot(_ id: UUID) async {
        guard let card = card(id) else { return }
        updateCard(id) { $0.state = .preparing; $0.error = nil }
        let actions = card.enabledActions, project = self.project, selection = self.selection
        let box = PilotExecutionBox()
        pilot.progress = 0
        let jid = await JobQueue.shared.enqueue(titleKey: "pilot.job.prepare", priority: 1) { [weak self] progress in
            box.execution = try await EditPilotExecutor.run(actions, project: project, selection: selection, progress: { p in
                progress.report(p)
                Task { @MainActor in self?.pilot.progress = p }
            }, phase: { ph in Task { @MainActor in self?.pilot.phase = ph } })
        }
        pilot.job = jid
        let st = await JobQueue.shared.wait(jid)
        pilot.job = nil
        pilot.phase = nil
        switch st {
        case .done:
            guard let ex = box.execution else { return }
            pilot.executions[id] = ex
            updateCard(id) { c in
                // results are in execution order = card order; unticked steps keep their row without a result
                var all: [PilotStepResult] = []
                var k = 0
                for (i, a) in c.actions.enumerated() {
                    if c.disabled.contains(i) { all.append(PilotStepResult(id: i, action: a, detail: nil, changed: false)); continue }
                    let r = k < ex.results.count ? ex.results[k] : nil
                    all.append(PilotStepResult(id: i, action: a, detail: r?.detail, changed: r?.changed ?? false))
                    k += 1
                }
                c.results = all
                c.diff = PilotDiff.rows(ex.before, ex.after)
                c.state = .ready
            }
        case .cancelled: finishPilotCard(id, state: .discarded)
        default:
            updateCard(id) { $0.error = tr("pilot.error.failed") }
            finishPilotCard(id, state: .failed)
        }
    }

    public func setPilotStep(_ id: UUID, index: Int, enabled: Bool) {
        guard let c = card(id), c.state == .ready else { return }
        endPilotPreview(apply: false)
        updateCard(id) { c in
            if enabled { c.disabled.remove(index) } else { c.disabled.insert(index) }
            c.state = .preparing
        }
        pilot.task = Task { await preparePilot(id) }
    }

    /// Applies the plan as ONE undo step ("EditPilot"). Re-prepares first when the project changed since the preview.
    public func applyPilot(_ id: UUID) {
        guard let c = card(id), c.state == .ready else { return }
        if pilot.previewing == id, pilot.executions[id] != nil {
            endPilotPreview(apply: true)
            finishPilotApplied(id)
            return
        }
        endPilotPreview(apply: false)
        pilot.task = Task {
            if pilot.executions[id]?.before != project { await preparePilot(id) }
            guard let ex = pilot.executions[id], ex.before == project, card(id)?.state == .ready else { return }
            let after = ex.after
            guard ex.changed, perform(Edit("cmd.editPilot") { $0 = after }) else {
                showToast(tr("pilot.nothingChanged"))
                return
            }
            finishPilotApplied(id)
        }
    }

    func finishPilotApplied(_ id: UUID) {
        finishPilotCard(id, state: .applied)
        requestPilotFollowUps()
        showToast(tr("pilot.applied"))
    }

    /// Audio steps that rely on ML stems (Reduce noise / Enhance voice) start them in the background, like the inspector.
    func requestPilotFollowUps() {
        for c in project.timeline.allClips where c.audio.noiseReduction != nil || c.audio.enhanceVoice != nil { requestVoiceStems(c.id) }
    }

    public func discardPilot(_ id: UUID) {
        if pilot.previewing == id { endPilotPreview(apply: false) }
        finishPilotCard(id, state: .discarded)
    }

    /// Undo of an applied plan (only while it is the latest undo step).
    public func undoPilot(_ id: UUID) {
        guard card(id)?.state == .applied, session.undoNameKey == "cmd.editPilot" else { return }
        undo()
        updateCard(id) { $0.state = .ready }
    }

    public var canUndoPilot: Bool { session.undoNameKey == "cmd.editPilot" }

    /// Shows the planned result in the player and timeline without committing it (a store gesture).
    public func togglePilotPreview(_ id: UUID) {
        if pilot.previewing == id { endPilotPreview(apply: false); return }
        endPilotPreview(apply: false)
        guard let ex = pilot.executions[id], ex.before == project, ex.changed else { return }
        let after = ex.after
        beginGesture("cmd.editPilot")
        pilot.previewing = id
        updateGesture { $0 = after }
    }

    /// Ends the live preview: `apply` commits it as the undo step, else the project goes back to before the preview.
    public func endPilotPreview(apply: Bool) {
        guard pilot.previewing != nil else { return }
        pilot.previewing = nil
        if apply { endGesture() } else { cancelGesture() }
    }

    /// Called by `perform` / `beginGesture` before any other edit: an un-applied preview must never be committed by it.
    func cancelPilotPreviewBeforeEdit() {
        guard pilot.previewing != nil else { return }
        pilot.previewing = nil
        if session.isInGesture { cancelGesture() }
    }

    public func cancelPilotWork() {
        if let j = pilot.job { Task { await JobQueue.shared.cancel(j) } }
        pilot.task?.cancel()
    }

    public func newPilotChat() {
        cancelPilotWork()
        endPilotPreview(apply: false)
        pilot.messages = []
        pilot.executions = [:]
    }

    // MARK: Helpers

    func card(_ id: UUID) -> PilotState.Card? { pilot.messages.first { $0.id == id }?.card }

    func updateCard(_ id: UUID, _ body: (inout PilotState.Card) -> Void) {
        guard let i = pilot.messages.firstIndex(where: { $0.id == id }), var c = pilot.messages[i].card else { return }
        body(&c)
        pilot.messages[i].card = c
    }

    func setMessageText(_ id: UUID, _ text: String) {
        if let i = pilot.messages.firstIndex(where: { $0.id == id }) { pilot.messages[i].text = text }
    }

    func finishPilotCard(_ id: UUID, state: PilotState.CardState) {
        updateCard(id) { $0.state = state }
        if state == .failed { setMessageText(id, tr("pilot.error.failed")) }
        if state == .discarded, card(id)?.actions.isEmpty ?? true { setMessageText(id, tr("pilot.cancelled")) }
    }

    /// `ui.pilot` in the UI-test state dump.
    func pilotStateDump() -> [String: Any] {
        let last = pilot.messages.last { $0.card != nil }?.card
        return [
            "open": pilot.isOpen, "messages": pilot.messages.count, "busy": pilot.isBusy,
            "previewing": pilot.previewing != nil, "engine": pilotEngine.rawValue,
            "state": last.map { "\($0.state)" } ?? "",
            "steps": last?.actions.map { "\($0)".components(separatedBy: "(").first ?? "" } ?? [],
            "results": last?.results.map { $0.detail ?? "" } ?? [],
            "diff": last?.diff.map(\.key) ?? [],
        ]
    }
}

/// AI shortcuts (appended to `ShortcutRegistry.builtins`).
enum AIShortcuts {
    static let all: [Shortcut] = [
        Shortcut("editPilot", "shortcut.editPilot", .char("j"), .command) { $0.togglePilot() },
    ]
}

nonisolated final class PilotPlanBox: @unchecked Sendable { var plan: EditPilotPlanner.Plan? }
nonisolated final class PilotExecutionBox: @unchecked Sendable { var execution: PilotExecution? }
