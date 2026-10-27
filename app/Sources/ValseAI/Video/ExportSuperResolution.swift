import Foundation
import ValseCore
import ValseEngine

/// EX-018 "AI ultra HD" export switch: clips shown larger than their source at the export resolution are
/// super-resolved with the same on-device VideoToolbox ML scalers as Enhance quality (CL-019) — HD ×2 when that is
/// enough, else UHD — into the shared `enhanced` cache, and the export renders those copies. The user's project is
/// never changed. Media the scalers can't take (too large, unsupported OS) export as before.
public enum ExportSuperResolution {
    public static func run(_ project: Project, _ settings: ExportSettings, _ range: TimeRange?,
                           _ progress: @escaping @Sendable (Double) -> Void) async throws -> Project {
        var p = project
        let needs = ExportHooks.clipsNeedingUpscale(p, settings: settings, range: range)
        // one job per (media, target)
        var jobs: [(asset: MediaAsset, target: UpscaleTarget, clips: [ClipID])] = []
        for (id, factor) in needs {
            guard let c = p.timeline.clip(id), case .media(let mid) = c.content, let a = p.asset(mid),
                  VideoEnhancer.canUpscale(a) else { continue }
            let target: UpscaleTarget = factor <= 2.05 ? .hd : .uhd
            if let i = jobs.firstIndex(where: { $0.asset.id == a.id && $0.target == target }) { jobs[i].clips.append(id) }
            else { jobs.append((a, target, [id])) }
        }
        for (n, job) in jobs.enumerated() {
            try Task.checkCancellation()
            let base = Double(n) / Double(jobs.count), span = 1 / Double(jobs.count)
            let e = VideoEnhancement(original: job.asset.id, upscale: job.target)
            let url = try await VideoEnhancer.process(job.asset, e) { progress(base + span * $0) }
            var processed = try await MediaProbe.probe(url)
            processed.name = job.asset.name
            let mid: MediaID
            if let existing = p.media.first(where: { $0.contentHash == processed.contentHash }) { mid = existing.id }
            else { p.media.append(processed); mid = processed.id }
            for id in job.clips {
                guard var c = p.timeline.clip(id) else { continue }
                c.content = .media(mid)
                var en = c.enhance ?? VideoEnhancement(original: job.asset.id)
                en.upscale = job.target
                c.enhance = en
                p.timeline[clip: id] = c
            }
        }
        progress(1)
        return p
    }
}
