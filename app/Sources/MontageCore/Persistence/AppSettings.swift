import Foundation

/// App-wide preferences (Settings window, SE-001…). Persisted as JSON in
/// `~/Library/Application Support/Montage/settings.json`.
///
/// Forward/backward compatible by construction: `decode` overlays the stored keys on the encoded defaults, so new
/// fields get their default and unknown (newer) fields are ignored — no migration step needed for additions.
/// Engine-typed values (preview quality, proxy policy, codecs) are stored as their raw strings; MontageUI maps them.
public struct AppSettings: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version = AppSettings.currentVersion

    // MARK: General
    /// Export-finished system notification (SE-012).
    public var notifyOnExport = true
    /// Play a sound when an export finishes (CapCut "Sound for export").
    public var exportSound = false

    // MARK: Project
    /// Folder new projects are saved in (nil = ~/Movies/Montage). CapCut "Save to".
    public var projectsDirectory: String?
    /// Auto-delete cache files not used for this many days (nil = never; CapCut "Don't delete cache files").
    public var cacheAutoDeleteDays: Int?
    /// Import material: copy files into the project package, or keep them in place (CapCut default).
    public var copyMediaOnImport = false

    // MARK: Edit
    /// Default duration of a still image on the timeline (s). CapCut: 5.0.
    public var imageDuration = 5.0
    /// Default duration of a newly applied transition (s). nil = each transition's own default.
    public var transitionDuration: Double?
    /// Default length of a freeze frame (s). CapCut: 3.
    public var freezeDuration = 3.0
    /// "Link freeze frame clips to original video" (TL-013): looks edited on the original follow its freeze frames.
    public var linkFreezeFrames = true
    /// Media bin lists media used only inside subprojects (SE-010 "Show media from subprojects").
    public var showSubprojectMedia = true
    /// "Step forward or back many frames" (⇧← / ⇧→). CapCut: 10.
    public var stepFrames = 10
    /// "Adjust value many units" (⇧ + arrows in numeric fields). CapCut: 10.
    public var valueStep = 10
    /// Frame rate of new projects (numerator/denominator).
    public var defaultFrameRateNum: Int32 = 30
    public var defaultFrameRateDen: Int32 = 1
    /// Ratio of new projects ("original" follows the first clip, CapCut default).
    public var defaultRatio = "original"
    /// Time code display: "frames" (HH:MM:SS:FF, CapCut default) or "seconds" (HH:MM:SS.ms).
    public var timecodeStyle = "frames"
    /// Drop-frame time code (HH:MM:SS;FF) for 29.97 / 59.94 fps projects.
    public var dropFrame = false
    /// Mouse (SE-016): plain mouse-wheel direction on the timeline, "vertical" (tracks) or "horizontal" (time).
    public var mouseWheelScroll = "vertical"
    /// Mouse (SE-016): modifier that makes scrolling zoom the timeline: "command" (default), "option", "none".
    public var mouseZoomModifier = "command"
    /// Play audio while scrubbing (CapCut default off).
    public var scrubAudio = false

    // MARK: Audio (SE-011 / AU-024)
    /// Preview output device UID (nil = system default).
    public var audioOutputDeviceUID: String?
    /// Default voice-over input device UID (nil = system default).
    public var audioInputDeviceUID: String?
    /// Preview monitor ("master") volume 0…1; never affects export.
    public var monitorVolume = 1.0

    // MARK: Performance
    /// `PreviewQuality` raw value ("auto", "full", "half", "quarter").
    public var previewQuality = "auto"
    /// Use proxies in the preview (player ☰ ▸ Proxy).
    public var useProxies = true
    /// `ProxyManager.Policy` raw value ("auto", "always", "never").
    public var proxyPolicy = "auto"
    /// Proxy short side in px: 540 / 720 / 1080 (MI-008).
    public var proxyResolution = 720
    /// "Only convert material above proxy resolution" (CapCut default on).
    public var proxyOnlyAbove = true
    /// Speed up hardware encoding (export uses VideoToolbox when available).
    public var hardwareEncoding = true
    /// Speed up hardware decoding.
    public var hardwareDecoding = true
    /// EX-016 "Faster exporting, but may have color differences": the hardware encoder favours speed over quality.
    public var fastExport = false
    /// Cache folder (nil = ~/Library/Caches/Montage). Takes effect after a restart.
    public var cacheDirectory: String?
    /// Render cache cap ("Auto clear [10] GB").
    public var renderCacheLimitGB = 10.0
    /// Pre-render heavy parts of the timeline in the background ("Auto render").
    public var autoRender = false
    /// Auto optimization when playback drops frames: "none" (CapCut default), "smart", "deep" (PB-003).
    public var autoOptimization = "none"
    /// Playback priority: "quality" or "performance" (PB-004).
    public var playbackPriority = "quality"

    // MARK: Export defaults
    /// `ExportSettings.Codec` raw value.
    public var exportCodec = "h264"
    /// Export short side in px (`ExportSettings.Resolution` raw value); 0 = follow the project.
    public var exportResolution = 0
    /// Export frame rate; 0 = follow the project.
    public var exportFrameRate = 0.0
    /// `ExportSettings.BitrateMode` raw value.
    public var exportBitrate = "recommended"
    /// Default export folder (nil = ~/Movies).
    public var exportDirectory: String?

    // MARK: Labs (C4)
    /// How "Remove filler words" applies: "instant" (cut at once, undo toast), "review" (checklist + Remove N, default),
    /// "inline" (highlighted words in the transcript, click to keep / drop, then Apply). `FillerRemovalStyle`.
    public var fillerRemovalStyle = "review"

    public init() {}

    public var defaultFrameRate: FrameRate {
        get { defaultFrameRateNum > 0 && defaultFrameRateDen > 0 ? FrameRate(defaultFrameRateNum, defaultFrameRateDen) : .fps30 }
        set { defaultFrameRateNum = newValue.numerator; defaultFrameRateDen = newValue.denominator }
    }

    /// Time code display the UI reads (`TimecodeDisplay.current`).
    public var timecodeDisplay: TimecodeDisplay {
        TimecodeDisplay(style: TimecodeStyle(rawValue: timecodeStyle) ?? .frames, dropFrame: dropFrame)
    }

    /// Edit defaults the model layer reads (`EditDefaults.current`).
    public var editDefaults: EditDefaults {
        EditDefaults(imageDuration: Time(max(0.1, imageDuration)), transitionDuration: transitionDuration.map { Time(max(0.1, $0)) },
                     freezeDuration: Time(max(0.1, freezeDuration)), stepFrames: max(1, stepFrames), linkFreeze: linkFreezeFrames)
    }

    // MARK: Persistence

    public static var defaultURL: URL { MontagePaths.supportDirectory.appendingPathComponent("settings.json") }

    public static func decode(_ data: Data) -> AppSettings {
        guard let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as? [String: Any]
        else { return AppSettings() }
        var merged = base
        for (k, v) in stored where base[k] != nil || v is NSNull == false { merged[k] = v }
        guard let d = try? JSONSerialization.data(withJSONObject: merged),
              var s = try? JSONDecoder().decode(AppSettings.self, from: d) else {
            // a stored value of the wrong type: fall back field-wise to defaults by dropping offending keys
            return lenientDecode(stored, base: base)
        }
        s.version = currentVersion
        return s
    }

    private static func lenientDecode(_ stored: [String: Any], base: [String: Any]) -> AppSettings {
        var merged = base
        for (k, v) in stored {
            var trial = merged
            trial[k] = v
            if let d = try? JSONSerialization.data(withJSONObject: trial), (try? JSONDecoder().decode(AppSettings.self, from: d)) != nil {
                merged = trial
            }
        }
        let d = try! JSONSerialization.data(withJSONObject: merged)
        return (try? JSONDecoder().decode(AppSettings.self, from: d)) ?? AppSettings()
    }

    public static func load(from url: URL = defaultURL) -> AppSettings {
        guard let d = try? Data(contentsOf: url) else { return AppSettings() }
        return decode(d)
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        try e.encode(self).write(to: url, options: .atomic)
    }
}

/// Editing defaults used by the model layer (image duration on insert, freeze length, "many frames" step, transition
/// length). Set from `AppSettings` at launch and whenever settings are saved. Thread-safe.
public struct EditDefaults: Sendable, Equatable {
    public var imageDuration: Time = Time(5)
    public var transitionDuration: Time?
    public var freezeDuration: Time = Time(3)
    public var stepFrames: Int = 10
    /// New freeze frames are linked to their original clip (TL-013).
    public var linkFreeze = true

    public init(imageDuration: Time = Time(5), transitionDuration: Time? = nil, freezeDuration: Time = Time(3), stepFrames: Int = 10,
                linkFreeze: Bool = true) {
        self.imageDuration = imageDuration; self.transitionDuration = transitionDuration
        self.freezeDuration = freezeDuration; self.stepFrames = stepFrames; self.linkFreeze = linkFreeze
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _current = EditDefaults()
    public static var current: EditDefaults {
        get { lock.withLock { _current } }
        set { lock.withLock { _current = newValue } }
    }
}
