import Foundation
import ValseCore
import ValseEngine

/// Auto captions options (Text ▸ Auto captions panel, UX_AI §1.2).
public struct CaptionOptions: Sendable, Equatable {
    /// Which audio to caption ("Select the track below to generate captions").
    public enum Source: Sendable, Equatable { case allTracks, mainTrack, track(TrackID), clip(ClipID) }
    /// Spoken language, nil = Auto detect.
    public var language: String?
    public var engine: SpeechEngine
    public var source: Source
    public var settings: CaptionSettings
    /// "Delete current captions" (only offered when auto captions exist).
    public var replaceExisting: Bool
    /// Auto lyrics: recognised from music (no filler handling, longer lines).
    public var lyrics: Bool
    /// Caption look (nil = the text team's default caption style).
    public var style: TextContent?
    public init(language: String? = nil, engine: SpeechEngine = .automatic, source: Source = .allTracks,
                settings: CaptionSettings = CaptionSettings(), replaceExisting: Bool = true, lyrics: Bool = false,
                style: TextContent? = nil) {
        self.language = language; self.engine = engine; self.source = source; self.settings = settings
        self.replaceExisting = replaceExisting; self.lyrics = lyrics; self.style = style
    }
}

/// Progress phases shown by the captions sheet ("Generating captions…" → "Splitting captions…" → "Adding caption clips").
public enum CaptionPhase: String, Sendable {
    case extracting, separating, transcribing, splitting, adding
    /// The macOS speech-recognition prompt is open: "Waiting for permission…".
    case permission
    public var titleKey: String { "captions.phase.\(rawValue)" }
}

public struct CaptionResult: Sendable {
    public let command: any EditCommand
    public let count: Int
    public let language: String
    public let engine: String
    /// Where the time went (also logged).
    public var timings = CaptionTimings()
}

/// Runs speech recognition for the chosen clips and builds the undoable "Auto captions" edit. Each media range is
/// transcribed once (cached per range in `TranscriptStore`); the uncached ranges are recognised together in one engine
/// run (`CaptionBatch`, PERF-CAPTIONS-1); one heavy model at a time (whisper runs in its own process). Logs the time
/// spent per phase (`CaptionTimings`).
public enum CaptionGenerator {
    /// Clips whose audio gets captioned.
    public static func sourceClips(_ p: Project, _ source: CaptionOptions.Source) -> [Clip] {
        func hasAudio(_ c: Clip) -> Bool {
            guard let a = c.mediaID.flatMap(p.asset), a.hasAudio, !c.audio.isMuted, !c.reversed, c.isEnabled else { return false }
            return true
        }
        let tl = p.timeline
        switch source {
        case .clip(let id): return tl.clip(id).map { hasAudio($0) ? [$0] : [] } ?? []
        case .mainTrack: return (tl.mainTrack?.clips ?? []).filter(hasAudio)
        case .track(let id): return tl.trackIndex(id).map { tl.tracks[$0].clips.filter(hasAudio) } ?? []
        case .allTracks: return tl.tracks.filter { !$0.isMuted && $0.kind.acceptsMedia }.flatMap(\.clips).filter(hasAudio)
        }
    }

    public static func run(project p: Project, options o: CaptionOptions, progress: (@Sendable (Double) -> Void)? = nil,
                           phase: (@Sendable (CaptionPhase) -> Void)? = nil) async throws -> CaptionResult {
        try await run(project: p, options: o, store: .shared, progress: progress, phase: phase)
    }

