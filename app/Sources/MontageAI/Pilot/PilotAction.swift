import Foundation
import MontageCore
import MontageEffects

// EditPilot (AI-048): an on-device editing agent. The language model (Apple Foundation Models, else the local Qwen
// sidecar, else the rule-based planner) only ever produces calls of this small, typed, validated command API; each
// action maps to existing editor operations (TimelineOps, CaptionOps, clip properties) and the whole plan is applied
// as ONE undo step. Nothing here can touch files, the network or anything outside the project.

/// Which clips an action applies to.
public enum PilotScope: String, Codable, Sendable, CaseIterable {
    /// Every clip of the main track (and, for audio actions, every clip with audio).
    case all
    /// The clips selected in the timeline (falls back to `all` when nothing is selected).
    case selected
}

public enum PilotAction: Hashable, Codable, Sendable {
    case removeSilences(minPause: Double)
    case removeFillers
    /// Auto captions; `translateTo` adds bilingual captions (skipped when it is the spoken language).
    case addCaptions(language: String?, translateTo: String?)
    case setAspect(ratio: String, fill: Bool)
    case setSpeed(factor: Double, scope: PilotScope)
    /// Speeds up the quiet, low-motion ("boring") parts of the main track instead of cutting them.
    case speedUpQuiet(factor: Double)
    case addTransitions(typeID: String, duration: Double)
    case applyFilter(typeID: String, intensity: Double, scope: PilotScope)
    case applyEffect(typeID: String, scope: PilotScope)
    /// Video + audio fade in at the start and out at the end of the video.
    case fade(seconds: Double)
    case volume(db: Double, scope: PilotScope)
    case mute(scope: PilotScope)
    case reduceNoise(scope: PilotScope)
    case enhanceVoice(scope: PilotScope)
    case normalizeLoudness(scope: PilotScope)
    case addTitle(text: String, seconds: Double)
    /// Changes the main track's speed so the video lasts `seconds`.
    case fitDuration(seconds: Double)
    case stabilize(scope: PilotScope)

    /// Execution order: cuts first, then timing, structure, looks, audio, fades, captions (on the final timeline), titles.
    public var phase: Int {
        switch self {
        case .removeSilences, .removeFillers: return 0
        case .speedUpQuiet, .setSpeed: return 1
        case .addTransitions: return 2
        case .fitDuration: return 3
        case .setAspect, .applyFilter, .applyEffect, .stabilize: return 4
        case .volume, .mute, .reduceNoise, .enhanceVoice, .normalizeLoudness: return 5
        case .fade: return 6
        case .addCaptions: return 7
        case .addTitle: return 9
        }
    }

    /// Needs the transcript (speech recognition) of the media.
    public var needsTranscript: Bool {
        switch self { case .removeFillers, .addCaptions: return true; default: return false }
    }
    /// Needs the audio/motion activity profile of the media.
    public var needsActivity: Bool {
        switch self { case .removeSilences, .speedUpQuiet: return true; default: return false }
    }

    public var symbol: String {
        switch self {
        case .removeSilences: return "waveform.badge.minus"
        case .removeFillers: return "text.badge.minus"
        case .addCaptions: return "captions.bubble"
        case .setAspect: return "aspectratio"
        case .setSpeed, .speedUpQuiet, .fitDuration: return "speedometer"
        case .addTransitions: return "rectangle.on.rectangle.angled"
        case .applyFilter: return "camera.filters"
        case .applyEffect: return "sparkles"
        case .fade: return "circle.lefthalf.filled"
        case .volume: return "speaker.wave.2"
        case .mute: return "speaker.slash"
        case .reduceNoise, .enhanceVoice: return "waveform"
        case .normalizeLoudness: return "chart.bar"
        case .addTitle: return "textformat"
        case .stabilize: return "camera.metering.center.weighted"
        }
    }

