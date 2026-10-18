import Foundation

// Speaker identification in captions (AI-005 / TX-038, CapCut "Smart caption speaker ID"): auto captions carry a
// speaker id (`CaptionData.speaker`, "1", "2"…); the project keeps each speaker's name and caption colour
// (`Project.speakers`). Diarization (embeddings + audio) lives in MontageAI (`SpeakerDiarizer`); everything here is
// pure: clustering, smoothing, splitting captions at speaker changes, per-speaker styling.

/// A diarized speaker of the project's captions (rename + per-speaker colour in Inspector ▸ Captions ▸ Speakers).
public struct CaptionSpeaker: Hashable, Codable, Sendable, Identifiable {
    /// Matches `CaptionData.speaker` ("1", "2"…).
    public var id: String
    /// User-given name; nil = "Speaker N".
    public var name: String?
    /// Caption fill colour of this speaker.
    public var color: RGBA
    public init(id: String, name: String? = nil, color: RGBA) { self.id = id; self.name = name; self.color = color }
    /// 1-based number for the default name.
    public var number: Int { Int(id) ?? 0 }
}

/// A time span spoken by one speaker (timeline seconds).
public struct SpeakerTurn: Hashable, Sendable {
    public var start: Double, end: Double
    public var speaker: Int
    public init(start: Double, end: Double, speaker: Int) { self.start = start; self.end = end; self.speaker = speaker }
}

/// Agglomerative (average-linkage) clustering on cosine distance.
public enum SpeakerClustering {
    public static func cosineDistance(_ a: [Float], _ b: [Float]) -> Double {
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<min(a.count, b.count) { dot += Double(a[i] * b[i]); na += Double(a[i] * a[i]); nb += Double(b[i] * b[i]) }
        guard na > 0, nb > 0 else { return 1 }
        return 1 - dot / (na.squareRoot() * nb.squareRoot())
    }

    /// Cluster labels 0…k-1, numbered by first appearance. `count` forces the number of clusters; otherwise merging
    /// stops when the closest pair is farther than `threshold`. Clusters weighing less than `minShare` of the total
    /// `weights` (e.g. speech seconds) are folded into the nearest bigger one. Large inputs are clustered on a
    /// subsample (≤ `maxDirect`) and the rest assigned to the nearest centroid.
    public static func cluster(_ x: [[Float]], threshold: Double, count: Int? = nil, weights: [Double]? = nil,
                               minShare: Double = 0.06, maxDirect: Int = 500) -> [Int] {
        let n = x.count
        guard n > 1 else { return Array(repeating: 0, count: n) }
        let w = weights ?? Array(repeating: 1, count: n)
        // subsample for big inputs (evenly spaced)
        let idx: [Int] = n <= maxDirect ? Array(0..<n) : (0..<maxDirect).map { $0 * n / maxDirect }
        let m = idx.count
        var d = [[Double]](repeating: [Double](repeating: 0, count: m), count: m)
        for i in 0..<m { for j in (i + 1)..<m { let v = cosineDistance(x[idx[i]], x[idx[j]]); d[i][j] = v; d[j][i] = v } }
        var members: [[Int]] = (0..<m).map { [$0] }
        var alive = Array(repeating: true, count: m)
        var clusters = m
        let target = count.map { max(1, $0) }
        while clusters > 1 {
            var best = (Double.infinity, -1, -1)
            for i in 0..<m where alive[i] { for j in (i + 1)..<m where alive[j] && d[i][j] < best.0 { best = (d[i][j], i, j) } }
            guard best.1 >= 0 else { break }
            if let t = target { if clusters <= t { break } } else if best.0 > threshold { break }
            let (_, a, b) = best
            let na = Double(members[a].count), nb = Double(members[b].count)
            for k in 0..<m where alive[k] && k != a && k != b {
                let v = (d[a][k] * na + d[b][k] * nb) / (na + nb)
                d[a][k] = v; d[k][a] = v
            }
            members[a] += members[b]; members[b] = []; alive[b] = false
            clusters -= 1
        }
        var groups = (0..<m).filter { alive[$0] }.map { members[$0].map { idx[$0] } }
        // centroids
        func centroid(_ g: [Int]) -> [Float] {
            var c = [Float](repeating: 0, count: x[g[0]].count)
            for i in g { let v = normalized(x[i]); for k in c.indices { c[k] += v[k] } }
            return c
        }
        // fold tiny clusters (auto mode only, or when forced count is still respected)
        let total = w.reduce(0, +)
        func weight(_ g: [Int]) -> Double { g.reduce(0) { $0 + w[$1] } * Double(n) / Double(m) }
        while groups.count > 1 {
            let weights = groups.map(weight)
            guard let small = weights.indices.min(by: { weights[$0] < weights[$1] }),
                  weights[small] < minShare * total, target == nil || groups.count > target! else { break }
            let cs = centroid(groups[small])
            let others = groups.indices.filter { $0 != small }
            let near = others.min { cosineDistance(cs, centroid(groups[$0])) < cosineDistance(cs, centroid(groups[$1])) }!
            groups[near] += groups[small]
            groups.remove(at: small)
        }
        let cents = groups.map(centroid)
        var labels = Array(repeating: 0, count: n)
        var assigned = Set<Int>()
        for (gi, g) in groups.enumerated() { for i in g { labels[i] = gi; assigned.insert(i) } }
        for i in 0..<n where !assigned.contains(i) {
            labels[i] = cents.indices.min { cosineDistance(x[i], cents[$0]) < cosineDistance(x[i], cents[$1]) } ?? 0
        }
        return renumber(labels)
    }

