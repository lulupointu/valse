import Foundation
import MontageCore
import MontageEffects
import MontageEngine

// MARK: - Planner

/// Turns a chat instruction into `PilotAction`s: Apple Foundation Models when Apple Intelligence is on, else the local
/// Qwen3-4B sidecar (llama.cpp), else — and whenever the model's reply can't be parsed — the rule-based planner.
public enum EditPilotPlanner {
    public enum Engine: String, Sendable { case foundationModels, localLLM, rules
        public var nameKey: String { "pilot.engine.\(rawValue)" }
    }

    public static var engine: Engine {
        if OnDeviceLLM.hasFoundationModels { return .foundationModels }
        if LlamaRuntime.isAvailable { return .localLLM }
        return .rules
    }

    public struct Plan: Sendable {
        public var actions: [PilotAction]
        public var engine: Engine
        public var reply: String
    }

    /// `history`: earlier user requests of the conversation (oldest first), so "faster" can refer to them.
    public static func plan(_ request: String, project: Project, selection: Set<ClipID>, history: [String] = [],
                            useModel: Bool = true) async -> Plan {
        let e = useModel ? engine : .rules
        if e != .rules {
            let prompt = (history.suffix(3).map { "Earlier request: \($0)" } + ["Request: \(request)"]).joined(separator: "\n")
            if let reply = try? await OnDeviceLLM.respond(prompt, instructions: instructions(project, selection: selection),
                                                          temperature: 0.1, maxTokens: 400),
               let actions = PilotCallParser.parse(reply) {
                if !actions.isEmpty { return Plan(actions: PilotRules.reconcile(actions, request: request), engine: e, reply: reply) }
                let rules = PilotRules.plan(request)
                return Plan(actions: rules, engine: rules.isEmpty ? e : .rules, reply: reply)
            }
        }
        return Plan(actions: PilotRules.plan(request), engine: .rules, reply: "")
    }

    /// System prompt: the typed tool list + a compact project summary. Kept short for a 3–4 B model.
    static func instructions(_ p: Project, selection: Set<ClipID>) -> String {
        let transitions = PilotCatalog.promptTransitions.joined(separator: ", ")
        return """
        You are EditPilot, the editing agent of a video editor. Turn the user's request (English or French) into tool calls.
        Reply with ONLY a JSON array of tool calls, no prose. Each call is {"tool": "<name>", ...arguments}. Reply [] if nothing matches.
        Only use these tools:
        - remove_silences {"min_pause": seconds, default 0.8}: cut silent pauses on the main track.
        - remove_fillers {}: cut filler words (um, uh, euh) and repetitions.
        - add_captions {"language": spoken language code or null, "translate_to": language code or null}
        - set_aspect {"ratio": "16:9"|"9:16"|"1:1"|"4:3"|"3:4"|"4:5"|"2.35:1", "fill": true}: square / carré = 1:1, vertical = 9:16, horizontal = 16:9.
        - set_speed {"factor": 0.1-10, "scope": "all"|"selected"}
        - speed_up_quiet {"factor": default 2}: speed up quiet, static (boring) parts instead of cutting them.
        - add_transitions {"transition": one of [\(transitions)], "duration": seconds}: between every clip of the main track.
        - apply_filter {"filter": filter name, "intensity": 0-100, "scope": "all"|"selected"}
        - apply_effect {"effect": effect name, "scope": "all"|"selected"}
        - fade {"seconds": 1}: fade in at the start and out at the end (video and audio).
        - volume {"db": number, "scope": "all"|"selected"} · mute {"scope": ...}
        - reduce_noise {"scope": ...} · enhance_voice {"scope": ...} · normalize_loudness {"scope": ...}
        - add_title {"text": string, "seconds": 3}
        - fit_duration {"seconds": number}: make the whole video that long by changing its speed.
        - stabilize {"scope": ...}
        Project: \(summary(p, selection: selection)).
        """
    }

    static func summary(_ p: Project, selection: Set<ClipID>) -> String {
        let main = p.timeline.mainTrack?.clips ?? []
        let captions = SpeechCaptions.captions(in: p.timeline).count
        let music = p.timeline.tracks.filter { $0.kind == .audio }.flatMap(\.clips).count
        return String(format: "%d clips on the main track, %.1f s, ratio %@, %d captions, %d audio clips, %d selected clips",
                      main.count, p.timeline.duration.seconds, p.settings.aspectPreset, captions, music, selection.count)
    }
}

// MARK: - Executor

public struct PilotStepResult: Sendable, Identifiable, Equatable {
    public let id: Int
    public let action: PilotAction
    /// Localized result ("4 silences removed (−6.2 s)"), nil when the step changed nothing.
    public let detail: String?
    public let changed: Bool
    public init(id: Int, action: PilotAction, detail: String?, changed: Bool) {
        self.id = id; self.action = action; self.detail = detail; self.changed = changed
    }
}