    /// Localized one-line description of the planned step (plan card).
    public var summary: String {
        let scope: (PilotScope) -> String = { tr("pilot.scope.\($0.rawValue)") }
        switch self {
        case .removeSilences(let m): return tr("pilot.step.removeSilences", PilotFormat.seconds(m))
        case .removeFillers: return tr("pilot.step.removeFillers")
        case .addCaptions(let l, let t):
            let spoken = l.map { PilotLanguages.title($0) } ?? tr("captions.autoDetect")
            if let t { return tr("pilot.step.addCaptionsTranslated", spoken, PilotLanguages.title(t)) }
            return tr("pilot.step.addCaptions", spoken)
        case .setAspect(let r, let fill): return tr(fill ? "pilot.step.setAspectFill" : "pilot.step.setAspect", r)
        case .setSpeed(let f, let s): return tr("pilot.step.setSpeed", PilotFormat.factor(f), scope(s))
        case .speedUpQuiet(let f): return tr("pilot.step.speedUpQuiet", PilotFormat.factor(f))
        case .addTransitions(let id, let d): return tr("pilot.step.addTransitions", PilotCatalog.transitionName(id), PilotFormat.seconds(d))
        case .applyFilter(let id, let i, let s): return tr("pilot.step.applyFilter", PilotCatalog.effectName(id), Int(i.rounded()), scope(s))
        case .applyEffect(let id, let s): return tr("pilot.step.applyEffect", PilotCatalog.effectName(id), scope(s))
        case .fade(let s): return tr("pilot.step.fade", PilotFormat.seconds(s))
        case .volume(let db, let s): return tr("pilot.step.volume", PilotFormat.db(db), scope(s))
        case .mute(let s): return tr("pilot.step.mute", scope(s))
        case .reduceNoise(let s): return tr("pilot.step.reduceNoise", scope(s))
        case .enhanceVoice(let s): return tr("pilot.step.enhanceVoice", scope(s))
        case .normalizeLoudness(let s): return tr("pilot.step.normalizeLoudness", scope(s))
        case .addTitle(let text, let s): return tr("pilot.step.addTitle", text, PilotFormat.seconds(s))
        case .fitDuration(let s): return tr("pilot.step.fitDuration", PilotFormat.duration(s))
        case .stabilize(let s): return tr("pilot.step.stabilize", scope(s))
        }
    }
}

/// Caption languages the agent understands (same list as the Auto captions panel).
public enum PilotLanguages {
    public static let codes = ["fr", "en", "es", "de", "it", "pt", "nl", "ja", "zh", "ko"]
    public static func title(_ code: String) -> String {
        (Locale(identifier: L10n.shared.language).localizedString(forLanguageCode: code) ?? code).capitalized
    }
}

enum PilotFormat {
    static func seconds(_ s: Double) -> String { String(format: "%.1f", locale: L10n.shared.locale, s) }
    static func factor(_ f: Double) -> String {
        f == f.rounded() ? String(format: "%.0f×", f) : String(format: "%.1f×", locale: L10n.shared.locale, f)
    }
    static func db(_ d: Double) -> String { String(format: "%+.0f dB", d) }
    static func duration(_ s: Double) -> String {
        s >= 60 ? String(format: "%d:%02d", Int(s) / 60, Int(s.rounded()) % 60) : tr("pilot.secondsUnit", seconds(s))
    }
}

/// Transitions / filters / effects the agent may use, resolved by id, English or French name (fuzzy, accent- and
/// case-insensitive) so a model's "black and white" or "noir et blanc" lands on a registry id.
public enum PilotCatalog {
    public static let defaultTransition = "montage.transition.dissolve"