    /// Labels renumbered 0, 1, 2… in order of first appearance.
    public static func renumber(_ labels: [Int]) -> [Int] {
        var map: [Int: Int] = [:]
        return labels.map { l in
            if let v = map[l] { return v }
            let v = map.count; map[l] = v; return v
        }
    }

    public static func normalized(_ v: [Float]) -> [Float] {
        let n = v.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }
}

public enum SpeakerCaptions {
    /// Default per-speaker caption colours (speaker 1 keeps white).
    public static let palette: [RGBA] = [RGBA(1, 1, 1), RGBA(hex: 0xFFE14D), RGBA(hex: 0x5ED8F0), RGBA(hex: 0xFF8FB8),
                                         RGBA(hex: 0x8CE07A), RGBA(hex: 0xFFAA5C), RGBA(hex: 0xB79CFF), RGBA(hex: 0xF5F5A0)]
    public static func defaultColor(_ index: Int) -> RGBA { palette[index % palette.count] }

    /// Speaker label (0-based) of a timeline time: the turn containing it, else the nearest turn.
    public static func speaker(at t: Double, in turns: [SpeakerTurn]) -> Int? {
        if let c = turns.first(where: { $0.start <= t && t <= $0.end }) { return c.speaker }
        return turns.min { dist(t, $0) < dist(t, $1) }?.speaker
    }
    static func dist(_ t: Double, _ r: SpeakerTurn) -> Double { t < r.start ? r.start - t : (t > r.end ? t - r.end : 0) }

    /// Smooths per-word labels: a run shorter than `minRun` seconds between two runs of the same speaker takes their
    /// label (a flip on one short word is almost always an embedding error).
    public static func smooth(_ labels: [Int], times: [(start: Double, end: Double)], minRun: Double = 0.5) -> [Int] {
        guard labels.count > 2 else { return labels }
        var out = labels
        var i = 0
        while i < out.count {
            var j = i
            while j + 1 < out.count, out[j + 1] == out[i] { j += 1 }
            if i > 0, j + 1 < out.count, out[i - 1] == out[j + 1], times[j].end - times[i].start < minRun {
                for k in i...j { out[k] = out[i - 1] }
            }
            i = j + 1
        }
        return out
    }

    /// Splits caption segments where the speaker changes (each part ≥ 1 word) and sets `speaker` ("1", "2"…) on
    /// every segment. Segments without word timings take the speaker at their midpoint.
    public static func split(_ segments: [CaptionSegment], turns: [SpeakerTurn]) -> [CaptionSegment] {
        guard !turns.isEmpty else { return segments }
        var out: [CaptionSegment] = []
        for s in segments {
            guard !s.words.isEmpty else {
                var c = s; c.speaker = speaker(at: (s.start + s.end) / 2, in: turns).map { "\($0 + 1)" }; out.append(c); continue
            }
            let raw = s.words.map { speaker(at: ($0.start + $0.end) / 2, in: turns) ?? 0 }
            let labels = smooth(raw, times: s.words.map { ($0.start, $0.end) })
            var i = 0
            while i < labels.count {
                var j = i
                while j + 1 < labels.count, labels[j + 1] == labels[i] { j += 1 }
                let ws = Array(s.words[i...j])
                var part = s
                part.words = ws
                part.text = labels.count == j - i + 1 ? s.text : CaptionText.join(ws.map(\.text))
                part.start = i == 0 ? s.start : ws.first!.start
                part.end = j == labels.count - 1 ? s.end : ws.last!.end
                part.speaker = "\(labels[i] + 1)"
                if labels.count != j - i + 1 { part.translation = nil }   // a translation can't be split by words
                out.append(part)
                i = j + 1
            }
        }
        return out
    }

    /// Speakers referenced by caption clips, in number order.
    public static func speakerIDs(in tl: Timeline) -> [String] {
        var ids = Set<String>()
        for ti in CaptionOps.captionTracks(tl) {
            for c in tl.tracks[ti].clips { if let s = CaptionOps.text(c)?.caption?.speaker, !s.isEmpty { ids.insert(s) } }
        }
        return ids.sorted { (Int($0) ?? Int.max, $0) < (Int($1) ?? Int.max, $1) }
    }

