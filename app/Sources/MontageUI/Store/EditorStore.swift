import SwiftUI
import Observation
import AppKit
import UniformTypeIdentifiers
import MontageCore
import MontageEffects
import MontageEngine
import MontageAI

/// Playhead + transport, kept separate from `EditorStore` so 30 Hz playhead updates only re-render what shows time.
@Observable
public final class TransportState {
    public var playhead: Time = .zero
    public var isPlaying = false
}

public struct Toast: Equatable, Identifiable {
    public let id = UUID()
    public let message: String
    public let isError: Bool
}

public enum ExportState: Equatable {
    case idle
    case running(Double)
    case done(URL)
    case failed(String)
}

/// The editor's single source of truth on the main actor.
///
/// - Every model change goes through `perform(_:)` (undoable command) or a gesture (`beginGesture`/`updateGesture`/
///   `endGesture`); both funnel into `didChangeProject()` which updates the playback engine, autosave and observers.
/// - Views read `project`, `selection`, `transport`… (Observation); AppKit views use `observe(_:)`.
/// - Long work (import probing, export, AI) runs off-main and reports back here.
@Observable
public final class EditorStore {
    public private(set) var session: EditSession
    public var project: Project { session.project }
    public var selection: Set<ClipID> = [] { didSet { if selection != oldValue { selectionDidChange() } } }
    public let transport = TransportState()
    /// Timeline view state: tool mode, scroll, clipboard, selected transition/marker (W1, MontageUI/Timeline).
    public let timelineUI = TimelineUIState()
    /// Timeline zoom (points per second).
    public var pixelsPerSecond: Double = 40
    public private(set) var packageURL: URL?
    public private(set) var lastAutosave: Date?
    public var toast: Toast?
    public private(set) var jobs: [JobInfo] = []
    public var exportState: ExportState = .idle
    public var isExportSheetPresented = false
    public var activeAssetTab = "media"
    public var inspectorTab: String?
    public var previewQuality: PreviewQuality = .auto { didSet { engine.previewQuality = previewQuality } }
    /// Media hash → proxy generating.
    public var proxyPending: Set<String> = []

    @ObservationIgnored public let engine: PlaybackEngine
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var firstUnsavedEdit: Date?
    @ObservationIgnored private var jobsTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored public var autosavePolicy = AutosavePolicy()
    @ObservationIgnored public var autosaveEnabled = true

    public init(project: Project = Project(), packageURL: URL? = nil) {
        MontageBootstrap.registerResources()
        session = EditSession(project: project)
        self.packageURL = packageURL
        engine = PlaybackEngine(project: project)
        engine.onTimeUpdate = { [weak self] t in self?.transport.playhead = t }
        engine.onPlayStateChange = { [weak self] playing in self?.transport.isPlaying = playing }
        ProxyManager.shared.onProxyReady = { [weak self] hash in
            guard let self else { return }
            self.proxyPending.remove(hash)
            if self.project.media.contains(where: { $0.contentHash == hash }) { self.engine.forceRebuild() }
        }
        jobsTask = Task { [weak self] in
            for await list in await JobQueue.shared.updates() { self?.jobs = list }
        }
        if let packageURL { SessionLock.acquire(packageURL) }
    }

    // MARK: Editing

    /// Applies an undoable command. Errors become a toast.
    @discardableResult
    public func perform(_ command: any EditCommand) -> Bool {
        do {
            try session.perform(command)
            didChangeProject()
            return true
        } catch let e as EditError {
            if e != .nothingToDo { showToast(tr(e.messageKey), error: true) }
        } catch {
            showToast(String(describing: error), error: true)
        }
        return false
    }

    public func beginGesture(_ nameKey: String) { session.beginGesture(nameKey) }

    /// Live update during a gesture (applied to the gesture's base snapshot → idempotent drags).
    public func updateGesture(_ body: (inout Project) throws -> Void) {
        do { try session.updateGesture(body); didChangeProject() } catch {}
    }

    public func endGesture() { session.endGesture(); didChangeProject() }
    public func cancelGesture() { session.cancelGesture(); didChangeProject() }

    /// Edits the selected clip(s) as one gesture step (slider drag) — begin/end handled by the caller's control.
    public func updateSelectedClips(_ body: @escaping (inout Clip) -> Void) {
        let ids = selection
        let box = UncheckedSendable(body)
        if session.isInGesture {
            updateGesture { p in for id in ids { if var c = p.timeline.clip(id) { box.value(&c); p.timeline[clip: id] = c } } }
        } else {
            perform(Edit("cmd.editClip") { p in for id in ids { if var c = p.timeline.clip(id) { box.value(&c); p.timeline[clip: id] = c } } })
        }
    }