    /// Names (en + fr) of a registry item.
    static func names(nameKey: String) -> [String] {
        ["en", "fr"].compactMap { L10n.shared.strings(for: $0)[nameKey] }
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Best match of `query` among (id, names); exact id / name first, then containment, then word overlap.
    static func match(_ query: String, in items: [(id: String, names: [String])]) -> String? {
        let q = fold(query)
        guard !q.isEmpty else { return nil }
        if let hit = items.first(where: { $0.id == query }) { return hit.id }
        let short = items.map { (id: $0.id, short: fold(String($0.id.split(separator: ".").last ?? "")), names: $0.names.map(fold)) }
        if let hit = short.first(where: { $0.short == q.replacingOccurrences(of: " ", with: "") || $0.names.contains(q) }) { return hit.id }
        if let hit = short.first(where: { s in s.names.contains { $0.contains(q) } || (q.count >= 4 && s.short.contains(q.replacingOccurrences(of: " ", with: ""))) }) { return hit.id }
        let qw = Set(q.split(separator: " ").map(String.init).filter { $0.count > 2 })
        guard !qw.isEmpty else { return nil }
        let scored = short.map { s -> (String, Int) in
            let w = Set(s.names.flatMap { $0.split(separator: " ").map(String.init) })
            return (s.id, qw.intersection(w).count)
        }.filter { $0.1 > 0 }.max { $0.1 < $1.1 }
        return scored?.0
    }

    public static func transitionID(_ query: String) -> String? {
        let synonyms: [String: String] = ["fade": "dissolve", "crossfade": "dissolve", "cross fade": "dissolve", "fondu": "dissolve",
                                          "fondu enchaine": "dissolve", "black": "blackFade", "noir": "blackFade",
                                          "fade to black": "blackFade", "fondu au noir": "blackFade", "white": "whiteFade",
                                          "blanc": "whiteFade", "flash": "whiteFade"]
        let q = fold(query)
        let items = Registries.transitions.all.map { (id: $0.id, names: names(nameKey: $0.nameKey)) }
        if let s = synonyms[q], let hit = items.first(where: { $0.id.hasSuffix(".\(s)") }) { return hit.id }
        return match(query, in: items)
    }

    public static func effectID(_ query: String, filter: Bool) -> String? {
        let synonyms: [String: String] = ["black and white": "mono", "noir et blanc": "mono", "b&w": "mono", "n&b": "mono",
                                          "monochrome": "mono", "grayscale": "mono", "greyscale": "mono", "niveaux de gris": "mono"]
        if filter, let s = synonyms[fold(query)], let d = Registries.effects.all.first(where: { $0.nameKey == "filter.\(s)" }) { return d.id }
        let items = Registries.effects.all.filter { filter ? $0.category == .filter : ($0.category != .filter) }
            .map { (id: $0.id, names: names(nameKey: $0.nameKey)) }
        return match(query, in: items)
    }

    static func transitionName(_ id: String) -> String { Registries.transitions[id].map { tr($0.nameKey) } ?? id }
    static func effectName(_ id: String) -> String { Registries.effects[id].map { tr($0.nameKey) } ?? id }

    /// A short list for the language model prompt.
    static var promptTransitions: [String] {
        ["dissolve", "blackFade", "whiteFade", "slideLeft", "zoomIn", "blur", "wipeLeft"].filter { n in
            Registries.transitions.all.contains { $0.id == "montage.transition.\(n)" }
        }
    }
}

/// Parses the language model's tool calls (`[{"tool": "remove_silences", "min_pause": 0.8}, …]`) into validated
/// actions: unknown tools and unresolvable names are dropped, numbers are clamped to sane ranges.
public enum PilotCallParser {
    public static func parse(_ text: String) -> [PilotAction]? {
        guard let json = extractJSON(text), let data = json.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let list: [[String: Any]]
        if let a = any as? [[String: Any]] { list = a }
        else if let d = any as? [String: Any], let a = (d["calls"] ?? d["tools"] ?? d["actions"]) as? [[String: Any]] { list = a }
        else if let d = any as? [String: Any], d["tool"] != nil { list = [d] }
        else { return nil }
        return list.compactMap(action)
    }

    /// The JSON array/object inside a reply (code fences / prose around it are ignored).
    static func extractJSON(_ s: String) -> String? {
        guard let start = s.firstIndex(where: { $0 == "[" || $0 == "{" }) else { return nil }
        let open = s[start], close: Character = open == "[" ? "]" : "}"
        guard let end = s.lastIndex(of: close), end > start else { return nil }
        return String(s[start...end])
    }

