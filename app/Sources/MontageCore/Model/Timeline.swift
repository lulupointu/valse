import Foundation

/// Track types. Determines what a track accepts, its colour in the timeline and its default height.
public enum TrackKind: String, Codable, Sendable, CaseIterable {
    /// Video/image clips. Exactly one video track is the *main track*.
    case video
    case audio
    case text
    case sticker
    /// Effect / filter / adjustment clips ("adjustment layers"): their effect stack applies to everything below.
    case effect, filter, adjustment

    public var isVisual: Bool { self != .audio }
    public var acceptsMedia: Bool { self == .video || self == .audio }
}

public struct Track: Codable, Sendable, Equatable, Identifiable {
    public var id: TrackID
    public var kind: TrackKind
    /// The CapCut "main track" (magnetic, bottom of the video stack, cover thumbnail).
    public var isMain: Bool
    public var name: String?
    public var isMuted: Bool
    public var isHidden: Bool
    public var isLocked: Bool
    /// Sorted by `start`. Clips never overlap, except main-track neighbours joined by a transition
    /// (the next clip starts `transition.duration` before the previous one ends).
    public var clips: [Clip]

    public init(kind: TrackKind, isMain: Bool = false, clips: [Clip] = []) {
        id = TrackID(); self.kind = kind; self.isMain = isMain
        isMuted = false; isHidden = false; isLocked = false; self.clips = clips
    }

    public var end: Time { clips.map(\.end).max() ?? .zero }

    public func clipIndex(_ id: ClipID) -> Int? { clips.firstIndex { $0.id == id } }

    /// Clips active at `t` (binary search; at most 2 on the main track during a transition).
    public func clips(at t: Time) -> [Clip] {
        var lo = 0, hi = clips.count
        while lo < hi { let m = (lo + hi) / 2; if clips[m].end <= t { lo = m + 1 } else { hi = m } }
        var out: [Clip] = []
        var i = max(lo - 1, 0)
        while i < clips.count, clips[i].start <= t {
            if clips[i].range.contains(t) { out.append(clips[i]) }
            i += 1
        }
        return out
    }

    /// Clips intersecting `range`, for virtualized drawing.
    public func clips(in range: TimeRange) -> ArraySlice<Clip> {
        var lo = 0, hi = clips.count
        while lo < hi { let m = (lo + hi) / 2; if clips[m].end <= range.start { lo = m + 1 } else { hi = m } }
        var e = lo
        while e < clips.count, clips[e].start < range.end { e += 1 }
        return clips[lo..<e]
    }

    public mutating func sortClips() { clips.sort { $0.start < $1.start } }
}

public struct Timeline: Codable, Sendable, Equatable {
    /// Bottom-to-top compositing order for visual tracks (index 0 is drawn first).
    /// Audio tracks may appear anywhere in the array; they are ignored by the video compositor.
    public var tracks: [Track]
    /// CapCut "Main track magnet": main-track clips stay contiguous from t = 0.
    public var mainTrackMagnet: Bool
    /// CapCut "Linkage": clips linked to a main-track clip follow it when it moves.
    public var linkage: Bool
    /// CapCut "Auto snapping".
    public var snapping: Bool
    public var markers: [Marker]

    public init() {
        tracks = [Track(kind: .video, isMain: true)]
        mainTrackMagnet = true
        linkage = true
        snapping = true
        markers = []
    }

    public var duration: Time { tracks.map(\.end).max() ?? .zero }

    public var mainTrackIndex: Int? { tracks.firstIndex { $0.isMain } }
    public var mainTrack: Track? { mainTrackIndex.map { tracks[$0] } }

    public func trackIndex(_ id: TrackID) -> Int? { tracks.firstIndex { $0.id == id } }

    /// (track index, clip index) of a clip.
    public func locate(_ clip: ClipID) -> (track: Int, clip: Int)? {
        for (ti, t) in tracks.enumerated() { if let ci = t.clipIndex(clip) { return (ti, ci) } }
        return nil
    }

    public func clip(_ id: ClipID) -> Clip? { locate(id).map { tracks[$0.track].clips[$0.clip] } }

    public var allClips: [Clip] { tracks.flatMap(\.clips) }

    public subscript(clip id: ClipID) -> Clip? {
        get { clip(id) }
        set {
            guard let loc = locate(id) else { return }
            if let newValue { tracks[loc.track].clips[loc.clip] = newValue } else { tracks[loc.track].clips.remove(at: loc.clip) }
        }
    }
}
