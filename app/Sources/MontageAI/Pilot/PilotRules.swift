import Foundation
import MontageCore

/// Rule-based planner for English and French instructions: the EditPilot fallback when no language model is installed
/// (and the deterministic path used by tests). Splits the request into clauses ("…, then …", "… et …") and maps each
/// to one action by keywords and numbers.
public enum PilotRules {
    public static func plan(_ request: String) -> [PilotAction] {
        var out: [PilotAction] = []
        for clause in clauses(request) {
            for a in actions(in: clause) where !out.contains(a) { out.append(a) }
        }
        return out
    }

    /// Lower-cased, accent-folded text with straight apostrophes.
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    static func clauses(_ s: String) -> [String] {
        // keep quoted titles intact while splitting
        var parts: [String] = []
        var cur = "", quote: Character?
        let chars = Array(s)
        var i = 0
        func flush() { let t = cur.trimmingCharacters(in: .whitespaces); if !t.isEmpty { parts.append(t) }; cur = "" }
        while i < chars.count {
            let c = chars[i]
            if let q = quote { cur.append(c); if c == q || (q == "«" && c == "»") || (q == "“" && c == "”") { quote = nil }; i += 1; continue }
            if c == "\"" || c == "«" || c == "“" { quote = c; cur.append(c); i += 1; continue }
            // "1,5 s" / "0.8 s" are decimals, not clause breaks
            let decimal = (c == "," || c == ".") && i > 0 && i + 1 < chars.count && chars[i - 1].isNumber && chars[i + 1].isNumber
            if !decimal && (c == "," || c == ";" || c == "." || c == "\n") { flush(); i += 1; continue }
            cur.append(c); i += 1
        }
        flush()
        // then on connectives
        let connectives = [" and then ", " then ", " puis ", " ensuite ", " and ", " et ", " also ", " aussi "]
        var result: [String] = []
        for p in parts {
            var pieces = [" " + p + " "]
            for c in connectives {
                pieces = pieces.flatMap { piece -> [String] in
                    // never split inside quotes or "black and white" / "noir et blanc"
                    let f = fold(piece)
                    if f.contains("\"") || f.contains("«") || f.contains("black and white") || f.contains("noir et blanc") { return [piece] }
                    return piece.components(separatedBy: c)
                }
            }
            result += pieces.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return result
    }

    static func has(_ s: String, _ words: [String]) -> Bool { words.contains { s.contains($0) } }

    /// First number in the text (comma or dot decimals).
    static func number(_ s: String, before units: [String]? = nil) -> Double? {
        let pattern = units.map { "([0-9]+(?:[.,][0-9]+)?)\\s*(?:\($0.joined(separator: "|")))(?![a-z])" } ?? "([0-9]+(?:[.,][0-9]+)?)"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s) else { return nil }
        return Double(s[r].replacingOccurrences(of: ",", with: "."))
    }

