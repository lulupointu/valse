import Foundation
import MontageCore
import MontageEngine

/// Why speech recognition (auto captions, lyrics, script alignment) could not produce words, in terms the user can act
/// on (BUG-CAPTION-ERRORS, docs/ux error-writing guide). Engines throw these instead of strings; the panel maps each
/// case to a title / body (`message`) and up to two buttons (`remedies`). Internal details (exit codes, error domains,
/// engine names) go to `EngineLog`, never into the message.
public enum SpeechFailure: Error, Sendable, Equatable {
    /// The chosen source has no enabled, unmuted clip with sound. `trackChosen`: a specific track (or the main track)
    /// was selected rather than All tracks.
    case nothingToCaption(trackChosen: Bool)
    /// A source file was moved, deleted or is on a drive that isn't connected.
    case mediaOffline(name: String, media: MediaID?)
    /// The file has no readable audio stream.
    case noSoundInFile(name: String)
    /// Nothing was recognised. `language`: the spoken language the user forced (nil = auto detect).
    case noSpeech(language: String?)
    /// Speech recognition permission refused in System Settings.
    case permissionDenied
    /// Speech recognition blocked by Screen Time / device management.
    case permissionRestricted
    /// No on-device Apple recognizer for that language. `canAddDictation`: macOS knows the language, adding it to
    /// Dictation (Keyboard settings) downloads the recognizer.
    case languageUnavailable(language: String, canAddDictation: Bool)
    /// High accuracy (Whisper) was chosen but the speech model isn't downloaded.
    case speechModelNeeded
    /// The speech model file can't be loaded.
    case speechModelDamaged
    /// The speech model was stopped for lack of memory.
    case notEnoughMemory
    /// The speech helper isn't in this copy of Montage, or can't run on this Mac.
    case appIncomplete
    /// No room on disk for the temporary audio.
    case diskFull
    /// Anything else (the detail is for the log and "Copy Details").
    case other(detail: String)

    /// Stable name (test hooks, state dump, l10n keys).
    public var name: String {
        switch self {
        case .nothingToCaption: return "nothingToCaption"
        case .mediaOffline: return "mediaOffline"
        case .noSoundInFile: return "noSoundInFile"
        case .noSpeech: return "noSpeech"
        case .permissionDenied: return "permissionDenied"
        case .permissionRestricted: return "permissionRestricted"
        case .languageUnavailable: return "languageUnavailable"
        case .speechModelNeeded: return "speechModelNeeded"
        case .speechModelDamaged: return "speechModelDamaged"
        case .notEnoughMemory: return "notEnoughMemory"
        case .appIncomplete: return "appIncomplete"
        case .diskFull: return "diskFull"
        case .other: return "other"
        }
    }

    /// A localized line: key + arguments (arguments are already user text: names, sizes, language names).
    public struct Line: Sendable, Equatable {
        public let key: String
        public let args: [String]
        public init(_ key: String, _ args: [String] = []) { self.key = key; self.args = args }
        public func text(_ l10n: L10n = .shared) -> String { l10n.string(key, args.map { $0 as any CVarArg }) }
    }

    public struct Message: Sendable, Equatable {
        public let title: Line
        public let body: Line
        /// Short form for a toast (panel closed).
        public let toast: Line
    }

    /// Title / body / toast lines. `uiLanguage` names the spoken language in the UI language ("French", "français");
    /// `repeated`: the same unexpected failure happened twice in a row (stop offering "Generate again").
    public func message(uiLanguage: String = L10n.shared.language, repeated: Bool = false) -> Message {
        let p = "captions.failure."
        let speechSize = Self.size(ModelCatalog.whisperTurbo.bytes)
        func m(_ c: String, _ titleArgs: [String] = [], _ bodyArgs: [String] = [], toastFromBody: Bool = false) -> Message {
            let t = Line(p + c + ".title", titleArgs), b = Line(p + c + ".body", bodyArgs)
            return Message(title: t, body: b, toast: toastFromBody ? b : t)
        }
        switch self {
        case .nothingToCaption(let track):
            return m(track ? "nothingToCaption.track" : "nothingToCaption.all", toastFromBody: true)
        case .mediaOffline(let name, _): return m("mediaOffline", [name])
        case .noSoundInFile(let name): return m("noSoundInFile", [], [name], toastFromBody: true)
        case .noSpeech(let lang):
            if let lang { return m("noSpeech.language", [], [Self.languageName(lang, uiLanguage)]) }
            return m("noSpeech")
        case .permissionDenied: return m("permissionDenied")
        case .permissionRestricted: return m("permissionRestricted", [], [speechSize])
        case .languageUnavailable(let lang, _): return m("languageUnavailable", [Self.languageName(lang, uiLanguage)], [speechSize])
        case .speechModelNeeded: return m("speechModelNeeded", [], [speechSize])
        case .speechModelDamaged: return m("speechModelDamaged")
        case .notEnoughMemory: return m("notEnoughMemory", [], [Self.size(ModelCatalog.whisperSmall.bytes)])
        case .appIncomplete: return m("appIncomplete")
        case .diskFull: return m("diskFull")
        case .other: return m(repeated ? "other.repeated" : "other", toastFromBody: true)
        }
    }

