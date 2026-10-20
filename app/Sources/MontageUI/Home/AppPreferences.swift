import Foundation
import Perception
import MontageCore
import MontageEngine

/// The app settings on the main actor (Settings window). Applying them pushes values to the places that use them:
/// `EditDefaults` (model), `ProxyManager.policy`, the open editor (preview quality, proxies), path overrides
/// (`MontagePaths`), render-cache limits, export defaults (`exportDefaults(for:)`).
@MainActor @Perceptible
public final class AppPreferences {
    public static let shared = AppPreferences(url: AppSettings.defaultURL)

    public private(set) var settings: AppSettings
    @PerceptionIgnored let url: URL?
    /// Editor to keep in sync (preview quality / proxies), set by `AppModel`.
    @PerceptionIgnored weak var store: EditorStore?

    public init(url: URL?) {
        self.url = url
        settings = url.map { AppSettings.load(from: $0) } ?? AppSettings()
        applyGlobals()
    }

    /// Replaces the settings (Settings ▸ Save), persists and applies them.
    public func update(_ new: AppSettings) {
        let old = settings
        if old.projectsDirectory != new.projectsDirectory { ProjectLibrary.shared.keepProjectsListed() }
        settings = new
        if let url { try? new.save(to: url) }
        applyGlobals()
        if let store { apply(to: store, previous: old) }
    }

    public func edit(_ body: (inout AppSettings) -> Void) {
        var s = settings
        body(&s)
        if s != settings { update(s) }
    }

    private func applyGlobals() {
        EditDefaults.current = settings.editDefaults
        TimecodeDisplay.current = settings.timecodeDisplay
        ProxyManager.shared.policy = ProxyManager.Policy(rawValue: settings.proxyPolicy) ?? .auto
        ProxyManager.shared.resolution = [540, 720, 1080].contains(settings.proxyResolution) ? settings.proxyResolution : 720
        ProxyManager.shared.onlyAboveResolution = settings.proxyOnlyAbove
        let s = settings
        ExportDialogModel.firstExportDefaults = { p in
            (Self.exportDefaults(s, for: p), s.exportDirectory.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) })
        }
        guard !HomeSandbox.isActive else { return }  // never touch the user's path overrides from a sandbox
        let d = UserDefaults.standard
        d.set(settings.hardwareEncoding, forKey: ExportDialogModel.hardwareDefaultsKey)
        d.set(settings.hardwareEncoding && settings.fastExport, forKey: ExportDialogModel.fastEncodingDefaultsKey)
        d.set(settings.exportSound, forKey: ExportQueue.soundDefaultsKey)
        d.set(settings.notifyOnExport, forKey: ExportQueue.notifyDefaultsKey)
        if let p = settings.projectsDirectory, !p.isEmpty { d.set(p, forKey: MontagePaths.draftsOverrideKey) } else { d.removeObject(forKey: MontagePaths.draftsOverrideKey) }
        if let p = settings.cacheDirectory, !p.isEmpty { d.set(p, forKey: MontagePaths.cacheOverrideKey) } else { d.removeObject(forKey: MontagePaths.cacheOverrideKey) }
    }

    /// Pushes the performance settings to an editor (on launch and when they change).
    func apply(to store: EditorStore, previous: AppSettings? = nil) {
        let q = PreviewQuality(rawValue: settings.previewQuality) ?? .auto
        if store.previewQuality != q { store.previewQuality = q }
        if store.playerUI.usesProxies != settings.useProxies { store.setUsesProxies(settings.useProxies) }
        let perf = settings.playbackPriority == PlaybackPriority.performance.rawValue
        if PlaybackEngine.performancePriority != perf { PlaybackEngine.performancePriority = perf; store.engine.forceRebuild() }
        // Settings ▸ Audio: preview output device + monitor volume (a missing device falls back to the default)
        let uid = AudioDevices.id(forUID: settings.audioOutputDeviceUID, in: AudioDevices.outputs()) != nil ? settings.audioOutputDeviceUID : nil
        if store.engine.player.audioOutputDeviceUniqueID != uid { store.engine.player.audioOutputDeviceUniqueID = uid }
        store.engine.player.volume = Float(min(max(settings.monitorVolume, 0), 1))
        if previous?.proxyPolicy != settings.proxyPolicy || previous?.proxyOnlyAbove != settings.proxyOnlyAbove { Task { await ProxyManager.shared.request(store.project.media) } }
    }

    /// The editor changed preview quality / proxies from the player menu: remember it.
    func noteEditorPerformance(quality: PreviewQuality, usesProxies: Bool) {
        guard settings.previewQuality != quality.rawValue || settings.useProxies != usesProxies else { return }
        var s = settings
        s.previewQuality = quality.rawValue
        s.useProxies = usesProxies
        settings = s
        if let url { try? s.save(to: url) }
    }

    /// Export dialog defaults (Settings ▸ Export) for a project.
    public func exportDefaults(for project: Project) -> ExportSettings { Self.exportDefaults(settings, for: project) }

    public nonisolated static func exportDefaults(_ settings: AppSettings, for project: Project) -> ExportSettings {
        var e = ExportSettings()
        e.codec = ExportSettings.Codec(rawValue: settings.exportCodec) ?? e.codec
        e.bitrateMode = ExportSettings.BitrateMode(rawValue: settings.exportBitrate) ?? e.bitrateMode
        e.preferHardware = settings.hardwareEncoding
        e.fastEncoding = settings.hardwareEncoding && settings.fastExport
        e.frameRate = settings.exportFrameRate > 0 ? Self.frameRate(settings.exportFrameRate) : project.settings.frameRate
        let short = min(project.settings.canvasSize.width, project.settings.canvasSize.height)
        if settings.exportResolution > 0, let r = ExportSettings.Resolution(rawValue: settings.exportResolution) {
            e.resolution = r
        } else {
            e.resolution = ExportSettings.Resolution.allCases.last { Double($0.rawValue) <= short } ?? .p1080
        }
        return e
    }

    public var exportDirectory: URL {
        if let p = settings.exportDirectory, !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
    }

    nonisolated static func frameRate(_ fps: Double) -> FrameRate {
        FrameRate.common.min { abs($0.fps - fps) < abs($1.fps - fps) } ?? .fps30
    }

    /// Settings for a new project (Settings ▸ Edit ▸ frame rate / ratio).
    public func newProjectSettings() -> ProjectSettings {
        var s = ProjectSettings()
        s.frameRate = settings.defaultFrameRate
        s.aspectPreset = settings.defaultRatio
        if let size = ProjectSettings.presetSize(settings.defaultRatio) { s.canvasSize = size }
        return s
    }
}

