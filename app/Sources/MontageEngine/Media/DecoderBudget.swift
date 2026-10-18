import Foundation
import MontageCore

/// Decoder memory limiter (8 GB machines): how many hardware decoders the preview keeps alive at once.
///
/// Every video clip active at an instant costs one decode stream per composition lane it uses (main lane plus aux lanes:
/// smooth slow-mo, motion-blur taps, matte), costed with `MemoryBudget.decoderCost` at the resolution actually decoded
/// (proxy when ready, else the original). `peak` sweeps clip boundaries; when it exceeds `MemoryBudget.decoderBudget`,
/// `mediaNeedingProxies` names the heaviest originals to proxy (largest saving first) until the peak fits — the
/// playback engine queues them and the preview switches to proxies as they finish. Export is not limited (it decodes
/// sequentially at full quality).
public enum DecoderBudget {
    struct Stream { let media: MediaAsset; let lanes: Int; let range: TimeRange }

    static func streams(_ project: Project) -> [Stream] {
        var out: [Stream] = []
        let lookup = project.mediaLookup
        for t in CompoundFlattening.decodeTracks(project) where t.kind.isVisual && !t.isHidden {
            for c in t.clips where c.isEnabled {
                guard let id = c.mediaID, let a = lookup[id], a.kind == .video, a.hasVideo else { continue }
                var lanes = 1
                if c.smoothSlowMo != nil { lanes += 1 }
                if let mb = c.motionBlur, mb.amount > 0 { lanes += mb.clampedSamples - 1 }
                if c.matte != nil { lanes += 1 }
                if c.relight != nil { lanes += 1 }   // depth (+ person) mattes: ≤ 518 px, counted as one lane
                out.append(Stream(media: a, lanes: lanes, range: c.range))
            }
        }
        return out
    }

    /// Decode size of a media item for preview (proxy short side 720 when ready).
    static func decodeSize(_ a: MediaAsset, proxied: (MediaAsset) -> Bool) -> Size2 {
        guard proxied(a) else { return a.pixelSize }
        let short = min(a.pixelSize.width, a.pixelSize.height)
        let k = min(1, 720 / max(short, 1))
        return Size2(a.pixelSize.width * k, a.pixelSize.height * k)
    }

    /// Peak simultaneous decoder cost (bytes) over the timeline.
    public static func peak(_ project: Project, proxied: (MediaAsset) -> Bool = { ProxyManager.shared.readyProxyURL(for: $0) != nil }) -> UInt64 {
        peakCost(streams(project), proxied: proxied)
    }

    static func peakCost(_ s: [Stream], proxied: (MediaAsset) -> Bool) -> UInt64 {
        var events: [(Time, Int64)] = []
        for x in s {
            let cost = Int64(MemoryBudget.decoderCost(decodeSize(x.media, proxied: proxied))) * Int64(x.lanes)
            events.append((x.range.start, cost)); events.append((x.range.end, -cost))
        }
        // ends before starts at the same instant (half-open ranges)
        events.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var cur: Int64 = 0, best: Int64 = 0
        for e in events { cur += e.1; best = max(best, cur) }
        return UInt64(max(best, 0))
    }

    /// Originals to proxy so the preview's peak decoder cost fits the budget (empty when it already fits, or when the
    /// proxy policy is `.never`). Excludes media whose proxy is ready or pending.
    public static func mediaNeedingProxies(_ project: Project, budget: UInt64 = MemoryBudget.decoderBudget,
                                           isReadyOrPending: (MediaAsset) -> Bool = {
                                               ProxyManager.shared.readyProxyURL(for: $0) != nil || ProxyManager.shared.isPending($0)
                                           }) -> [MediaAsset] {
        guard ProxyManager.shared.policy != .never else { return [] }
        let s = streams(project)
        var chosen = Set<String>()
        func proxied(_ a: MediaAsset) -> Bool { chosen.contains(a.contentHash) || isReadyOrPending(a) }
        guard peakCost(s, proxied: proxied) > budget else { return [] }
        // candidates by saving per stream, largest first
        var seen = Set<String>()
        let candidates = s.map(\.media).filter { seen.insert($0.contentHash).inserted && !isReadyOrPending($0) }
            .sorted { $0.pixelSize.width * $0.pixelSize.height > $1.pixelSize.width * $1.pixelSize.height }
        var out: [MediaAsset] = []
        for a in candidates {
            if min(a.pixelSize.width, a.pixelSize.height) <= 720 { continue }
            chosen.insert(a.contentHash); out.append(a)
            if peakCost(s, proxied: proxied) <= budget { break }
        }
        return out
    }
}