    /// Buttons, primary first (≤ 2). `helperPresent`: the speech helper is in the app (a model download can help);
    /// `modelInstalled`: a speech model is already downloaded; `updatesAvailable`: the updater is wired (packaged app).
    public func remedies(helperPresent: Bool, modelInstalled: Bool, updatesAvailable: Bool, repeated: Bool = false) -> [SpeechRemedy] {
        var r: [SpeechRemedy]
        switch self {
        case .nothingToCaption(let track): r = track ? [.useAllTracks] : []
        case .mediaOffline(_, let id): r = id.map { [.relink($0)] } ?? []
        case .noSoundInFile: r = []
        case .noSpeech(let lang): r = lang == nil ? [] : [.detectLanguage]
        case .permissionDenied:
            r = [.openSettings(.speechRecognition)]
            if helperPresent && !modelInstalled { r.append(.useSpeechModel) }
        case .permissionRestricted: r = helperPresent ? [.downloadSpeechModel] : []
        case .languageUnavailable(_, let dictation):
            r = helperPresent ? [.downloadSpeechModel] : []
            if dictation { r.append(.openSettings(.dictation)) }
        case .speechModelNeeded: r = (helperPresent ? [.downloadSpeechModel] : []) + [.useAutomatic]
        case .speechModelDamaged: r = [.redownloadSpeechModel]
        case .notEnoughMemory: r = [.useLighterModel]
        case .appIncomplete: r = updatesAvailable ? [.checkForUpdates] : []
        case .diskFull: r = [.openSettings(.storage)]
        case .other: r = repeated ? [.copyDetails] : [.retry]
        }
        return Array(r.prefix(2))
    }

    /// Without the speech helper, a failure whose fix is the speech model can only be fixed by updating Montage.
    public func resolved(helperPresent: Bool) -> SpeechFailure {
        guard !helperPresent else { return self }
        switch self {
        case .permissionRestricted, .speechModelNeeded, .speechModelDamaged, .notEnoughMemory: return .appIncomplete
        case .languageUnavailable(_, let dictation) where !dictation: return .appIncomplete
        default: return self
        }
    }

    /// When several engines failed, the reason whose fix most likely produces captions (input problems first: no
    /// engine can fix them; then disk; permission when Whisper isn't usable; downloads; damaged / memory / helper).
    public static func mostActionable(_ failures: [SpeechFailure], whisperUsable: Bool = false) -> SpeechFailure {
        func rank(_ f: SpeechFailure) -> Int {
            switch f {
            case .nothingToCaption, .mediaOffline, .noSoundInFile, .noSpeech: return 0
            case .diskFull: return 1
            case .permissionDenied: return whisperUsable ? 4 : 2
            case .speechModelNeeded, .languageUnavailable, .permissionRestricted: return 3
            case .speechModelDamaged, .notEnoughMemory: return 5
            case .appIncomplete: return 6
            case .other: return 7
            }
        }
        return failures.min { rank($0) < rank($1) } ?? .other(detail: "no engine")
    }

    /// One-line text for flows without a failure card (Shorts, script alignment): a typed reason says why and what to
    /// do; "no speech" uses `noSpeechKey`; unknown errors use `fallbackKey`.
    public static func userText(_ error: (any Error)?, fallbackKey: String, noSpeechKey: String = "ai.error.noSpeech") -> String {
        if let e = error as? AIToolError, case .noSpeech = e { return tr(noSpeechKey) }
        guard let f = error as? SpeechFailure else { return tr(fallbackKey) }
        switch f {
        case .noSpeech: return tr(noSpeechKey)
        case .other: return tr(fallbackKey)
        default:
            let m = f.message()
            return m.title.text() + ". " + m.body.text()
        }
    }