/// Clears caches through the engine objects that own them (they also keep in-memory "ready" lists).
@MainActor
public enum CacheCleaner {
    static func clear(_ c: CacheManager.Category) {
        switch c {
        case .proxies: ProxyManager.shared.deleteAll()
        case .render: RenderCache.shared.deleteAll()
        case .converted: PlayableMediaCache.shared.deleteAll()
        case .reversed: ReverseManager.shared.deleteAll()
        case .audio: AudioRenderCache.shared.purge()
        default: CacheManager().clear(c)
        }
    }

    /// Categories that are safe to clear while a project is open (pure caches re-created on demand).
    static let safeWhileEditing: Set<CacheManager.Category> = [.thumbs, .waveforms, .render, .other]

    /// "Clear cache" for one project (Home ▸ … ▸ Clear cache): every cache item of its media.
    static func clear(project hashes: Set<String>) {
        let touched = CacheManager().clear(hashes: hashes)
        // engine caches with ready lists forget everything (cheap: they rescan or regenerate)
        for c in touched where [.proxies, .converted, .reversed, .audio].contains(c) { forgetOnly(c) }
    }

    private static func forgetOnly(_ c: CacheManager.Category) {
        // `deleteAll` also deletes the other projects' items; reload the remaining ones by re-reading the folder.
        // Engine caches re-validate files lazily, so a full reset is only needed for proxies/conversions.
        switch c {
        case .proxies: ProxyManager.shared.reloadFromDisk()
        case .converted: PlayableMediaCache.shared.reloadFromDisk()
        default: break
        }
    }

    /// Settings ▸ "Auto delete cache N days ago" and "Auto clear N GB" (run at launch, off-main for the file walk).
    public static func runAutomaticCleanup(_ s: AppSettings) {
        let days = s.cacheAutoDeleteDays, limit = Int64(s.renderCacheLimitGB * 1_073_741_824)
        Task.detached(priority: .utility) {
            let m = CacheManager()
            if let days { m.purge(olderThan: days) }
            m.enforceLimit(limit, category: .render)
            await MainActor.run {
                ProxyManager.shared.reloadFromDisk()
                PlayableMediaCache.shared.reloadFromDisk()
            }
        }
    }
}