    /// `store`, `recognizer`: injectable for tests (a private cache, a fake engine).
    static func run(project p: Project, options o: CaptionOptions, store: TranscriptStore,
                    recognizer: @escaping CaptionBatch.Recognizer = CaptionBatch.defaultRecognizer,
                    progress: (@Sendable (Double) -> Void)? = nil,
                    phase: (@Sendable (CaptionPhase) -> Void)? = nil) async throws -> CaptionResult {
        let started = CaptionTimings.now()
        var tm = CaptionTimings()
        let clips = sourceClips(p, o.source)
        guard !clips.isEmpty else { throw SpeechFailure.nothingToCaption(trackChosen: o.source != .allTracks) }
        if let forced = SpeechTestHooks.forcedFailure { throw forced }   // UI tests: failure cards
        let request = Transcriber.Request(language: o.language, engine: o.engine, keepFillers: o.settings.removeFillers,
                                          candidates: Self.candidates(uiLanguage: L10n.shared.language), voiceActivity: !o.lyrics)
        // merged source ranges per media, in timeline order (the joined run reads them in the order they are heard)
        var ranges: [MediaID: [TimeRange]] = [:]
        for c in clips { ranges[c.mediaID!, default: []].append(c.sourceRange) }
        var jobs: [(asset: MediaAsset, range: TimeRange, at: Time)] = ranges.flatMap { mid, rs -> [(asset: MediaAsset, range: TimeRange, at: Time)] in
            guard let a = p.asset(mid) else { return [] }
            return merge(rs, pad: Time(0.5), limit: a.duration).map { r in
                let at = clips.filter { $0.mediaID == mid && $0.sourceRange.start < r.end && $0.sourceRange.end > r.start }
                    .map(\.start).min() ?? .zero
                return (a, r, at)
            }
        }
        jobs.sort { ($0.at, $0.asset.id.description, $0.range.start) < ($1.at, $1.asset.id.description, $1.range.start) }
        tm.ranges = jobs.count
        let keepFillers = o.settings.removeFillers
        // Auto lyrics (AI-002): recognise the separated vocals, not the band
        let lyricsMethod = o.lyrics ? LyricsVocals.preferred : nil
        let keys: [String] = jobs.map { j in
            var key = TranscriptStore.key(hash: j.asset.contentHash, range: j.range, language: o.language, engine: o.engine, fillers: keepFillers)
            if let m = lyricsMethod { key += LyricsVocals.cacheSuffix(m) }
            return key
        }
        var results = [Transcript?](repeating: nil, count: jobs.count)
        // a whole-file transcript (background pre-transcription, PERF-CAPTIONS-2) serves any range of its media
        var whole: [MediaID: Transcript?] = [:]
        let whisperReady = lyricsMethod == nil && o.engine != .apple ? WhisperRuntime.isAvailable : false
        for i in jobs.indices {
            if let cached = store.get(keys[i]) { results[i] = cached; tm.cached += 1; continue }
            guard lyricsMethod == nil else { continue }
            let a = jobs[i].asset
            if whole[a.id] == nil {
                whole[a.id] = .some(PreTranscription.wholeFile(hash: a.contentHash, language: o.language, engine: o.engine,
                                                               keepFillers: keepFillers, whisperAvailable: whisperReady, store: store))
            }
            if let t = whole[a.id] ?? nil {
                results[i] = PreTranscription.slice(t, to: jobs[i].range); tm.cached += 1; tm.wholeFile += 1
            }
        }

        // 1. extraction of the uncached ranges (each to its own 16 kHz WAV); a silent one is simply left out
        let separating = (lyricsMethod ?? .none) != .none
        let extractShare = separating ? 0.45 : 0.1
        let pending = jobs.indices.filter { results[$0] == nil }
        let pendingSeconds = max(pending.reduce(0.0) { $0 + jobs[$1].range.duration.seconds }, 0.001)
        var extracted = 0.0
        var pieces: [(job: Int, wav: URL)] = []
        defer { for piece in pieces { try? FileManager.default.removeItem(at: piece.wav) } }
        for i in pending {
            try Task.checkCancellation()
            let (asset, range, _) = jobs[i]
            let frac = range.duration.seconds / pendingSeconds
            var c0 = CaptionTimings.now()
            phase?(.extracting)
            var source = PlayableURL.resolve(asset)
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw SpeechFailure.mediaOffline(name: asset.name, media: asset.id)
            }
            if let m = lyricsMethod, m != .none {
                phase?(.separating)   // AI-002 "Separating vocals…"
                let base = extracted
                let v = try await LyricsVocals.vocals(asset, method: m) { f in progress?(0.05 + extractShare * (base + f * frac)) }
                if let u = v.url { source = u }
                tm.separation += CaptionTimings.now() - c0; c0 = CaptionTimings.now()
            }
            let wav: URL
            do { wav = try await AudioExtractor.wav16k(source, range: range) }
            catch SpeechFailure.mediaOffline { throw SpeechFailure.mediaOffline(name: asset.name, media: asset.id) }
            catch SpeechFailure.noSoundInFile { throw SpeechFailure.noSoundInFile(name: asset.name) }
            tm.extraction += CaptionTimings.now() - c0; c0 = CaptionTimings.now()
            let silent = AudioExtractor.isSilent(wav)
            tm.silenceCheck += CaptionTimings.now() - c0
            if silent {
                try? FileManager.default.removeItem(at: wav)
                let t = Transcript(engine: "silence", language: o.language ?? "", words: [])
                results[i] = t; tm.silent += 1
                store.put(t, keys[i])
            } else {
                pieces.append((i, wav))
            }
            extracted += frac
            progress?(0.05 + extractShare * extracted)
        }