    public func undo() {
        if let key = session.undo() { showToast(tr("toast.undo", tr(key))); didChangeProject() }
    }

    public func redo() {
        if let key = session.redo() { showToast(tr("toast.redo", tr(key))); didChangeProject() }
    }

    private func didChangeProject() {
        engine.update(project: session.project)
        selection = selection.filter { session.project.timeline.clip($0) != nil }
        scheduleAutosave()
    }

    private func selectionDidChange() {
        if let t = inspectorTab, !InspectorRegistry.tabs(for: InspectorContext(store: self)).contains(where: { $0.id == t }) {
            inspectorTab = nil
        }
    }

    // MARK: Selection helpers

    public var selectedClips: [Clip] { selection.compactMap { project.timeline.clip($0) } }
    public var singleSelectedClip: Clip? { selection.count == 1 ? selectedClips.first : nil }

    public func trackKind(of clip: Clip) -> TrackKind? {
        project.timeline.locate(clip.id).map { project.timeline.tracks[$0.track].kind }
    }

    // MARK: Import & insert

    public func importFiles(_ urls: [URL], thenInsertAt time: Time? = nil, target: InsertTarget = .automatic) {
        let files = MediaProbe.expand(urls)
        guard !files.isEmpty else { return }
        Task {
            let (assets, failed) = await MediaProbe.probeAll(files)
            if !failed.isEmpty { showToast(tr("toast.importFailed", failed.count), error: true) }
            guard !assets.isEmpty else { return }
            let existing = Dictionary(project.media.map { ($0.contentHash, $0) }, uniquingKeysWith: { a, _ in a })
            let fresh = assets.filter { existing[$0.contentHash] == nil }
            if !fresh.isEmpty { perform(AddMedia(fresh)) }
            let all = assets.map { existing[$0.contentHash] ?? $0 }
            await ProxyManager.shared.request(all)
            proxyPending.formUnion(all.filter { ProxyManager.shared.isPending($0) }.map(\.contentHash))
            if let time {
                var t = time
                for a in all {
                    addToTimeline(a.id, at: t, target: target)
                    t += a.defaultClipDuration
                }
            }
            for a in all { Task.detached { _ = await ThumbnailCache.shared.thumbnail(a, at: .zero, height: 96) } }
        }
    }

    /// Adds a media item at `time` (default: playhead; main track inserts at the nearest cut).
    @discardableResult
    public func addToTimeline(_ mediaID: MediaID, at time: Time? = nil, target: InsertTarget = .automatic) -> ClipID? {
        guard let asset = project.asset(mediaID) else { return nil }
        let clip = TimelineOps.makeClip(for: asset, at: time ?? transport.playhead)
        guard perform(InsertClip(clip, target: target)) else { return nil }
        selection = [clip.id]
        if project.timeline.mainTrack?.clips.count == 1, project.settings.aspectPreset == "original" || project.timeline.allClips.count == 1 {
            adoptCanvas(from: asset)
        }
        return clip.id
    }

    /// First clip sets the canvas ratio (CapCut "Original").
    private func adoptCanvas(from asset: MediaAsset) {
        guard asset.pixelSize.width > 0, asset.pixelSize.height > 0 else { return }
        let size = asset.pixelSize
        let short = min(size.width, size.height)
        let k = short > 1080 ? 1080 / short : 1
        let canvas = Size2((size.width * k / 2).rounded() * 2, (size.height * k / 2).rounded() * 2)
        guard canvas != project.settings.canvasSize else { return }
        session.updateGestureIncrementally { $0.settings.canvasSize = canvas; $0.settings.aspectPreset = "original" }
        if let fr = asset.frameRate { session.updateGestureIncrementally { $0.settings.frameRate = fr } }
        didChangeProject()
    }

    /// Adds a generator clip (text, sticker, adjustment…) at the playhead on a new track.
    @discardableResult
    public func addGeneratorClip(_ content: ClipContent, duration: Time = Time(3), effects: [EffectInstance] = [],
                                 nameKey: String = "cmd.addClip") -> ClipID? {
        var c = Clip(content: content, start: transport.playhead, duration: duration)
        c.effects = effects
        guard perform(InsertClip(c, target: .automatic, nameKey: nameKey)) else { return nil }
        selection = [c.id]
        return c.id
    }