    /// Makes sure `project.speakers` lists every speaker used by the captions (default colours) and drops unused ones.
    public static func syncSpeakers(in p: inout Project) {
        let used = speakerIDs(in: p.timeline)
        guard !used.isEmpty else { if p.speakers != nil { p.speakers = nil }; return }
        let old = Dictionary((p.speakers ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        p.speakers = used.enumerated().map { i, id in old[id] ?? CaptionSpeaker(id: id, color: defaultColor((Int(id) ?? i + 1) - 1)) }
    }

    /// Colours every speaker-tagged caption with its speaker's colour (after generation / a colour change).
    public static func applyColors(in p: inout Project, only speakerID: String? = nil) {
        let colors = Dictionary((p.speakers ?? []).map { ($0.id, $0.color) }, uniquingKeysWith: { a, _ in a })
        for ti in CaptionOps.captionTracks(p.timeline) {
            for i in p.timeline.tracks[ti].clips.indices {
                guard case .text(var t) = p.timeline.tracks[ti].clips[i].content, let s = t.caption?.speaker,
                      speakerID == nil || s == speakerID, let col = colors[s] else { continue }
                t.color = col
                p.timeline.tracks[ti].clips[i].content = .text(t)
            }
        }
    }

    /// After diarization of a generated caption track: registers speakers and colours them.
    public static func finish(in p: inout Project) {
        syncSpeakers(in: &p)
        applyColors(in: &p)
    }

    /// Sets the speaker of existing captions by majority vote of their words (no splitting: keeps per-clip styles).
    public static func assign(turns: [SpeakerTurn], in p: inout Project) {
        for ti in CaptionOps.captionTracks(p.timeline) {
            for i in p.timeline.tracks[ti].clips.indices {
                let c = p.timeline.tracks[ti].clips[i]
                guard case .text(var t) = c.content, var data = t.caption else { continue }
                let origin = (c.start - c.sourceStart).seconds
                let words = CaptionOps.words(of: c)
                var votes: [Int: Double] = [:]
                if words.isEmpty {
                    if let s = speaker(at: (c.start.seconds + c.end.seconds) / 2, in: turns) { votes[s] = 1 }
                } else {
                    for w in words {
                        let m = origin + (w.start.seconds + w.end.seconds) / 2
                        if let s = speaker(at: m, in: turns) { votes[s, default: 0] += max(w.end.seconds - w.start.seconds, 0.05) }
                    }
                }
                guard let best = votes.max(by: { $0.value < $1.value })?.key else { continue }
                data.speaker = "\(best + 1)"
                t.caption = data
                p.timeline.tracks[ti].clips[i].content = .text(t)
            }
        }
        finish(in: &p)
    }

    /// Removes speaker tags (and the project's speaker list); caption colours return to the first caption's colour.
    public static func clear(in p: inout Project) {
        for ti in CaptionOps.captionTracks(p.timeline) {
            for i in p.timeline.tracks[ti].clips.indices {
                guard case .text(var t) = p.timeline.tracks[ti].clips[i].content, var data = t.caption, data.speaker != nil else { continue }
                data.speaker = nil
                t.caption = data
                t.color = .white
                p.timeline.tracks[ti].clips[i].content = .text(t)
            }
        }
        p.speakers = nil
    }

    public static func rename(_ id: String, to name: String?, in p: inout Project) {
        syncSpeakers(in: &p)
        guard let i = p.speakers?.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        p.speakers![i].name = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    public static func setColor(_ id: String, _ color: RGBA, in p: inout Project) {
        syncSpeakers(in: &p)
        guard let i = p.speakers?.firstIndex(where: { $0.id == id }) else { return }
        p.speakers![i].color = color
        applyColors(in: &p, only: id)
    }

    /// "Apply to this speaker": copies the look of one caption to every caption of the same speaker (text, timings
    /// and caption data stay); the speaker's colour becomes that caption's colour.
    public static func applyLookToSpeaker(from id: ClipID, in p: inout Project) {
        guard let src = p.timeline.clip(id), let st = CaptionOps.text(src), let sp = st.caption?.speaker else { return }
        for ti in CaptionOps.captionTracks(p.timeline) {
            for i in p.timeline.tracks[ti].clips.indices {
                var c = p.timeline.tracks[ti].clips[i]
                guard c.id != id, var t = CaptionOps.text(c), t.caption?.speaker == sp else { continue }
                let keep = t.caption
                t.adoptLook(of: st)
                t.caption = keep
                c.content = .text(t)
                c.transform = src.transform
                p.timeline.tracks[ti].clips[i] = c
            }
        }
        syncSpeakers(in: &p)
        if let i = p.speakers?.firstIndex(where: { $0.id == sp }) { p.speakers![i].color = st.color }
    }
}
