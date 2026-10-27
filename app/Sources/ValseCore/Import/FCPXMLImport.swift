import Foundation

/// "Import timeline" (MI-018): reads an FCPXML 1.x (or Final Cut Pro 7 / Premiere XML) sequence (Final Cut Pro, DaVinci Resolve, Premiere via FCPXML, and
/// Valse's own export) into a timeline. Spine items become the main track (gaps kept), connected clips go to one
/// track per lane (positive lanes = video/titles above, negative = audio below). Media are referenced by their
/// `media-rep src` / `src` file URLs; titles become text clips; transitions become cross dissolves on the cut.
public enum FCPXMLImport {
    public struct Asset: Sendable, Equatable {
        public var id: String, name: String, url: URL, start: Time, hasVideo: Bool, hasAudio: Bool
    }
    public struct Item: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case media(String), title(String), gap }
        public var kind: Kind
        /// 0 = spine; FCPXML lane otherwise.
        public var lane: Int
        public var start: Time, duration: Time
        /// Source in-point relative to the asset start.
        public var sourceStart: Time
        public var enabled: Bool
        public var name: String
        /// Cross dissolve into this spine item (its duration).
        public var transitionIn: Time?
    }
    public struct Sequence: Sendable {
        public var name: String
        public var frameRate: FrameRate?
        public var size: Size2?
        public var assets: [String: Asset]
        public var items: [Item]
    }

    public enum ImportError: Error { case notFCPXML, noSequence }

    /// "1001/30000s", "3s", "0s" → Time.
    public static func time(_ s: String?) -> Time {
        guard var s, !s.isEmpty else { return .zero }
        if s.hasSuffix("s") { s.removeLast() }
        let parts = s.split(separator: "/")
        if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d != 0 { return Time(seconds: n / d) }
        return Time(seconds: Double(s) ?? 0)
    }

    public static func parse(_ data: Data) throws -> Sequence {
        let doc = try XMLDocument(data: data, options: [])
        guard let root = doc.rootElement() else { throw ImportError.notFCPXML }
        if root.name == "xmeml" { return try parseXMEML(root) }
        guard root.name == "fcpxml" else { throw ImportError.notFCPXML }
        var formats: [String: (FrameRate?, Size2?)] = [:]
        var assets: [String: Asset] = [:]
        var titles: Set<String> = []
        for r in (root.elements(forName: "resources").first?.children ?? []).compactMap({ $0 as? XMLElement }) {
            let id = r.attr("id") ?? ""
            switch r.name {
            case "format":
                let fd = time(r.attr("frameDuration"))
                let rate: FrameRate? = fd.seconds > 0 ? FrameRate.nearest(to: 1 / fd.seconds) : nil
                let size: Size2? = Double(r.attr("width") ?? "").flatMap { w in Double(r.attr("height") ?? "").map { Size2(w, $0) } }
                formats[id] = (rate, size)
            case "asset":
                let src = r.elements(forName: "media-rep").first?.attr("src") ?? r.attr("src")
                guard let src, let url = URL(string: src) ?? URL(fileURLWithPath: src) as URL? else { continue }
                assets[id] = Asset(id: id, name: r.attr("name") ?? url.deletingPathExtension().lastPathComponent, url: url,
                                   start: time(r.attr("start")), hasVideo: r.attr("hasVideo") != "0", hasAudio: r.attr("hasAudio") == "1")
            case "effect":
                if (r.attr("uid") ?? "").contains("Titles") || (r.attr("name") ?? "").lowercased().contains("title") { titles.insert(id) }
            default: break
            }
        }
        guard let project = root.descendants(named: "project").first ?? root.descendants(named: "sequence").first,
              let seq = project.name == "sequence" ? project : project.elements(forName: "sequence").first,
              let spine = seq.elements(forName: "spine").first else { throw ImportError.noSequence }
        let fmt = formats[seq.attr("format") ?? ""]
        var items: [Item] = []
        var cursor = Time.zero
        var pendingTransition: Time?
        for e in spine.children?.compactMap({ $0 as? XMLElement }) ?? [] {
            let offset = e.attr("offset").map { time($0) } ?? cursor
            let dur = time(e.attr("duration"))
            if e.name == "transition" { pendingTransition = dur; continue }
            guard dur > .zero else { continue }
            let localStart = time(e.attr("start"))
            if var it = item(e, lane: 0, start: offset, assets: assets, titles: titles) {
                it.transitionIn = pendingTransition
                items.append(it)
            }
            pendingTransition = nil
            // connected clips: offset in the parent's local (source) time
            for c in e.children?.compactMap({ $0 as? XMLElement }) ?? [] where c.attr("lane") != nil {
                let lane = Int(c.attr("lane") ?? "") ?? 1
                let t = offset + (time(c.attr("offset")) - localStart)
                if let it = item(c, lane: lane, start: max(.zero, t), assets: assets, titles: titles) { items.append(it) }
            }
            cursor = offset + dur
        }
        return Sequence(name: project.attr("name") ?? "Imported", frameRate: fmt?.0, size: fmt?.1, assets: assets, items: items)
    }

    /// Final Cut Pro 7 / Premiere XML (xmeml): sequence ▸ media ▸ video/audio ▸ track ▸ clipitem (frame units at the
    /// sequence timebase; `file` elements carry `pathurl`, later clipitems reference them by id).
    static func parseXMEML(_ root: XMLElement) throws -> Sequence {
        guard let seq = root.descendants(named: "sequence").first, let media = seq.elements(forName: "media").first else {
            throw ImportError.noSequence
        }
        func rate(_ e: XMLElement?) -> Double {
            guard let r = e?.elements(forName: "rate").first else { return 30 }
            let tb = Double(r.elements(forName: "timebase").first?.stringValue ?? "") ?? 30
            let ntsc = r.elements(forName: "ntsc").first?.stringValue?.uppercased() == "TRUE"
            return ntsc ? tb * 1000 / 1001 : tb
        }
        let fps = rate(seq)
        func t(_ frames: String?) -> Time { Time(seconds: (Double(frames ?? "") ?? 0) / fps) }
        var assets: [String: Asset] = [:]
        var items: [Item] = []
        for (kindName, laneSign) in [("video", 1), ("audio", -1)] {
            guard let k = media.elements(forName: kindName).first else { continue }
            for (ti, track) in k.elements(forName: "track").enumerated() {
                let lane = kindName == "video" ? ti : -(ti + 1)
                _ = laneSign
                for c in track.elements(forName: "clipitem") {
                    let start = Double(c.elements(forName: "start").first?.stringValue ?? "") ?? -1
                    let end = Double(c.elements(forName: "end").first?.stringValue ?? "") ?? -1
                    guard start >= 0, end > start else { continue }   // -1 = transition-adjusted; skipped
                    guard let f = c.elements(forName: "file").first, let fid = f.attr("id") else { continue }
                    if assets[fid] == nil, let path = f.elements(forName: "pathurl").first?.stringValue,
                       let url = URL(string: path) {
                        let name = f.elements(forName: "name").first?.stringValue ?? url.deletingPathExtension().lastPathComponent
                        assets[fid] = Asset(id: fid, name: name, url: url, start: .zero, hasVideo: kindName == "video", hasAudio: true)
                    }
                    guard assets[fid] != nil else { continue }
                    let inPt = c.elements(forName: "in").first?.stringValue
                    let enabled = c.elements(forName: "enabled").first?.stringValue?.uppercased() != "FALSE"
                    items.append(Item(kind: .media(fid), lane: lane, start: t(String(start)), duration: t(String(end - start)),
                                      sourceStart: t(inPt), enabled: enabled, name: c.elements(forName: "name").first?.stringValue ?? ""))
                }
            }
        }
        let fmt = media.elements(forName: "video").first?.elements(forName: "format").first?.elements(forName: "samplecharacteristics").first
        let size = Double(fmt?.elements(forName: "width").first?.stringValue ?? "").flatMap { w in
            Double(fmt?.elements(forName: "height").first?.stringValue ?? "").map { Size2(w, $0) } }
        return Sequence(name: seq.elements(forName: "name").first?.stringValue ?? "Imported", frameRate: FrameRate.nearest(to: fps),
                        size: size, assets: assets, items: items)
    }

    static func item(_ e: XMLElement, lane: Int, start: Time, assets: [String: Asset], titles: Set<String>) -> Item? {
        let dur = time(e.attr("duration"))
        guard dur > .zero else { return nil }
        let enabled = e.attr("enabled") != "0"
        let name = e.attr("name") ?? ""
        switch e.name {
        case "asset-clip", "video", "audio", "clip":
            var ref = e.attr("ref")
            var inner = e
            if e.name == "clip", let v = (e.elements(forName: "video").first ?? e.elements(forName: "asset-clip").first) {
                ref = v.attr("ref"); inner = v
            }
            guard let ref, let a = assets[ref] else { return nil }
            let src = time(e.attr("start") ?? inner.attr("start")) - a.start
            return Item(kind: .media(ref), lane: lane, start: start, duration: dur, sourceStart: max(.zero, src), enabled: enabled, name: name)
        case "title":
            let text = e.descendants(named: "text-style").compactMap { $0.stringValue }.joined()
            return Item(kind: .title(text.isEmpty ? name : text), lane: lane, start: start, duration: dur, sourceStart: .zero, enabled: enabled, name: name)
        case "gap":
            return lane == 0 ? Item(kind: .gap, lane: 0, start: start, duration: dur, sourceStart: .zero, enabled: true, name: name) : nil
        default:
            return nil
        }
    }

    /// Builds the timeline from a parsed sequence once its assets are in the bin (`media`: asset id → bin media).
    public static func timeline(_ s: Sequence, media: [String: MediaAsset]) -> Timeline {
        // group clips by destination: main, visual lanes (ascending), audio lanes
        var mainClips: [Clip] = []
        var visual: [Int: [Clip]] = [:]   // lane → clips (text/video)
        var audio: [Int: [Clip]] = [:]
        for it in s.items {
            switch it.kind {
            case .gap: continue
            case .media(let ref):
                guard let a = media[ref] else { continue }
                var c = Clip(content: .media(a.id), start: it.start, duration: it.duration)
                c.sourceStart = it.sourceStart
                c.name = it.name.isEmpty || it.name == a.name ? nil : it.name
                c.isEnabled = it.enabled
                if a.kind == .audio || it.lane < 0 { audio[it.lane, default: []].append(c) }
                else if it.lane == 0 { mainClips.append(c) }
                else { visual[it.lane, default: []].append(c) }
            case .title(let text):
                var c = Clip(content: .text(TextContent(string: text)), start: it.start, duration: it.duration)
                c.isEnabled = it.enabled
                visual[max(it.lane, 1) + 10_000, default: []].append(c)   // titles above video lanes
            }
        }
        var tl = Timeline()
        tl.mainTrackMagnet = false   // keep the imported gaps
        var below: [Track] = [], above: [Track] = []
        func split(_ clips: [Clip], kind: TrackKind) -> [Track] {
            // non-overlapping runs (a lane with overlaps becomes several tracks)
            var tracks: [Track] = []
            for c in clips.sorted(by: { $0.start < $1.start }) {
                if let i = tracks.firstIndex(where: { !$0.clips.contains { $0.range.overlaps(c.range) } }) { tracks[i].clips.append(c) }
                else { tracks.append(Track(kind: kind, clips: [c])) }
            }
            return tracks
        }
        for lane in audio.keys.sorted(by: >) { below += split(audio[lane]!, kind: .audio) }
        for lane in visual.keys.sorted() {
            let clips = visual[lane]!
            let isText = clips.allSatisfy { if case .text = $0.content { return true }; return false }
            above += split(clips, kind: isText ? .text : .video)
        }
        let mainSplit = split(mainClips, kind: .video)
        var main = tl.tracks[tl.mainTrackIndex!]
        main.clips = mainSplit.first?.clips ?? []
        tl.tracks = below + [main] + Array(mainSplit.dropFirst()) + above
        // cross dissolves on main-track cuts
        let mi = tl.mainTrackIndex!
        for it in s.items where it.lane == 0 && it.transitionIn != nil {
            let m = tl.tracks[mi].clips
            if let i = m.firstIndex(where: { abs(($0.start - it.start).seconds) < 0.001 }), i > 0,
               abs((m[i - 1].end - m[i].start).seconds) < 0.001 {
                try? TimelineOps.setTransition(m[i - 1].id, TransitionInstance(typeID: "valse.transition.dissolve", duration: it.transitionIn!), in: &tl)
            }
        }
        return tl
    }

}

extension XMLElement {
    func attr(_ n: String) -> String? { attribute(forName: n)?.stringValue }
    func descendants(named n: String) -> [XMLElement] {
        var out: [XMLElement] = []
        for c in children ?? [] { if let e = c as? XMLElement { if e.name == n { out.append(e) }; out += e.descendants(named: n) } }
        return out
    }
}