public struct PilotExecution: Sendable {
    public let before: Project
    public let after: Project
    public let results: [PilotStepResult]
    public var changed: Bool { before != after }
}

/// Phases reported while a plan is prepared.
public enum PilotPhase: String, Sendable {
    case analyzing, transcribing, measuring, applying
    public var titleKey: String { "pilot.phase.\(rawValue)" }
}

/// Runs a plan on a project snapshot: gathers what the steps need (activity profiles, transcripts, loudness — cached
/// per media, each heavy model loaded one at a time and released), then applies every step in order to a working copy.
/// The UI previews the result and commits it as ONE undo step ("EditPilot").
public enum EditPilotExecutor {
    public static func ordered(_ actions: [PilotAction]) -> [PilotAction] {
        actions.enumerated().sorted { ($0.element.phase, $0.offset) < ($1.element.phase, $1.offset) }.map(\.element)
    }

    public static func run(_ actions: [PilotAction], project: Project, selection: Set<ClipID> = [],
                           progress: (@Sendable (Double) -> Void)? = nil,
                           phase: (@Sendable (PilotPhase) -> Void)? = nil) async throws -> PilotExecution {
        let steps = ordered(actions)
        var ctx = PilotContext()
        ctx.selection = selection
        // 1. analyses (progress 0 … 0.85)
        let needsActivity = steps.contains(where: \.needsActivity)
        let needsTranscript = steps.contains(where: \.needsTranscript)
        let needsLoudness = steps.contains { if case .normalizeLoudness = $0 { return true }; return false }
        let parts = Double([needsActivity, needsTranscript, needsLoudness].filter { $0 }.count)
        var base = 0.0
        func sub(_ f: Double) -> Double { parts == 0 ? 0 : 0.85 * (base + f) / parts }
        if needsActivity {
            phase?(.analyzing)
            let assets = uniqueAssets(PilotOps.mainMediaClips(project), project)
            for (i, a) in assets.enumerated() {
                try Task.checkCancellation()
                let b = base
                ctx.activity[a.id] = try await ActivityAnalyzer.shared.profile(a) { f in
                    progress?(parts == 0 ? 0 : 0.85 * (b + (Double(i) + f) / Double(max(assets.count, 1))) / parts)
                }
            }
            base += 1
        }
        if needsTranscript {
            phase?(.transcribing)
            let lang = steps.lazy.compactMap { if case .addCaptions(let l, _) = $0 { return l }; return nil }.first
            let b = base
            ctx.transcripts = try await PilotTranscripts.load(project, language: lang) { f in
                progress?(parts == 0 ? 0 : 0.85 * (b + f) / parts)
            }
            base += 1
        }
        if needsLoudness {
            phase?(.measuring)
            let scopes = steps.compactMap { if case .normalizeLoudness(let s) = $0 { return s }; return nil }
            let ids = Set(scopes.flatMap { PilotOps.targets($0, project, ctx, visual: false) })
            for (i, id) in ids.enumerated() {
                try Task.checkCancellation()
                guard let c = project.timeline.clip(id), let a = c.mediaID.flatMap(project.asset) else { continue }
                ctx.loudness[id] = try? await AudioAnalysis.loudness(url: a.url, range: c.sourceRange)
                progress?(sub(Double(i + 1) / Double(ids.count)))
            }
            base += 1
        }
        // 2. apply (0.85 … 1)
        phase?(.applying)
        var working = project
        var results: [PilotStepResult] = []
        for (i, step) in steps.enumerated() {
            try Task.checkCancellation()
            var p = working
            var detail: String?
            do {
                switch step {
                case .addCaptions(_, let target):
                    detail = try PilotOps.apply(step, to: &p, context: ctx)
                    if detail != nil, let target { detail = await translate(&p, to: target).map { "\(detail!) · \($0)" } ?? detail }
                default:
                    detail = try PilotOps.apply(step, to: &p, context: ctx)
                }
                if !TimelineOps.validate(p.timeline).isEmpty { detail = nil; p = working }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                detail = nil; p = working
            }
            let changed = p != working
            working = p
            results.append(PilotStepResult(id: i, action: step, detail: changed ? detail : nil, changed: changed))
            progress?(0.85 + 0.15 * Double(i + 1) / Double(max(steps.count, 1)))
        }
        return PilotExecution(before: project, after: working, results: results)
    }

    static func uniqueAssets(_ clips: [Clip], _ p: Project) -> [MediaAsset] {
        var seen = Set<MediaID>(), out: [MediaAsset] = []
        for c in clips { if let id = c.mediaID, seen.insert(id).inserted, let a = p.asset(id) { out.append(a) } }
        return out
    }

