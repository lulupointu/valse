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
}

/// Runs speech recognition for the chosen clips and builds the undoable "Auto captions" edit. Each media range is
/// transcribed once (cached in `TranscriptStore`); one heavy model at a time (whisper runs in its own process).
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
        let clips = sourceClips(p, o.source)
        guard !clips.isEmpty else { throw SpeechFailure.nothingToCaption(trackChosen: o.source != .allTracks) }
        if let forced = SpeechTestHooks.forcedFailure { throw forced }   // UI tests: failure cards
        let request = Transcriber.Request(language: o.language, engine: o.engine, keepFillers: o.settings.removeFillers,
                                          candidates: Self.candidates(uiLanguage: L10n.shared.language))
        // merged source ranges per media
        var ranges: [MediaID: [TimeRange]] = [:]
        for c in clips { ranges[c.mediaID!, default: []].append(c.sourceRange) }
        let jobs: [(MediaAsset, TimeRange)] = ranges.flatMap { mid, rs -> [(MediaAsset, TimeRange)] in
            guard let a = p.asset(mid) else { return [] }
            return merge(rs, pad: Time(0.5), limit: a.duration).map { (a, $0) }
        }
        let total = jobs.reduce(0.0) { $0 + $1.1.duration.seconds }
        var done = 0.0
        var transcripts: [MediaID: [Transcript]] = [:]
        var detected: [String: Int] = [:]
        var engineUsed = ""
        let keepFillers = o.settings.removeFillers
        for (asset, range) in jobs {
            try Task.checkCancellation()
            // Auto lyrics (AI-002): recognise the separated vocals, not the band
            let lyricsMethod = o.lyrics ? LyricsVocals.preferred : nil
            var key = TranscriptStore.key(hash: asset.contentHash, range: range, language: o.language, engine: o.engine, fillers: keepFillers)
            if let m = lyricsMethod { key += LyricsVocals.cacheSuffix(m) }
            let frac = range.duration.seconds / max(total, 0.001)
            let t: Transcript
            if let cached = TranscriptStore.shared.get(key) {
                t = cached
            } else {
                phase?(.extracting)
                var source = PlayableURL.resolve(asset)
                guard FileManager.default.fileExists(atPath: source.path) else {
                    throw SpeechFailure.mediaOffline(name: asset.name, media: asset.id)
                }
                if let m = lyricsMethod, m != .none {
                    phase?(.separating)   // AI-002 "Separating vocals…"
                    let base = done
                    let v = try await LyricsVocals.vocals(asset, method: m) { f in progress?(0.05 + 0.85 * (base + 0.5 * f * frac)) }
                    if let u = v.url { source = u }
                }
                let wav: URL
                do { wav = try await AudioExtractor.wav16k(source, range: range) }
                catch SpeechFailure.mediaOffline { throw SpeechFailure.mediaOffline(name: asset.name, media: asset.id) }
                catch SpeechFailure.noSoundInFile { throw SpeechFailure.noSoundInFile(name: asset.name) }
                defer { try? FileManager.default.removeItem(at: wav) }
                if AudioExtractor.isSilent(wav) {
                    t = Transcript(engine: "silence", language: o.language ?? "", words: [])
                } else {
                    // Apple speech asks for permission once: wait for the user's answer ("Waiting for permission…")
                    if Transcriber.willAskPermission(request) {
                        phase?(.permission)
                        _ = await Transcriber.requestAuthorization()
                        try Task.checkCancellation()
                    }
                    phase?(.transcribing)
                    // with vocal separation the transcription is the second half of this range's progress
                    let sep = (lyricsMethod ?? .none) == .none ? 0.0 : 0.5
                    let base = done + sep * frac
                    let r = try await Transcriber.transcribe(wav: wav, request: request) { f in
                            progress?(0.05 + 0.85 * (base + (1 - sep) * f * frac))
                        }
                    t = r.shifted(by: range.start.seconds)
                }
                TranscriptStore.shared.put(t, key)
            }
            done += frac
            progress?(0.05 + 0.85 * done)
            transcripts[asset.id, default: []].append(t)
            if !t.words.isEmpty { detected[t.language, default: 0] += t.words.count; engineUsed = t.engine }
        }
        phase?(.splitting)
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
        return CaptionResult(command: cmd, count: segments.count, language: lang, engine: engineUsed)
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