    /// Maps any error from the speech path to a reason (typed failures pass through).
    public static func classify(_ error: any Error, language: String? = nil) -> SpeechFailure {
        if let f = error as? SpeechFailure { return f }
        if let e = error as? AIToolError {
            switch e {
            case .noSpeech: return .noSpeech(language: language)
            case .noInput: return .nothingToCaption(trackChosen: false)
            case .modelMissing: return .speechModelNeeded
            case .unavailable(let d): return .other(detail: d)
            }
        }
        let ns = error as NSError
        if isDiskFull(ns) { return .diskFull }
        // SFSpeech "No speech detected" (kAFAssistantErrorDomain 1110) is thrown instead of an empty result
        if ns.domain == "kAFAssistantErrorDomain", ns.code == 1110 { return .noSpeech(language: language) }
        return .other(detail: "\(ns.domain) \(ns.code): \(ns.localizedDescription)")
    }

    static func isDiskFull(_ ns: NSError) -> Bool {
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return true }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError { return true }
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isDiskFull(u) }
        return false
    }

    /// File missing / unreachable (AVFoundation, Cocoa or POSIX flavour).
    static func isFileMissing(_ ns: NSError) -> Bool {
        if ns.domain == NSCocoaErrorDomain, [NSFileNoSuchFileError, NSFileReadNoSuchFileError, NSFileReadNoPermissionError].contains(ns.code) { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) { return true }
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorFileDoesNotExist { return true }
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isFileMissing(u) }
        return false
    }

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    /// "French" (en UI) / "français" (fr UI).
    public static func languageName(_ code: String, _ uiLanguage: String) -> String {
        Locale(identifier: uiLanguage).localizedString(forLanguageCode: code).map { uiLanguage == "en" ? $0.capitalized : $0 } ?? code
    }

    /// Every message key (l10n coverage tests).
    public static var allKeys: [String] {
        let cases = ["nothingToCaption.track", "nothingToCaption.all", "mediaOffline", "noSoundInFile", "noSpeech", "noSpeech.language",
                     "permissionDenied", "permissionRestricted", "languageUnavailable", "speechModelNeeded", "speechModelDamaged",
                     "notEnoughMemory", "appIncomplete", "diskFull", "other", "other.repeated"]
        return cases.flatMap { ["captions.failure.\($0).title", "captions.failure.\($0).body"] } + SpeechRemedy.allTitleKeys
    }

    /// One example of every case (tests, UI test hook).
    public static let samples: [SpeechFailure] = [
        .nothingToCaption(trackChosen: true), .nothingToCaption(trackChosen: false), .mediaOffline(name: "Trip.mov", media: MediaID()),
        .noSoundInFile(name: "Trip.mov"), .noSpeech(language: nil), .noSpeech(language: "fr"), .permissionDenied, .permissionRestricted,
        .languageUnavailable(language: "fr", canAddDictation: true), .languageUnavailable(language: "fr", canAddDictation: false),
        .speechModelNeeded, .speechModelDamaged, .notEnoughMemory, .appIncomplete, .diskFull, .other(detail: "test"),
    ]

    /// UI test hook spec: "<name>[:<language>]" (e.g. "languageUnavailable:fr", "noSpeech:fr", "permissionDenied").
    public static func parse(_ spec: String) -> SpeechFailure? {
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : nil
        switch parts.first ?? "" {
        case "nothingToCaption": return .nothingToCaption(trackChosen: arg == "track")
        case "mediaOffline": return .mediaOffline(name: arg ?? "Clip.mov", media: nil)
        case "noSoundInFile": return .noSoundInFile(name: arg ?? "Clip.mov")
        case "noSpeech": return .noSpeech(language: arg)
        case "permissionDenied": return .permissionDenied
        case "permissionRestricted": return .permissionRestricted
        case "languageUnavailable": return .languageUnavailable(language: arg ?? "fr", canAddDictation: false)
        case "languageUnavailableDictation": return .languageUnavailable(language: arg ?? "fr", canAddDictation: true)
        case "speechModelNeeded": return .speechModelNeeded
        case "speechModelDamaged": return .speechModelDamaged
        case "notEnoughMemory": return .notEnoughMemory
        case "appIncomplete": return .appIncomplete
        case "diskFull": return .diskFull
        case "other": return .other(detail: arg ?? "test")
        default: return nil
        }
    }
}

