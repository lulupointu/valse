@preconcurrency import AVFoundation
import Foundation
import MontageCore
import MontageEngine

/// Audio actions of the editor (W8): analysis-backed settings (loudness, beats, sync), voice changer "apply to all",
/// audio extraction from video files, voice-over recording.
extension EditorStore {
    /// Selected clips that carry sound.
    var audioClips: [Clip] {
        selectedClips.filter { $0.mediaID.flatMap(project.asset)?.hasAudio == true }
    }

    // MARK: Loudness normalization (AU-006)

    /// Turns "Loudness normalization" on (measuring each selected clip in the background) or off.
    public func setLoudnessNormalization(_ on: Bool, target: Double = -23) {
        let clips = audioClips
        guard !clips.isEmpty else { return }
        if !on {
            perform(Edit("cmd.loudness") { p in for c in clips { p.timeline[clip: c.id]?.audio.loudness = nil } })
            return
        }
        let items = clips.compactMap { c in c.mediaID.flatMap(project.asset).map { (c.id, $0.url, c.sourceRange) } }
        let box = AudioResultBox<[ClipID: Double]>([:])
        Task {
            let job = await JobQueue.shared.enqueue(titleKey: "job.loudness", priority: 1) { progress in
                for (i, (id, url, range)) in items.enumerated() {
                    let l = try await Task.detached { try await AudioAnalysis.loudness(url: url, range: range) }.value
                    box.update { $0[id] = l }
                    progress.report(Double(i + 1) / Double(items.count))
                }
            }
            guard await JobQueue.shared.wait(job) == .done else { showToast(tr("audio.error.analysis"), error: true); return }
            let measured = box.value
            perform(Edit("cmd.loudness") { p in
                for (id, l) in measured {
                    guard let c = p.timeline.clip(id) else { continue }
                    p.timeline[clip: id]?.audio.loudness = LoudnessNormalization(targetLUFS: target, measuredLUFS: l, measuredRange: c.sourceRange)
                }
            })
            showToast(tr("audio.loudness.done"))
        }
    }

    public func setLoudnessTarget(_ target: Double) {
        let ids = audioClips.map(\.id)
        perform(Edit("cmd.loudness") { p in for id in ids { p.timeline[clip: id]?.audio.loudness?.targetLUFS = target } })
    }

    // MARK: Beats (AU-015 / TL-026)

    /// CapCut "Beats ▾ None / Beats 1 / Beats 2": auto-detects beats of the selected clip(s) and stores them as
    /// clip beat markers (`Clip.beats`, clip-local), which the timeline draws and snaps to. `level` nil = remove.
    /// Returns the task that runs the analysis job and writes the beats (tests await it), nil when nothing runs.
    @discardableResult
    public func autoBeats(level: Int?) -> Task<Void, Never>? {
        let clips = audioClips
        guard !clips.isEmpty else { showToast(tr("audio.beats.needAudio"), error: true); return nil }
        guard let level else {
            perform(Edit("cmd.beat") { p in for c in clips { p.timeline[clip: c.id]?.beats = nil } })
            return nil
        }
        let items = clips.compactMap { c in c.mediaID.flatMap(project.asset).map { (c, $0) } }
        let box = AudioResultBox<[ClipID: [Time]]>([:])
        return Task {
            let job = await JobQueue.shared.enqueue(titleKey: "job.beats", priority: 1) { progress in
                for (i, (c, a)) in items.enumerated() {
                    let b = try await Task.detached { try await AudioAnalysis.clipBeats(c, asset: a, level: level) }.value
                    box.update { $0[c.id] = b }
                    progress.report(Double(i + 1) / Double(items.count))
                }
            }
            guard await JobQueue.shared.wait(job) == .done else { showToast(tr("audio.error.analysis"), error: true); return }
            let found = box.value
            perform(Edit("cmd.beat") { p in for (id, b) in found { p.timeline[clip: id]?.beats = b.isEmpty ? nil : b } })
            showToast(found.values.allSatisfy(\.isEmpty) ? tr("audio.beats.none") : tr("audio.beats.done", found.values.map(\.count).reduce(0, +)))
        }
    }

    // MARK: Sync (AU-016)