    static func factor(_ s: String) -> Double? {
        if let x = number(s, before: ["x", "×", "fois", "times"]) { return x }
        if let re = try? NSRegularExpression(pattern: "(?:x|×)\\s*([0-9]+(?:[.,][0-9]+)?)"),
           let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s) {
            return Double(s[r].replacingOccurrences(of: ",", with: "."))
        }
        if let p = number(s, before: ["%"]) { return 1 + p / 100 }
        if has(s, ["double", "twice", "deux fois"]) { return 2 }
        return nil
    }

    static func scope(_ s: String) -> PilotScope {
        has(s, ["selected", "selection", "this clip", "ce clip", "le clip selectionne", "clip selectionne", "these clips", "ces clips"]) ? .selected : .all
    }

    /// "9:16", "9/16", "9x16", "16 9" → a ratio id of `ProjectSettings.aspectPresets`.
    public static func normalizeRatio(_ s: String) -> String? {
        let f = fold(s)
        if let re = try? NSRegularExpression(pattern: "([0-9]+(?:[.,][0-9]+)?)\\s*[:/x×]\\s*([0-9]+)"),
           let m = re.firstMatch(in: f, range: NSRange(f.startIndex..., in: f)),
           let a = Range(m.range(at: 1), in: f), let b = Range(m.range(at: 2), in: f) {
            let id = "\(f[a].replacingOccurrences(of: ",", with: ".")):\(f[b])"
            if ProjectSettings.presetSize(id) != nil { return id }
        }
        if has(f, ["vertical", "portrait", "tiktok", "reel", "short", "story", "stories"]) { return "9:16" }
        if has(f, ["square", "carre", "instagram post"]) { return "1:1" }
        if has(f, ["horizontal", "landscape", "paysage", "youtube", "widescreen"]) { return "16:9" }
        if has(f, ["cinema", "cinemascope"]) { return "2.35:1" }
        return nil
    }

    static func language(_ s: String) -> String? {
        let table: [(String, [String])] = [
            ("fr", ["french", "francais", " fr "]), ("en", ["english", "anglais", " en anglais", " en "]),
            ("es", ["spanish", "espagnol"]), ("de", ["german", "allemand"]), ("it", ["italian", "italien"]),
            ("pt", ["portuguese", "portugais"]), ("nl", ["dutch", "neerlandais"]), ("ja", ["japanese", "japonais"]),
            ("zh", ["chinese", "chinois"]), ("ko", ["korean", "coreen"]),
        ]
        let padded = " \(s) "
        for (code, words) in table where words.contains(where: { w in
            // " en " alone is French for "in": only count it as English after "captions/sous-titres … en anglais"
            w == " en " ? false : padded.contains(w)
        }) { return code }
        return nil
    }

    static func quoted(_ s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "[\"«“]\\s*([^\"»”]+?)\\s*[\"»”]"),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func actions(in clause: String) -> [PilotAction] {
        let s = fold(clause)
        let sc = scope(s)
        var out: [PilotAction] = []
        let speedUp = ["speed up", "faster", "accelere", "accelerer", "plus vite", "plus rapide", "rapid"]
        let boring = ["boring", "dull", "quiet", "slow part", "dead time", "ennuy", "calme", "temps mort", "passages lents", "longueur", "mou"]

        // silences / pauses (before the "boring" rule: "cut the silences" ≠ "speed up the silences")
        if has(s, ["silence", "pause", "blancs", "dead air"]) && !has(s, speedUp) {
            out.append(.removeSilences(minPause: number(s, before: ["s", "sec", "second", "seconde"]).map { min(max($0, 0.3), 5) } ?? 0.8))
        }
        if has(s, ["filler", " um", " uh", "hesitation", "tics", "tic de langage", "euh", "mots parasites", "repetition"]) {
            out.append(.removeFillers)
        }
        // captions / subtitles
        if has(s, ["caption", "subtitle", "sous-titre", "sous titre", "soustitre", "legende", "transcri"]) {
            let lang = language(s)
            if has(s, ["translat", "tradui", "bilingu"]) {
                out.append(.addCaptions(language: nil, translateTo: lang))
            } else {
                // "add captions in French": CapCut-style target language → translated if the speech isn't French
                out.append(.addCaptions(language: nil, translateTo: lang))
            }
        }
        if has(s, ["keyword", "mot-cle", "mot cle", "mots cles", "mots-cles"]) { out.append(.highlightKeywords) }
        // aspect ratio
        if let r = normalizeRatio(s), has(s, ["ratio", "format", "aspect", "make it", "en ", "mets", "passe", "convert", "resize",
                                                 "redimension", "turn", "vertical", "portrait", "square", "carre", "horizontal",
                                                 "paysage", "tiktok", "reel", "short", ":", "/"]) {
            out.append(.setAspect(ratio: r, fill: !has(s, ["letterbox", "bandes noires", "black bars", "fit", "sans recadr"])))
        }
        // speed
        if has(s, speedUp) && has(s, boring + ["silence", "pause"]) {
            out.append(.speedUpQuiet(factor: factor(s).map { min(max($0, 1.25), 8) } ?? 2))
        } else if has(s, speedUp) || (has(s, ["speed", "vitesse"]) && factor(s) != nil) {
            out.append(.setSpeed(factor: min(max(factor(s) ?? 1.5, 0.1), 10), scope: sc))
        } else if has(s, ["slow down", "slow motion", "slow-mo", "ralenti", "ralentis", "plus lent"]) {
            out.append(.setSpeed(factor: min(max(factor(s).map { $0 > 1 ? 1 / $0 : $0 } ?? 0.5, 0.1), 1), scope: sc))
        }
        // fit to a duration: "make it 1 min", "a 30 second video", "une vidéo d'une minute"
        if has(s, ["long", "duree", "dure", "minute", "min ", "second", "seconde", " sec", "fit", "make it", "turn", "en "]),
           !has(s, ["silence", "pause", "transition", "fondu", "fade", "titre", "title"]),
           let d = duration(s) {
            out.append(.fitDuration(seconds: d))
        }
        // transitions vs fades
        let between = has(s, ["between", "entre", "transition", "each clip", "chaque clip", "every clip", "cuts", "coupes", "enchaine"])
        if has(s, ["transition", "crossfade", "cross-fade", "dissolve", "fondu enchaine"]) || (between && has(s, ["fade", "fondu"])) {
            var name = "dissolve"
            for (k, v) in [("black", "blackFade"), ("noir", "blackFade"), ("white", "whiteFade"), ("blanc", "whiteFade"),
                           ("slide", "slideLeft"), ("gliss", "slideLeft"), ("zoom", "zoomIn"), ("blur", "blur"), ("flou", "blur"),
                           ("wipe", "wipeLeft"), ("balay", "wipeLeft")] where s.contains(k) { name = v; break }
            let id = PilotCatalog.transitionID(name) ?? PilotCatalog.defaultTransition
            out.append(.addTransitions(typeID: id, duration: number(s, before: ["s", "sec", "second", "seconde"]).map { min(max($0, 0.1), 3) } ?? 0.5))
        } else if has(s, ["fade", "fondu"]) {
            out.append(.fade(seconds: number(s, before: ["s", "sec", "second", "seconde"]).map { min(max($0, 0.2), 5) } ?? 1))
        }
        // looks
        if has(s, ["filter", "filtre", "black and white", "noir et blanc", "vintage", "sepia", "warm", "chaud", "cinematic", "cinema"]),
           !has(s, ["remove filter", "supprime le filtre"]) {
            let q = filterQuery(s)
            if let id = PilotCatalog.effectID(q, filter: true) {
                out.append(.applyFilter(typeID: id, intensity: number(s, before: ["%"]).map { min(max($0, 0), 100) } ?? 100, scope: sc))
            }
        }
        if has(s, ["stabili"]) { out.append(.stabilize(scope: sc)) }
        // audio
        if has(s, ["mute", "muet", "coupe le son", "couper le son", "sans le son", "silent"]) && !out.contains(where: { if case .removeSilences = $0 { return true }; return false }) {
            out.append(.mute(scope: sc))
        } else if has(s, ["louder", "plus fort", "monte le son", "augmente le volume", "volume up", "increase the volume", "raise the volume"]) {
            out.append(.volume(db: number(s, before: ["db"]) ?? 6, scope: sc))
        } else if has(s, ["quieter", "moins fort", "baisse le son", "baisse le volume", "lower the volume", "volume down", "reduce the volume", "decrease the volume"]) {
            out.append(.volume(db: -(number(s, before: ["db"]).map(abs) ?? 6), scope: sc))
        }
        if has(s, ["noise", "bruit", "souffle", "hiss"]) { out.append(.reduceNoise(scope: sc)) }
        if has(s, ["enhance voice", "enhance the voice", "voice clearer", "clearer voice", "ameliore la voix", "ameliorer la voix", "voix plus claire"]) {
            out.append(.enhanceVoice(scope: sc))
        }
        if has(s, ["normaliz", "normalis", "loudness", "niveau sonore", "same volume", "meme volume", "volume constant"]) {
            out.append(.normalizeLoudness(scope: sc))
        }
        // title
        if has(s, ["title", "titre", "intro text", "texte d'intro"]), let text = quoted(clause) {
            out.append(.addTitle(text: String(text.prefix(120)), seconds: number(fold(clause.replacingOccurrences(of: text, with: "")), before: ["s", "sec", "second", "seconde"]) ?? 3))
        }
        return out
    }

    /// "1 min", "90 seconds", "une minute", "30s" → seconds.
    static func duration(_ s: String) -> Double? {
        if let m = number(s, before: ["min", "minute", "minutes", "mn"]) { return m * 60 }
        if let sec = number(s, before: ["s", "sec", "secs", "second", "seconds", "seconde", "secondes"]) { return sec }
        if has(s, ["one minute", "a minute", "une minute", "1 minute", "d'une minute", "dune minute"]) { return 60 }
        if has(s, ["half a minute", "demi-minute", "demi minute"]) { return 30 }
        return nil
    }

    static func filterQuery(_ s: String) -> String {
        if has(s, ["black and white", "noir et blanc", "b&w", "monochrome", "n&b"]) { return "black and white" }
        var q = s
        for w in ["apply", "add", "use", "put", "a ", "the ", "filter", "filtre", "applique", "ajoute", "mets", "un ", "le ", "la ",
                  "to all clips", "a tous les clips", "on everything", "partout", "please", "stp", "s'il te plait"] {
            q = q.replacingOccurrences(of: w, with: " ")
        }
        q = q.replacingOccurrences(of: "[0-9]+\\s*%", with: " ", options: .regularExpression)
        return q.split(separator: " ").joined(separator: " ")
    }
}