    public func addText(style: TextStyleDescriptor? = nil) {
        var t = TextContent(string: tr("text.default"))
        style?.apply(&t)
        t.styleID = style?.id
        addGeneratorClip(.text(t), nameKey: "cmd.text")
    }

    /// Applies an effect/filter: to the selected visual clips, or as a new adjustment clip when nothing is selected.
    public func applyEffect(_ d: EffectDescriptor) {
        let targets = selectedClips.filter { c in trackKind(of: c).map { $0 != .audio } ?? false }
        if targets.isEmpty {
            addGeneratorClip(.adjustment, effects: [d.makeInstance()], nameKey: d.category == .filter ? "cmd.filter" : "cmd.effect")
        } else {
            perform(Edit(d.category == .filter ? "cmd.filter" : "cmd.effect") { p in
                for c in targets {
                    guard var clip = p.timeline.clip(c.id) else { continue }
                    if d.category == .filter { clip.effects.removeAll { Registries.effects[$0.typeID]?.category == .filter } }
                    clip.effects.append(d.makeInstance())
                    p.timeline[clip: c.id] = clip
                }
            })
        }
    }

    /// Applies a transition after the selected main-track clip (or the cut nearest the playhead).
    public func applyTransition(_ d: TransitionDescriptor) {
        guard let main = project.timeline.mainTrack, main.clips.count > 1 else { showToast(tr("toast.needTwoClips"), error: true); return }
        let sel = selectedClips.first { c in main.clips.contains { $0.id == c.id } }
        let target = sel ?? main.clips.dropLast().min { abs(($0.end - transport.playhead).ticks) < abs(($1.end - transport.playhead).ticks) }
        guard let target, target.id != main.clips.last?.id else { return }
        perform(SetTransition(target.id, d.makeInstance()))
    }

    // MARK: Timeline commands

    public func splitAtPlayhead() {
        perform(SplitClips(Array(selection), at: transport.playhead))
    }

    public func deleteSelection() {
        guard !selection.isEmpty else { return }
        perform(DeleteClips(selection))
        selection = []
    }

    /// CapCut Q / W: trim the selected clip's start/end to the playhead.
    public func trimSelection(_ edge: TrimEdge) {
        guard let c = singleSelectedClip ?? project.timeline.tracks.flatMap({ $0.clips(at: transport.playhead) }).first else { return }
        perform(TrimClip(c.id, edge: edge, to: transport.playhead))
    }

    public func setOption(_ o: SetTimelineOption.Option) { perform(SetTimelineOption(o)) }

    public func zoom(by factor: Double) { pixelsPerSecond = min(max(pixelsPerSecond * factor, 2), 1200) }

    public func zoomToFit(width: Double) {
        let d = max(project.duration.seconds, 5)
        pixelsPerSecond = min(max((width - 120) / d, 2), 1200)
    }

    // MARK: Transport

    public func togglePlay() { engine.togglePlay() }
    public func seek(to t: Time, exact: Bool = true) { engine.seek(to: t, exact: exact) }
    public func step(frames: Int) { engine.step(frames: frames) }

    /// J / K / L shuttle (repeated J/L doubles the speed, K stops).
    public func shuttle(_ key: Character) {
        switch key {
        case "k": engine.pause()
        case "l": engine.setRate(engine.player.rate > 0 ? min(engine.player.rate * 2, 8) : 1)
        case "j": engine.setRate(engine.player.rate < 0 ? max(engine.player.rate * 2, -8) : -1)
        default: break
        }
    }

    // MARK: Persistence

    public var projectName: String { project.name.isEmpty ? (packageURL?.deletingPathExtension().lastPathComponent ?? tr("project.untitled")) : project.name }

    /// Saves to the current package (creating one in the drafts folder if needed).
    public func save() {
        if packageURL == nil {
            packageURL = MontagePaths.newProjectURL(baseName: projectName)
            SessionLock.acquire(packageURL!)
        }
        write(to: packageURL!)
    }

    public func saveAs(_ url: URL) {
        if let old = packageURL { SessionLock.release(old) }
        packageURL = url
        SessionLock.acquire(url)
        write(to: url)
    }

    private func write(to url: URL) {
        do {
            try ProjectPackage.save(project, to: url)
            session.markSaved()
            lastAutosave = Date()
            firstUnsavedEdit = nil
        } catch {
            showToast(tr("toast.saveFailed"), error: true)
        }
    }