    /// "Sync video and audio": moves every other selected clip so its sound lines up with the first selected clip
    /// (earliest start), by cross-correlating onset envelopes.
    public func syncSelectedAudio() {
        let clips = audioClips.sorted { $0.start < $1.start }
        guard clips.count >= 2, let ref = clips.first else { showToast(tr("audio.sync.needTwo"), error: true); return }
        let assets = Dictionary(uniqueKeysWithValues: project.media.map { ($0.id, $0) })
        let box = AudioResultBox<[ClipID: Time]>([:])
        Task {
            let job = await JobQueue.shared.enqueue(titleKey: "job.sync", priority: 1) { _ in
                func mono(_ c: Clip) async throws -> [Float] {
                    guard let a = c.mediaID.flatMap({ assets[$0] }) else { return [] }
                    return try await AudioFileIO.read(a.url, sampleRate: AudioAnalysis.onsetSampleRate, channels: 1,
                                                      range: c.sourceRange).channel(0)
                }
                let r = try await mono(ref)
                for c in clips.dropFirst() {
                    let other = try await mono(c)
                    let off = await Task.detached { AudioAnalysis.syncOffset(r, other, maxLag: 20) }.value
                    // b's content starts at its start; aligned position = ref.start + (b.start offset from content)
                    box.update { $0[c.id] = max(.zero, ref.start + Time(-off)) }
                }
            }
            guard await JobQueue.shared.wait(job) == .done else { showToast(tr("audio.error.analysis"), error: true); return }
            let targets = box.value
            perform(Edit("cmd.syncAudio") { p in
                for (id, t) in targets { _ = try TimelineOps.move(id, to: t, in: &p.timeline) }
            })
            showToast(tr("audio.sync.done", targets.count))
        }
    }

    // MARK: Voice changer (AU-011)

    public func applyVoice(_ effect: VoiceEffect?, toAll: Bool) {
        let ids = toAll ? project.timeline.allClips.filter { $0.mediaID.flatMap(project.asset)?.hasAudio == true }.map(\.id)
                        : audioClips.map(\.id)
        guard !ids.isEmpty else { return }
        perform(Edit("cmd.voice") { p in for id in ids { p.timeline[clip: id]?.audio.voice = effect } })
    }

    // MARK: Extract audio from a video file (AU-003)

    /// Audio tab ▸ "Extract audio": writes the audio of each video file to an .m4a next to the project (or in the
    /// drafts "Extracted audio" folder) and imports it as audio media.
    public func extractAudio(fromFiles urls: [URL]) {
        let dir = (packageURL?.appendingPathComponent("media", isDirectory: true))
            ?? MontagePaths.draftsDirectory.appendingPathComponent("Extracted audio", isDirectory: true)
        Task {
            var out: [URL] = []
            let box = AudioResultBox<[URL]>([])
            let job = await JobQueue.shared.enqueue(titleKey: "job.extractAudio", priority: 1) { progress in
                for (i, u) in urls.enumerated() {
                    let dst = dir.appendingPathComponent(u.deletingPathExtension().lastPathComponent + " (audio).m4a")
                    try await Task.detached { try await AudioExtractor.extract(from: u, to: dst) }.value
                    box.update { $0.append(dst) }
                    progress.report(Double(i + 1) / Double(urls.count))
                }
            }
            let state = await JobQueue.shared.wait(job)
            out = box.value
            if !out.isEmpty { importFiles(out) }
            if state != .done { showToast(tr("audio.extract.failed"), error: true) }
        }
    }

    // MARK: Voice-over (MI-016 / AU-020)

    /// Inserts a finished recording at `time` on a free audio track (new one if needed).
    public func insertRecording(_ url: URL, at time: Time) {
        Task {
            guard let asset = try? await MediaProbe.probe(url) else { showToast(tr("record.error.file"), error: true); return }
            var named = asset
            named.name = tr("record.clipName", Self.recordingCount(project) + 1)
            let a = named
            let clip = TimelineOps.makeClip(for: a, at: time)
            perform(Edit("cmd.record") { p in
                if !p.media.contains(where: { $0.contentHash == a.contentHash }) { p.media.append(a) }
                _ = try TimelineOps.insert(clip, into: &p, target: .automatic)
            })
            selection = [clip.id]
        }
    }

    static func recordingCount(_ p: Project) -> Int { p.media.filter { $0.url.lastPathComponent.hasPrefix("Voiceover") }.count }

    /// Where a new recording is written.
    var nextRecordingURL: URL {
        let dir = (packageURL?.appendingPathComponent("media", isDirectory: true))
            ?? MontagePaths.draftsDirectory.appendingPathComponent("Recordings", isDirectory: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        return dir.appendingPathComponent("Voiceover \(f.string(from: Date())).caf")
    }
}

/// Small lock-protected accumulator for job results.
nonisolated final class AudioResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.withLock { v } }
    func update(_ f: (inout T) -> Void) { lock.withLock { f(&v) } }
}
