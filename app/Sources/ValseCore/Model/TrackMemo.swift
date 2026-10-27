import Foundation

/// Per-track memo of a value derived from a track's clips (perf, W14 round 2). Engine bookkeeping that walks every
/// clip on every edit tick (effect prewarm, live audio chains, derived-media scans) recomputes only the tracks whose
/// clip array changed. The memo retains each track's clip array, so the same buffer address means the same contents
/// (copy-on-write: any mutation of a shared buffer copies it first). Thread-safe.
public final class TrackMemo<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [TrackID: (clips: [Clip], value: Value)] = [:]
    private let make: ([Clip]) -> Value

    public init(_ make: @escaping ([Clip]) -> Value) { self.make = make }

    public static func sameBuffer<T>(_ a: [T], _ b: [T]) -> Bool {
        guard a.count == b.count else { return false }
        if a.isEmpty { return true }
        return a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in pa.baseAddress == pb.baseAddress } }
    }

    /// Values for `tracks`, in order.
    public func values(_ tracks: [Track]) -> [Value] {
        lock.lock(); defer { lock.unlock() }
        var out: [Value] = []
        out.reserveCapacity(tracks.count)
        for t in tracks {
            if let e = entries[t.id], Self.sameBuffer(e.clips, t.clips) { out.append(e.value); continue }
            let v = make(t.clips)
            entries[t.id] = (t.clips, v)
            out.append(v)
        }
        if entries.count > tracks.count {
            let live = Set(tracks.map(\.id))
            entries = entries.filter { live.contains($0.key) }
        }
        return out
    }

    public func reset() { lock.withLock { entries.removeAll() } }
}