        // 2. one engine run over all the speech pieces (CaptionBatch), words mapped back to their range
        if !pieces.isEmpty {
            // Apple speech asks for permission once: wait for the user's answer ("Waiting for permission…")
            if Transcriber.willAskPermission(request) {
                phase?(.permission)
                _ = await Transcriber.requestAuthorization()
                try Task.checkCancellation()
            }
            phase?(.transcribing)
            let from = 0.05 + extractShare, span = 0.9 - from
            let out = try await CaptionBatch.transcribe(pieces.map(\.wav), request: request, recognizer: recognizer, timings: &tm) { f in
                progress?(from + span * f)
            }
            tm.transcribed = pieces.count
            tm.audioSeconds = pieces.reduce(0.0) { $0 + jobs[$1.job].range.duration.seconds }
            for (k, piece) in pieces.enumerated() {
                let t = out[k].shifted(by: jobs[piece.job].range.start.seconds)
                results[piece.job] = t
                store.put(t, keys[piece.job])
            }
        }
        progress?(0.9)
        var transcripts: [MediaID: [Transcript]] = [:]
        var detected: [String: Int] = [:]
        var engineUsed = ""
        for (i, j) in jobs.enumerated() {
            guard let t = results[i] else { continue }
            transcripts[j.asset.id, default: []].append(t)
            if !t.words.isEmpty { detected[t.language, default: 0] += t.words.count; engineUsed = t.engine }
        }
        phase?(.splitting)
        let g0 = CaptionTimings.now()
        var settings = o.settings
        if o.lyrics { settings.removeFillers = false; settings.maxPause = 1.2 }
        // lines that fit the frame at the caption size (≈ 25 characters on 9:16, ≤ 40 on 16:9)
        let canvas = p.settings.canvasSize
        settings.maxCharsPerLine = min(settings.maxCharsPerLine,
                                       CaptionLayout.maxCharsPerLine(canvas: canvas, fontSize: o.style?.fontSize ?? CaptionLayout.fontSize(canvas: canvas)))
        var segments: [CaptionSegment] = []
        for c in clips {
            for t in transcripts[c.mediaID!] ?? [] where !t.words.isEmpty {
                segments += SpeechCaptions.segments(t, for: c, settings: settings)
            }
        }
        tm.segmenting = CaptionTimings.now() - g0
        tm.total = CaptionTimings.now() - started
        EngineLog.info(tm.logLine)
        guard !segments.isEmpty else { throw SpeechFailure.noSpeech(language: o.language) }
        phase?(.adding)
        progress?(0.97)
        let lang = detected.max { $0.value < $1.value }?.key ?? o.language ?? "en"
        let replace = o.replaceExisting
        let origin: CaptionOrigin = o.lyrics ? .lyrics : .auto
        let style = o.style
        let final = segments
        let cmd = Edit(o.lyrics ? "cmd.lyrics" : "cmd.captions") { p in
            try insert(final, style: style, origin: origin, replacing: replace, language: lang, into: &p)
        }
        return CaptionResult(command: cmd, count: segments.count, language: lang, engine: engineUsed, timings: tm)
    }

    /// The "Auto captions" / "Auto lyrics" edit body: a new caption track (never on an existing track, so no existing
    /// clip moves: BUG-AUTOCAPTION-SHIFT), captions linked to the main clips under them.
    @discardableResult
    public static func insert(_ segments: [CaptionSegment], style: TextContent?, origin: CaptionOrigin, replacing: Bool,
                              language: String? = nil, into p: inout Project) throws -> TrackID {
        guard let id = CaptionOps.addCaptionTrack(segments, to: &p, style: style, origin: origin, replacing: replacing) else {
            throw EditError.nothingToDo
        }
        SpeechCaptions.finish(trackID: id, in: &p)
        // CAP-LANG-TRACKS: the track knows its language
        if let ti = p.timeline.trackIndex(id) { p.timeline.tracks[ti].captionLanguage = CaptionLanguageTracks.normalized(language) }
        return id
    }

    /// Apple-engine auto-detect candidates: the UI language first (it names the language in messages).
    static func candidates(uiLanguage: String) -> [String] {
        uiLanguage == "en" ? ["en", "fr"] : ["fr", "en"]
    }

    static func merge(_ rs: [TimeRange], pad: Time, limit: Time) -> [TimeRange] {
        let sorted = rs.map { TimeRange(start: max(.zero, $0.start - pad), end: min(limit > .zero ? limit : $0.end + pad, $0.end + pad)) }
            .sorted { $0.start < $1.start }
        var out: [TimeRange] = []
        for r in sorted {
            if let l = out.last, r.start <= l.end { out[out.count - 1] = TimeRange(start: l.start, end: max(l.end, r.end)) }
            else { out.append(r) }
        }
        return out
    }
}

/// File actually decoded for a media item (converted GIF/sequence/FFmpeg formats resolve to their cached mezzanine
/// once the media pipeline provides it; until then the original URL).
enum PlayableURL {
    static func resolve(_ a: MediaAsset) -> URL { a.url }
}