/// A button that fixes a `SpeechFailure` (the store performs it).
public enum SpeechRemedy: Sendable, Equatable, Hashable {
    case openSettings(SystemSettingsPane)
    /// Download the speech model, then create the captions.
    case downloadSpeechModel
    /// Same, offered as the alternative to granting permission.
    case useSpeechModel
    case redownloadSpeechModel
    case useLighterModel
    case detectLanguage
    case useAutomatic
    case useAllTracks
    case relink(MediaID)
    case checkForUpdates
    case retry
    case copyDetails

    /// Stable name (test IDs `captions.remedy.<name>`, state dump).
    public var name: String {
        switch self {
        case .openSettings(let p): return "settings.\(p.rawValue)"
        case .downloadSpeechModel: return "download"
        case .useSpeechModel: return "useSpeechModel"
        case .redownloadSpeechModel: return "redownload"
        case .useLighterModel: return "lighterModel"
        case .detectLanguage: return "detectLanguage"
        case .useAutomatic: return "useAutomatic"
        case .useAllTracks: return "allTracks"
        case .relink: return "relink"
        case .checkForUpdates: return "checkForUpdates"
        case .retry: return "retry"
        case .copyDetails: return "copyDetails"
        }
    }

    public var title: SpeechFailure.Line {
        switch self {
        case .useSpeechModel: return .init("captions.remedy.useSpeechModel", [SpeechFailure.size(ModelCatalog.whisperTurbo.bytes)])
        default: return .init("captions.remedy.\(name)")
        }
    }

    /// The speech model this remedy downloads, if any.
    public var model: AIModelSpec? {
        switch self {
        case .downloadSpeechModel, .useSpeechModel, .redownloadSpeechModel: return ModelCatalog.whisperTurbo
        case .useLighterModel: return ModelCatalog.whisperSmall
        default: return nil
        }
    }

    static var allTitleKeys: [String] {
        (["download", "useSpeechModel", "redownload", "lighterModel", "detectLanguage", "useAutomatic", "allTracks", "relink",
          "checkForUpdates", "retry", "copyDetails"] + SystemSettingsPane.allCases.map { "settings.\($0.rawValue)" })
            .map { "captions.remedy.\($0)" }
    }
}

/// System Settings panes a fix can open (macOS 13+ deep links).
public enum SystemSettingsPane: String, Sendable, CaseIterable {
    case speechRecognition, dictation, storage
    public var url: URL {
        switch self {
        case .speechRecognition: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!
        case .dictation: return URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
        case .storage: return URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!
        }
    }
}

/// What the captions panel can tell before Generate (pre-flight, `Transcriber.readiness`).
public enum SpeechReadiness: Sendable, Equatable {
    /// An engine can run.
    case ready
    /// Apple speech will ask for permission on Generate (macOS prompt).
    case needsPermissionPrompt
    /// Generate would fail for this reason: show it with its fix first.
    case blocked(SpeechFailure)

    public var name: String {
        switch self {
        case .ready: return "ready"
        case .needsPermissionPrompt: return "needsPermission"
        case .blocked(let f): return f.name
        }
    }
}

/// UI test hooks (set by the UI test driver from the script's `"speech"` block): force a failure from the caption job
/// and a readiness result, so failure cards are environment-independent.
public enum SpeechTestHooks {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _failure: SpeechFailure?
    nonisolated(unsafe) private static var _readiness: SpeechReadiness?
    nonisolated(unsafe) private static var _helper: Bool?
    /// Pretend the speech helper is (not) in the app when choosing fixes (nil = look for it).
    public static var forcedHelperPresent: Bool? {
        get { lock.withLock { _helper } }
        set { lock.withLock { _helper = newValue } }
    }
    /// Clears every override (start of a UI script).
    public static func reset() { forcedFailure = nil; forcedReadiness = nil; forcedHelperPresent = nil }

    /// "ready" / "needsPermission" / a failure spec (`SpeechFailure.parse`).
    public static func parseReadiness(_ s: String) -> SpeechReadiness? {
        switch s {
        case "ready": return .ready
        case "needsPermission": return .needsPermissionPrompt
        default: return SpeechFailure.parse(s).map { .blocked($0) }
        }
    }
    public static var forcedFailure: SpeechFailure? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }
    public static var forcedReadiness: SpeechReadiness? {
        get { lock.withLock { _readiness } }
        set { lock.withLock { _readiness = newValue } }
    }
}
