import SwiftUI
import Perception
import ValseCore
import ValseEffects
import ValseEngine
import ValseAI

/// Observable mirror of `L10n` so SwiftUI re-renders on language change. The root view uses `revision` as its
/// identity, so switching language rebuilds the tree with the new strings (no relaunch).
@Perceptible
public final class LocaleState {
    public static let shared = LocaleState()
    public private(set) var revision = 0
    public var language: String { L10n.shared.language }
    @PerceptionIgnored private var token: (any NSObjectProtocol)?

    init() {
        token = NotificationCenter.default.addObserver(forName: L10n.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LocaleState.shared.revision += 1 }
        }
    }
}

/// Registers every module's string bundle. Call once at startup (and in UI tests).
public enum ValseBootstrap {
    nonisolated(unsafe) private static var done = false
    public static func registerResources() {
        guard !done else { return }
        done = true
        EffectsResources.register()
        EngineResources.register()
        AIResources.register()
        UIResources.register()
        LUTLibrary.shared.loadAll()   // imported LUTs → effect registry
        UserStickerLibrary.shared.loadAll()   // imported custom stickers → sticker registry (ST-003)
        CustomEffectLibrary.shared.loadAll()  // FX-018 custom effect packages → effect registry
        // custom effect names are per language (manifest name / name_fr): re-register on a language switch
        NotificationCenter.default.addObserver(forName: L10n.didChange, object: nil, queue: .main) { _ in
            CustomEffectLibrary.shared.loadAll()
        }
    }
}

public enum UIResources {
    public static let bundle: Bundle = ResourceBundleLocator.find("Valse_ValseUI", fallback: .module)
    public static func register() { L10n.shared.register(bundle) }
}

extension Text {
    /// `Text(loc: "panel.player")` — localized through `L10n`.
    public init(loc key: String, _ args: any CVarArg...) { self.init(verbatim: L10n.shared.string(key, args)) }
}