    static func action(_ d: [String: Any]) -> PilotAction? {
        let args = (d["arguments"] as? [String: Any]) ?? (d["args"] as? [String: Any]) ?? d
        guard let rawName = (d["tool"] ?? d["name"] ?? d["function"]) as? String else { return nil }
        let name = rawName.lowercased().replacingOccurrences(of: "-", with: "_")
        func num(_ k: String) -> Double? {
            if let v = args[k] as? Double { return v }
            if let v = args[k] as? Int { return Double(v) }
            if let s = args[k] as? String { return Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: CharacterSet(charactersIn: " xs%"))) }
            return nil
        }
        func str(_ k: String) -> String? { (args[k] as? String).flatMap { $0.isEmpty || $0 == "null" ? nil : $0 } }
        func scope() -> PilotScope { str("scope").flatMap { PilotScope(rawValue: $0.lowercased()) } ?? .all }
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
        func lang(_ k: String) -> String? {
            guard let s = str(k)?.lowercased() else { return nil }
            let map = ["french": "fr", "français": "fr", "francais": "fr", "english": "en", "anglais": "en", "spanish": "es",
                       "espagnol": "es", "german": "de", "allemand": "de", "italian": "it", "italien": "it", "portuguese": "pt"]
            let code = map[s] ?? String(s.prefix(2))
            return PilotLanguages.codes.contains(code) ? code : nil
        }
        switch name {
        case "remove_silences", "cut_silences": return .removeSilences(minPause: clamp(num("min_pause") ?? 0.8, 0.3, 5))
        case "remove_fillers", "remove_filler_words": return .removeFillers
        case "add_captions", "captions": return .addCaptions(language: lang("language"), translateTo: lang("translate_to"))
        case "set_aspect", "set_ratio", "aspect_ratio":
            guard let r = str("ratio").flatMap(PilotRules.normalizeRatio) else { return nil }
            return .setAspect(ratio: r, fill: (args["fill"] as? Bool) ?? true)
        case "set_speed", "speed": return num("factor").map { .setSpeed(factor: clamp($0, 0.1, 10), scope: scope()) }
        case "speed_up_quiet", "speed_up_boring": return .speedUpQuiet(factor: clamp(num("factor") ?? 2, 1.25, 8))
        case "add_transitions", "add_transition", "transitions":
            let id = str("transition").flatMap(PilotCatalog.transitionID) ?? PilotCatalog.defaultTransition
            return .addTransitions(typeID: id, duration: clamp(num("duration") ?? 0.5, 0.1, 3))
        case "apply_filter", "filter":
            guard let id = str("filter").flatMap({ PilotCatalog.effectID($0, filter: true) }) else { return nil }
            return .applyFilter(typeID: id, intensity: clamp(num("intensity") ?? 100, 0, 100), scope: scope())
        case "apply_effect", "effect":
            guard let id = str("effect").flatMap({ PilotCatalog.effectID($0, filter: false) }) else { return nil }
            return .applyEffect(typeID: id, scope: scope())
        case "fade", "fade_in_out": return .fade(seconds: clamp(num("seconds") ?? 1, 0.2, 5))
        case "volume", "set_volume": return num("db").map { .volume(db: clamp($0, -40, 20), scope: scope()) }
        case "mute": return .mute(scope: scope())
        case "reduce_noise": return .reduceNoise(scope: scope())
        case "enhance_voice": return .enhanceVoice(scope: scope())
        case "normalize_loudness": return .normalizeLoudness(scope: scope())
        case "add_title", "title":
            guard let t = str("text") else { return nil }
            return .addTitle(text: String(t.prefix(120)), seconds: clamp(num("seconds") ?? 3, 0.5, 30))
        case "fit_duration": return num("seconds").map { .fitDuration(seconds: clamp($0, 1, 3600)) }
        case "stabilize": return .stabilize(scope: scope())
        default: return nil
        }
    }
}