    /// Bilingual captions with an installed language pair (no OS download prompt from a background job).
    static func translate(_ p: inout Project, to target: String) async -> String? {
        let caps = SpeechCaptions.captions(in: p.timeline)
        guard let source = PilotOps.captionLanguage(p.timeline), source != target else { return nil }
        guard await CaptionTranslator.status(from: source, to: target) == .installed,
              let map = try? await CaptionTranslator.translate(caps.map { ($0.id, CaptionOps.text($0)?.string ?? "") }, from: source, to: target),
              !map.isEmpty else {
            return tr("pilot.result.translationMissing", PilotLanguages.title(target))
        }
        SpeechCaptions.setTranslations(map, display: .both, in: &p.timeline)
        return tr("pilot.result.translated", PilotLanguages.title(target))
    }
}

/// Transcripts of every audible media range of a project, disfluencies kept (one transcript per media, cached per
/// range in `TranscriptStore`, whisper.cpp → Apple Speech fallback like Auto captions).
public enum PilotTranscripts {
    public static func load(_ p: Project, language: String?, progress: (@Sendable (Double) -> Void)? = nil) async throws -> [MediaID: Transcript] {
        let clips = CaptionGenerator.sourceClips(p, .allTracks)
        var ranges: [MediaID: [TimeRange]] = [:]
        for c in clips { ranges[c.mediaID!, default: []].append(c.sourceRange) }
        let jobs: [(MediaAsset, TimeRange)] = ranges.flatMap { mid, rs -> [(MediaAsset, TimeRange)] in
            guard let a = p.asset(mid) else { return [] }
            return CaptionGenerator.merge(rs, pad: Time(0.5), limit: a.duration).map { (a, $0) }
        }
        let total = max(jobs.reduce(0.0) { $0 + $1.1.duration.seconds }, 0.001)
        var done = 0.0
        var out: [MediaID: Transcript] = [:]
        for (asset, range) in jobs {
            try Task.checkCancellation()
            let key = TranscriptStore.key(hash: asset.contentHash, range: range, language: language, engine: .automatic, fillers: true)
            let frac = range.duration.seconds / total
            let t: Transcript
            if let cached = TranscriptStore.shared.get(key) {
                t = cached
            } else {
                let wav = try await AudioExtractor.wav16k(asset.url, range: range)
                defer { try? FileManager.default.removeItem(at: wav) }
                if AudioExtractor.isSilent(wav) {
                    t = Transcript(engine: "silence", language: language ?? "", words: [])
                } else {
                    let b = done
                    t = try await Transcriber.transcribe(wav: wav, request: .init(language: language, keepFillers: true)) { f in
                        progress?(b + f * frac)
                    }.shifted(by: range.start.seconds)
                }
                TranscriptStore.shared.put(t, key)
            }
            done += frac
            progress?(done)
            if var prev = out[asset.id] {
                prev.words = (prev.words + t.words).sorted { $0.start < $1.start }
                if prev.language.isEmpty { prev.language = t.language }
                out[asset.id] = prev
            } else {
                out[asset.id] = t
            }
        }
        return out
    }
}

// MARK: - Diff

/// What a plan changes, for the plan card ("Duration 42.0 s → 31.5 s").
public struct PilotDiffRow: Sendable, Identifiable, Equatable {
    public var id: String { key }
    public let key: String
    public let before: String
    public let after: String
}

public enum PilotDiff {
    public static func rows(_ a: Project, _ b: Project) -> [PilotDiffRow] {
        var out: [PilotDiffRow] = []
        func add(_ key: String, _ x: String, _ y: String) { if x != y { out.append(PilotDiffRow(key: key, before: x, after: y)) } }
        add("pilot.diff.duration", PilotFormat.duration(a.timeline.duration.seconds), PilotFormat.duration(b.timeline.duration.seconds))
        add("pilot.diff.ratio", a.settings.aspectPreset, b.settings.aspectPreset)
        add("pilot.diff.mainClips", "\(a.timeline.mainTrack?.clips.count ?? 0)", "\(b.timeline.mainTrack?.clips.count ?? 0)")
        add("pilot.diff.captions", "\(SpeechCaptions.captions(in: a.timeline).count)", "\(SpeechCaptions.captions(in: b.timeline).count)")
        let tr0 = a.timeline.allClips.filter { $0.transitionOut != nil }.count, tr1 = b.timeline.allClips.filter { $0.transitionOut != nil }.count
        add("pilot.diff.transitions", "\(tr0)", "\(tr1)")
        add("pilot.diff.effects", "\(a.timeline.allClips.reduce(0) { $0 + $1.effects.count })", "\(b.timeline.allClips.reduce(0) { $0 + $1.effects.count })")
        add("pilot.diff.tracks", "\(a.timeline.tracks.count)", "\(b.timeline.tracks.count)")
        return out
    }
}
