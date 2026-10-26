import Foundation
import Perception

/// Automatic updates (SE-015): the UI side. The updater itself (Sparkle) lives in MontageApp and plugs in through
/// `UpdateController.Backend`; MontageUI, its tests and UI scripts never link Sparkle. Without a backend (swift run,
/// UI tests, a build without a feed URL) the controller reports `isAvailable == false` and the About panel says so.
///
/// Behaviour (owner decisions 2026-10-26): no polling; the backend checks at launch, after wake and when a release push
/// arrives. Background checks are silent (no network = nothing shown), an update found downloads quietly and installs
/// when Montage quits; the `UpdateBanner` offers "Restart to update" meanwhile. Only a check started by the user
/// ("Check for updates") reports its result, inline in Settings ▸ About.
@MainActor @Perceptible
public final class UpdateController {
    public static let shared = UpdateController()

    /// What Sparkle (or a test double) does for the controller.
    @MainActor public protocol Backend: AnyObject {
        /// Launch / wake / push checks (Settings ▸ About switch).
        var automaticallyChecks: Bool { get set }
        var lastCheck: Date? { get }
        /// User-initiated check: results come back through `UpdateController.state`.
        func checkNow()
    }

    public enum State: Equatable {
        case idle
        case checking
        case upToDate
        /// Downloading the update (fraction 0…1 when known).
        case downloading(version: String, progress: Double?)
        /// Downloaded and verified: installs on quit, or now via `installNow`.
        case ready(version: String)
        /// Only after a user-initiated check (background failures stay silent).
        case failed(message: String)
    }

    public var state: State = .idle
    /// The banner was dismissed for this ready version ("Later"): it stays hidden until another version is ready.
    public var bannerDismissedFor: String?
    @PerceptionIgnored public private(set) var backend: Backend?
    @PerceptionIgnored private var installer: (@MainActor () -> Void)?
    /// Bumped when backend settings change, so views reading them re-render.
    private var revision = 0

    public init() {}

    public func attach(_ backend: Backend) {
        self.backend = backend
        revision += 1
    }

    public var isAvailable: Bool { _ = revision; return backend != nil }

    public var automaticallyChecks: Bool {
        get { _ = revision; return backend?.automaticallyChecks ?? false }
        set { backend?.automaticallyChecks = newValue; revision += 1 }
    }

    public var lastCheck: Date? { _ = revision; return backend?.lastCheck }

    public func checkNow() {
        guard let backend else { return }
        if case .ready = state { return }
        state = .checking
        backend.checkNow()
    }

    /// Called by the backend once an update is downloaded; `install` quits, installs and relaunches.
    public func updateReady(version: String, install: @escaping @MainActor () -> Void) {
        installer = install
        state = .ready(version: version)
    }

    /// "Restart to update": the normal quit path runs (project saved, background jobs stopped), then Sparkle installs.
    public func installNow() { installer?() }

    public var showsBanner: Bool {
        if case .ready(let v) = state { return bannerDismissedFor != v }
        return false
    }

    /// Backend finished a check (any kind): records it for "Last checked".
    public func checkFinished() { revision += 1 }

    /// Screenshots (`--ui-state update=<v>`): an offline backend with `v` downloaded; installing does nothing.
    func preview(readyVersion v: String) {
        if backend == nil { attach(PreviewBackend(controller: self)) }
        updateReady(version: v) {}
    }
}

/// Backend for screenshots and tests: no network, checks answer "up to date".
@MainActor final class PreviewBackend: UpdateController.Backend {
    var automaticallyChecks = true
    var lastCheck: Date?
    var checks = 0
    weak var controller: UpdateController?
    init(controller: UpdateController) { self.controller = controller }
    func checkNow() {
        checks += 1
        lastCheck = Date()
        guard let c = controller else { return }
        if c.state == .checking { c.state = .upToDate }
        c.checkFinished()
    }
}
