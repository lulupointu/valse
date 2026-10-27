import Foundation
import ValseCore
import ValseEngine

// Background-job progress shown in the UI (C2): the timeline's clip overlay ("Applying … 40 %") and the inspector's
// progress lines read the same value — `EditorStore.jobs` (JobQueue updates) through these helpers — and both redraw
// when it changes (TimelineView observes `jobs`).

extension JobInfo {
    /// Whole percent shown next to a job's title (timeline overlay and inspector alike).
    public var percent: Int { JobInfo.percent(progress) }
    public static func percent(_ p: Double) -> Int { Int((min(max(p, 0), 1) * 100).rounded(.down)) }
}

@MainActor
extension EditorStore {
    /// Progress 0…1 of a queued / running job (nil = unknown job id).
    public func jobProgress(_ id: JobID?) -> Double? {
        guard let id else { return nil }
        return jobs.first { $0.id == id }?.progress
    }

    /// The running (else queued) job whose subject is this clip — what the timeline draws on the clip.
    public func clipJob(_ clipID: ClipID) -> JobInfo? {
        let s = clipID.description
        return jobs.first { $0.subject == s && $0.state == .running } ?? jobs.first { $0.subject == s && $0.state == .queued }
    }
}