    public func open(_ url: URL) throws {
        let p = try ProjectPackage.load(from: url)
        if let old = packageURL { SessionLock.release(old) }
        let crashed = SessionLock.acquire(url)
        packageURL = url
        session.reset(p)
        selection = []
        engine.update(project: p, force: true)
        engine.seek(to: .zero)
        Task { await ProxyManager.shared.request(p.media) }
        if crashed { showToast(tr("toast.recovered")) }
    }

    /// Replaces the open project (new project, demo, recovery) without history.
    public func load(project p: Project, packageURL url: URL? = nil) {
        if let old = packageURL { SessionLock.release(old) }
        packageURL = url
        if let url { SessionLock.acquire(url) }
        session.reset(p)
        selection = []
        lastAutosave = nil
        engine.update(project: p, force: true)
        engine.seek(to: .zero)
        Task { await ProxyManager.shared.request(p.media) }
    }

    public func close() {
        autosaveTask?.cancel()
        if session.isDirty, packageURL != nil { save() }
        if let u = packageURL { SessionLock.release(u) }
    }

    private func scheduleAutosave() {
        guard autosaveEnabled, session.isDirty else { return }
        if firstUnsavedEdit == nil { firstUnsavedEdit = Date() }
        autosaveTask?.cancel()
        let policy = autosavePolicy
        let overdue = Date().timeIntervalSince(firstUnsavedEdit!) > Double(policy.maxInterval.components.seconds)
        autosaveTask = Task { [weak self] in
            if !overdue { try? await Task.sleep(for: policy.idleDelay) }
            guard !Task.isCancelled, let self, !self.session.isInGesture else { return }
            let snapshot = self.project
            let url = self.packageURL ?? MontagePaths.newProjectURL(baseName: self.projectName)
            if self.packageURL == nil { self.packageURL = url; SessionLock.acquire(url) }
            let rev = self.session.revision
            let ok = await Task.detached { (try? ProjectPackage.save(snapshot, to: url)) != nil }.value
            if ok && self.session.revision == rev { self.session.markSaved(); self.lastAutosave = Date(); self.firstUnsavedEdit = nil }
        }
    }

    // MARK: Export

    public func startExport(settings: ExportSettings, to url: URL) {
        exportState = .running(0)
        let project = self.project
        exportTask = Task { [weak self] in
            do {
                try await Exporter.export(project: project, settings: settings, to: url) { p in
                    Task { @MainActor in if case .running = self?.exportState { self?.exportState = .running(p) } }
                }
                self?.exportState = .done(url)
            } catch let e as ExportError {
                if case .cancelled = e { self?.exportState = .idle } else { self?.exportState = .failed(tr(e.messageKey)) }
            } catch {
                self?.exportState = .failed(error.localizedDescription)
            }
        }
    }

    public func cancelExport() { exportTask?.cancel() }

    // MARK: AI

    public func runAITool(_ tool: AIToolDescriptor) {
        let input = AIToolInput(project: project, clipID: singleSelectedClip?.id, language: L10n.shared.language)
        Task {
            guard await tool.isAvailable() else { showToast(tr("ai.error.unavailable"), error: true); return }
            let box = OutputBox()
            let id = await JobQueue.shared.enqueue(titleKey: tool.nameKey, priority: 1, subject: input.clipID?.description) { progress in
                box.output = try await tool.run(input, progress)
            }
            let state = await JobQueue.shared.wait(id)
            switch state {
            case .done:
                if case .edit(let cmd) = box.output { perform(cmd) }
                showToast(tr("toast.aiDone", tr(tool.nameKey)))
            case .failed:
                showToast(tr("ai.error.unavailable"), error: true)
            default: break
            }
        }
    }

    // MARK: Toasts

    public func showToast(_ message: String, error: Bool = false) {
        let t = Toast(message: message, isError: error)
        toast = t
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            if self?.toast == t { self?.toast = nil }
        }
    }

    // MARK: Observation for AppKit views

    /// Calls `apply` now and again whenever an observed property it read changes (main actor).
    public func observe(_ apply: @escaping @MainActor () -> Void) {
        withObservationTracking { apply() } onChange: { [weak self] in
            Task { @MainActor in self?.observe(apply) }
        }
    }
}

nonisolated final class OutputBox: @unchecked Sendable { var output: AIToolOutput = .none }
