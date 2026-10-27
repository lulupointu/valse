import Foundation
import MontageCore

/// "Export timeline" (EX-020): the project as FCPXML 1.10 (Final Cut Pro, DaVinci Resolve, Premiere via import),
/// CMX 3600 EDL (main track) and OpenTimelineIO JSON. Times are snapped to the project frame grid.
///
/// Mapping: main track → `spine` (gaps where the magnet is off; transitions centred on the cut, the clips trimmed by
/// half the transition each side, like FCP's handles); other tracks → connected clips (`lane` +n above for video/text,
/// −n for audio) anchored to the spine item under their start; constant speed / reverse → `timeMap`; volume →
/// `adjust-volume`; transform → `adjust-transform`; opacity → `adjust-blend`; text → Basic Title. Effects, masks,
/// keyframes, stickers, solids and compound clips are not exchanged (they have no portable equivalent).
public enum TimelineInterchange {
    public enum Format: String, Sendable, CaseIterable {
        case fcpxml, edl, otio
        public var fileExtension: String { rawValue }
        public var label: String { self == .fcpxml ? "Final Cut Pro XML" : (self == .edl ? "EDL (CMX 3600)" : "OpenTimelineIO") }
    }

    public static func write(_ p: Project, format: Format, name: String, to url: URL) throws {
        let text: String
        switch format {
        case .fcpxml: text = fcpxml(p, name: name)
        case .edl: text = edl(p, name: name)
        case .otio: text = otio(p, name: name)
        }
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    // MARK: Time helpers

    struct Clock {
        let rate: FrameRate
        func frames(_ t: Time) -> Int64 { Int64((t.seconds * rate.fps).rounded()) }
        /// FCPXML rational seconds on the frame grid ("1001/30000s", "3s").
        func fcp(_ t: Time) -> String { fcpFrames(frames(t)) }
        func fcpFrames(_ f: Int64) -> String {
            let num = f * Int64(rate.denominator), den = Int64(rate.numerator)
            if num == 0 { return "0s" }
            let g = gcd(abs(num), den)
            return den / g == 1 ? "\(num / g)s" : "\(num / g)/\(den / g)s"
        }
        /// Rational seconds of an arbitrary time (source in-points of media with another rate).
        func exact(_ t: Time) -> String {
            let ticks = t.ticks, den = Int64(Time.ticksPerSecond)
            if ticks == 0 { return "0s" }
            let g = gcd(abs(ticks), den)
            return den / g == 1 ? "\(ticks / g)s" : "\(ticks / g)/\(den / g)s"
        }
        func timecode(_ t: Time) -> String { timecode(frames: frames(t)) }
        func timecode(frames f: Int64) -> String {
            let fps = Int64(rate.fps.rounded())
            let s = f / fps
            return String(format: "%02lld:%02lld:%02lld:%02lld", s / 3600, (s / 60) % 60, s % 60, f % fps)
        }
        func gcd(_ a: Int64, _ b: Int64) -> Int64 { b == 0 ? max(a, 1) : gcd(b, a % b) }
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func num(_ v: Double) -> String {
        let r = (v * 10000).rounded() / 10000
        return r == r.rounded() ? String(Int(r)) : String(r)
    }

    /// Constant source rate of a clip (curves use their average).
    static func rate(_ c: Clip) -> Double { c.speed.averageRate }

    // MARK: FCPXML

    struct SpineItem {
        var offset: Time, duration: Time, localStart: Time, rate: Double
        var open: String, body: [String], close: String
        var anchors: [String] = []
        var isParent = true
    }

    public static func fcpxml(_ p: Project, name: String) -> String {
        let clock = Clock(rate: p.settings.frameRate)
        let canvas = p.settings.canvasSize
        var res: [String] = []
        var nextID = 1
        func rid() -> String { defer { nextID += 1 }; return "r\(nextID)" }
        let seqFormat = rid()
        let cs = p.settings.colorSpace == .sdr709 ? "1-1-1 (Rec. 709)" : (p.settings.colorSpace == .hdrHLG ? "9-18-9 (Rec. 2020 HLG)" : "9-16-9 (Rec. 2020 PQ)")
        res.append(#"<format id="\#(seqFormat)" name="Valse \#(Int(canvas.width))x\#(Int(canvas.height))" frameDuration="\#(clock.fcpFrames(1))" width="\#(Int(canvas.width))" height="\#(Int(canvas.height))" colorSpace="\#(cs)"/>"#)
        var assetRef: [MediaID: String] = [:]
        for a in p.media {
            var formatAttr = ""
            if a.kind != .audio {
                let f = rid()
                let fd = a.frameRate.map { Clock(rate: $0).fcpFrames(1) } ?? clock.fcpFrames(1)
                res.append(#"<format id="\#(f)" frameDuration="\#(fd)" width="\#(Int(a.pixelSize.width))" height="\#(Int(a.pixelSize.height))"/>"#)
                formatAttr = #" format="\#(f)""#
            }
            let id = rid(); assetRef[a.id] = id
            let dur = a.kind == .image ? "0s" : clock.exact(a.duration)
            let audio = a.hasAudio ? #" hasAudio="1" audioSources="1" audioChannels="2" audioRate="48000""# : ""
            res.append(#"<asset id="\#(id)" name="\#(esc(a.name))" uid="\#(esc(a.contentHash))" start="0s" duration="\#(dur)" hasVideo="\#(a.hasVideo || a.kind == .image ? 1 : 0)"\#(audio)\#(formatAttr)>"#
                       + #"<media-rep kind="original-media" src="\#(esc(a.url.absoluteString))"/></asset>"#)
        }
        let titleRef = rid(), dissolveRef = rid()
        res.append(#"<effect id="\#(titleRef)" name="Basic Title" uid=".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti"/>"#)
        res.append(#"<effect id="\#(dissolveRef)" name="Cross Dissolve" uid="FxPlug:4731E73A-8DAC-4113-9A30-AE85B1761265"/>"#)

        var styleN = 0
        /// Element for one clip; `lane` nil on the spine. `trimIn/Out` shorten the clip (transition handles).
        func element(_ c: Clip, lane: Int?, offset: Time, trimIn: Time = .zero, trimOut: Time = .zero) -> (open: String, body: [String], close: String, localStart: Time)? {
            let laneAttr = lane.map { #" lane="\#($0)""# } ?? ""
            let enabled = c.isEnabled ? "" : #" enabled="0""#
            let dur = c.duration - trimIn - trimOut
            guard dur > .zero else { return nil }
            let nameAttr = esc(c.name ?? "")
            var body: [String] = []
            let r = rate(c)
            switch c.content {
            case .media(let mid):
                guard let a = p.asset(mid), let ref = assetRef[mid] else { return nil }
                let srcIn = c.sourceStart + trimIn * r
                let start = srcIn
                if !c.speed.isNormal || c.reversed {
                    let srcOut = c.sourceStart + (c.duration - trimOut) * r
                    let (v0, v1) = c.reversed ? (c.sourceStart + c.sourceDuration - trimIn * r, c.sourceStart + c.sourceDuration - (c.duration - trimOut) * r) : (srcIn, srcOut)
                    body.append(#"<timeMap><timept time="\#(clock.exact(start))" value="\#(clock.exact(v0))" interp="linear"/><timept time="\#(clock.exact(start + dur))" value="\#(clock.exact(v1))" interp="linear"/></timeMap>"#)
                }
                if a.kind != .audio { body += visualAdjust(c, canvas: canvas) }
                if a.hasAudio && a.kind != .image {
                    let v = c.audio.isMuted ? 0 : c.audio.volume
                    if v != 1 { body.append(#"<adjust-volume amount="\#(v <= 0.00001 ? "-96" : num(20 * log10(v)))dB"/>"#) }
                }
                let tag = a.kind == .image ? "video" : "asset-clip"
                let role = a.kind == .audio ? #" audioRole="dialogue""# : ""
                let open = #"<\#(tag) ref="\#(ref)"\#(laneAttr) offset="\#(clock.fcp(offset))" name="\#(nameAttr.isEmpty ? esc(a.name) : nameAttr)" start="\#(clock.exact(start))" duration="\#(clock.fcp(dur))"\#(role)\#(enabled)>"#
                return (open, body, "</\(tag)>", start)
            case .text(let t):
                styleN += 1
                let ts = "ts\(styleN)"
                let px = t.fontSize * canvas.height
                let col = "\(num(t.color.r)) \(num(t.color.g)) \(num(t.color.b)) \(num(t.color.a))"
                body += visualAdjust(c, canvas: canvas)
                body.append(#"<text><text-style ref="\#(ts)">\#(esc(t.string))</text-style></text>"#)
                body.append(#"<text-style-def id="\#(ts)"><text-style font="\#(esc(t.fontName.isEmpty ? "Helvetica" : t.fontName))" fontSize="\#(num(px))" fontColor="\#(col)"\#(t.bold ? #" bold="1""# : "")\#(t.italic ? #" italic="1""# : "") alignment="center"/></text-style-def>"#)
                let open = #"<title ref="\#(titleRef)"\#(laneAttr) offset="\#(clock.fcp(offset))" name="\#(esc(t.string.prefix(60).description))" start="0s" duration="\#(clock.fcp(dur))"\#(enabled)>"#
                return (open, body, "</title>", .zero)
            default:
                return nil
            }
        }

        // Spine (main track)
        var spine: [SpineItem] = []
        var cursor = Time.zero
        let main = p.timeline.mainTrack?.clips ?? []
        for (i, c) in main.enumerated() {
            let prev = i > 0 ? main[i - 1] : nil
            let next = i + 1 < main.count ? main[i + 1] : nil
            let inT = prev.flatMap { pv in pv.transitionOut.map { $0.duration } }.flatMap { d in c.start < prev!.end ? d / 2 : nil } ?? .zero
            let outT = c.transitionOut.flatMap { t in next.map { $0.start < c.end ? t.duration / 2 : .zero } } ?? .zero
            let vStart = c.start + inT
            if vStart > cursor {
                spine.append(SpineItem(offset: cursor, duration: vStart - cursor, localStart: cursor, rate: 1,
                                       open: #"<gap name="Gap" offset="\#(clock.fcp(cursor))" start="\#(clock.fcp(cursor))" duration="\#(clock.fcp(vStart - cursor))">"#, body: [], close: "</gap>"))
            }
            if inT > .zero, let pv = prev, let tr = pv.transitionOut {
                spine.append(SpineItem(offset: c.start, duration: tr.duration, localStart: .zero, rate: 1,
                                       open: #"<transition name="Cross Dissolve" offset="\#(clock.fcp(c.start))" duration="\#(clock.fcp(tr.duration))">"#,
                                       body: [#"<filter-video ref="\#(dissolveRef)" name="Cross Dissolve"/>"#], close: "</transition>", isParent: false))
            }
            let dur = c.duration - inT - outT
            if let e = element(c, lane: nil, offset: vStart, trimIn: inT, trimOut: outT) {
                spine.append(SpineItem(offset: vStart, duration: dur, localStart: e.localStart, rate: rate(c), open: e.open, body: e.body, close: e.close))
            } else {
                spine.append(SpineItem(offset: vStart, duration: dur, localStart: vStart, rate: 1,
                                       open: #"<gap name="\#(esc(c.name ?? "Gap"))" offset="\#(clock.fcp(vStart))" start="\#(clock.fcp(vStart))" duration="\#(clock.fcp(dur))">"#, body: [], close: "</gap>"))
            }
            cursor = vStart + dur
        }
        let total = p.duration
        if total > cursor {
            spine.append(SpineItem(offset: cursor, duration: total - cursor, localStart: cursor, rate: 1,
                                   open: #"<gap name="Gap" offset="\#(clock.fcp(cursor))" start="\#(clock.fcp(cursor))" duration="\#(clock.fcp(total - cursor))">"#, body: [], close: "</gap>"))
        }

        // Connected clips: lanes by track order (video/text above the main track: +1, +2…; audio: −1, −2…).
        let tracks = p.timeline.tracks
        let mainIndex = p.timeline.mainTrackIndex ?? -1
        var upLane = 0, downLane = 0
        for (ti, t) in tracks.enumerated() where ti != mainIndex {
            let lane: Int
            if t.kind == .audio { downLane -= 1; lane = downLane } else if ti > mainIndex { upLane += 1; lane = upLane } else { downLane -= 1; lane = downLane }
            for c in t.clips {
                guard let host = spine.indices.first(where: { spine[$0].isParent && spine[$0].offset <= c.start && c.start < spine[$0].offset + spine[$0].duration })
                        ?? spine.indices.last(where: { spine[$0].isParent }) else { continue }
                let h = spine[host]
                let local = h.localStart + (c.start - h.offset) * h.rate
                if let e = element(c, lane: lane, offset: local) {
                    spine[host].anchors.append(e.open + e.body.joined() + e.close)
                }
            }
        }

        let seqBody = spine.map { $0.open + $0.body.joined() + $0.anchors.joined() + $0.close }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.10">
        <resources>
        \(res.joined(separator: "\n"))
        </resources>
        <library>
        <event name="Valse">
        <project name="\(esc(name))">
        <sequence format="\(seqFormat)" duration="\(clock.fcp(total))" tcStart="0s" tcFormat="NDF" audioLayout="stereo" audioRate="48k">
        <spine>
        \(seqBody)
        </spine>
        </sequence>
        </project>
        </event>
        </library>
        </fcpxml>

        """
    }

    static func visualAdjust(_ c: Clip, canvas: Size2) -> [String] {
        var out: [String] = []
        let t = c.transform
        if t != .identity {
            // FCP: position in % of frame height from the centre, y up; rotation counter-clockwise.
            let x = t.position.x * canvas.aspect * 100, y = -t.position.y * 100
            let sx = t.scale.x * (t.flipH ? -1 : 1), sy = t.scale.y * (t.flipV ? -1 : 1)
            out.append(#"<adjust-transform position="\#(num(x)) \#(num(y))" scale="\#(num(sx)) \#(num(sy))" rotation="\#(num(-t.rotation))"/>"#)
        }
        if c.opacity < 1 { out.append(#"<adjust-blend amount="\#(num(c.opacity))"/>"#) }
        return out
    }

    // MARK: EDL (CMX 3600, main track video + linked audio)

    public static func edl(_ p: Project, name: String) -> String {
        let clock = Clock(rate: p.settings.frameRate)
        var lines = ["TITLE: \(name.uppercased())", "FCM: NON-DROP FRAME", ""]
        var n = 0
        let main = p.timeline.mainTrack?.clips ?? []
        for (i, c) in main.enumerated() {
            guard let mid = c.mediaID, let a = p.asset(mid) else { continue }
            n += 1
            let r = rate(c)
            let reel = String(a.name.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(8)).padding(toLength: 8, withPad: " ", startingAt: 0)
            let channels = a.hasAudio && a.kind == .video ? "AA/V " : (a.kind == .audio ? "AA   " : "V    ")
            let srcIn = c.sourceStart, srcOut = c.sourceStart + c.sourceDuration
            let prev = i > 0 ? main[i - 1] : nil
            if let pv = prev, let tr = pv.transitionOut, c.start < pv.end {
                // dissolve from the previous event
                lines.append(String(format: "%03d  %@ %@ D    %03lld %@ %@ %@ %@", n, reel, channels, clock.frames(tr.duration),
                                    clock.timecode(srcIn), clock.timecode(srcOut), clock.timecode(c.start), clock.timecode(c.end)))
            } else {
                lines.append(String(format: "%03d  %@ %@ C        %@ %@ %@ %@", n, reel, channels,
                                    clock.timecode(srcIn), clock.timecode(srcOut), clock.timecode(c.start), clock.timecode(c.end)))
            }
            if !c.speed.isNormal || c.reversed {
                let fps = (c.reversed ? -1 : 1) * r * p.settings.frameRate.fps
                lines.append(String(format: "M2   %@       %05.1f                %@", reel, fps, clock.timecode(srcIn)))
            }
            lines.append("* FROM CLIP NAME: \(a.name)")
            lines.append("* SOURCE FILE: \(a.url.path)")
            lines.append("")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: OpenTimelineIO

    public static func otio(_ p: Project, name: String) -> String {
        let fps = p.settings.frameRate.fps
        func rt(_ t: Time) -> [String: Any] { ["OTIO_SCHEMA": "RationalTime.1", "rate": fps, "value": (t.seconds * fps).rounded()] }
        func range(_ s: Time, _ d: Time) -> [String: Any] { ["OTIO_SCHEMA": "TimeRange.1", "start_time": rt(s), "duration": rt(d)] }
        var tracks: [[String: Any]] = []
        for t in p.timeline.tracks where t.kind == .video || t.kind == .audio || t.kind == .text {
            var children: [[String: Any]] = []
            var cursor = Time.zero
            for (i, c) in t.clips.enumerated() {
                let prev = i > 0 ? t.clips[i - 1] : nil
                let next = i + 1 < t.clips.count ? t.clips[i + 1] : nil
                let inT = (prev?.transitionOut).flatMap { tr in c.start < prev!.end ? tr.duration / 2 : nil } ?? .zero
                let outT = c.transitionOut.flatMap { tr in next.map { $0.start < c.end ? tr.duration / 2 : .zero } } ?? .zero
                let vStart = c.start + inT, vDur = c.duration - inT - outT
                if vStart > cursor { children.append(["OTIO_SCHEMA": "Gap.1", "name": "", "source_range": range(.zero, vStart - cursor)]) }
                var item: [String: Any] = ["OTIO_SCHEMA": "Clip.2", "name": c.name ?? "", "source_range": range(c.sourceStart + inT * rate(c), vDur),
                                           "metadata": ["valse": ["clip_id": "\(c.id)"]]]
                if let mid = c.mediaID, let a = p.asset(mid) {
                    item["name"] = c.name ?? a.name
                    item["media_references"] = ["DEFAULT_MEDIA": ["OTIO_SCHEMA": "ExternalReference.1", "target_url": a.url.absoluteString,
                                                                  "available_range": a.kind == .image ? NSNull() : range(.zero, a.duration) as Any]]
                    item["active_media_reference_key"] = "DEFAULT_MEDIA"
                    if !c.speed.isNormal || c.reversed {
                        item["effects"] = [["OTIO_SCHEMA": "LinearTimeWarp.1", "name": "speed", "effect_name": "LinearTimeWarp",
                                            "time_scalar": (c.reversed ? -1 : 1) * rate(c)]]
                    }
                } else if case .text(let tc) = c.content {
                    item["name"] = tc.string
                    item["media_references"] = ["DEFAULT_MEDIA": ["OTIO_SCHEMA": "GeneratorReference.1", "generator_kind": "Text",
                                                                  "parameters": ["text": tc.string]]]
                    item["active_media_reference_key"] = "DEFAULT_MEDIA"
                    item["source_range"] = range(.zero, vDur)
                } else { item["source_range"] = range(.zero, vDur) }
                children.append(item)
                if let tr = c.transitionOut, outT > .zero {
                    children.append(["OTIO_SCHEMA": "Transition.1", "name": "Cross Dissolve", "transition_type": "SMPTE_Dissolve",
                                     "in_offset": rt(tr.duration / 2), "out_offset": rt(tr.duration / 2)])
                }
                cursor = vStart + vDur
            }
            tracks.append(["OTIO_SCHEMA": "Track.1", "name": t.name ?? t.kind.rawValue, "kind": t.kind == .audio ? "Audio" : "Video",
                           "children": children])
        }
        let root: [String: Any] = ["OTIO_SCHEMA": "Timeline.1", "name": name, "global_start_time": rt(.zero),
                                   "tracks": ["OTIO_SCHEMA": "Stack.1", "name": "tracks", "children": tracks]]
        let data = (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
