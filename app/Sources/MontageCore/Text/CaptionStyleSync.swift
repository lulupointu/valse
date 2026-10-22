import Foundation

/// "Apply to all main captions" (C4, CapCut Text ▸ Basic checkbox, on by default): a style edit made on one caption is
/// replayed on every caption of its track, inside the same edit (one undo step, live during slider drags).
///
/// Only what the edit changed is copied — the changed `TextContent` properties (font, size, colour, stroke, background,
/// karaoke, bubble…) plus the clip's position / scale / rotation, opacity and blend — so per-caption differences that
/// weren't touched (e.g. speaker colours, a caption moved by hand when the edit was a colour change) survive. Text, runs,
/// word timings, translations and timing are never copied.
public enum CaptionStyleSync {
    /// `TextContent` properties that are per caption, never copied.
    static let excluded: Set<String> = ["string", "runs", "caption", "template", "counter"]

    /// Replays on the siblings of `source` (same caption track) the look changes `source` received between `before`
    /// and `after`. No-op when `source` isn't a caption, its look didn't change, or the edit already restyled others.
    /// `coEdited` = other clips the same edit was fanned out to (C2 multi-select): their change doesn't count as
    /// "already restyled", so editing several selected captions still restyles the whole track.
    public static func propagate(from source: ClipID, coEdited: Set<ClipID> = [], before: Project, after: inout Project) {
        guard let old = before.timeline.clip(source), let new = after.timeline.clip(source),
              let t0 = CaptionOps.text(old), let t1 = CaptionOps.text(new), t1.caption != nil,
              let loc = after.timeline.locate(source), CaptionOps.isCaptionTrack(after.timeline.tracks[loc.track]) else { return }
        let lookChanged = !t0.sameLook(as: t1) || t0.caption?.subStyle != t1.caption?.subStyle || t0.caption?.display != t1.caption?.display
        let clipChanged = old.transform != new.transform || old.opacity != new.opacity || old.blendMode != new.blendMode
        guard lookChanged || clipChanged else { return }
        let ti = loc.track
        let siblings = after.timeline.tracks[ti].clips.indices.filter { after.timeline.tracks[ti].clips[$0].id != source }
        // the edit restyled other captions itself (templates, "apply to all"…): leave it alone
        if let bt = before.timeline.trackIndex(after.timeline.tracks[ti].id) {
            let beforeByID = Dictionary(before.timeline.tracks[bt].clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for i in siblings {
                let c = after.timeline.tracks[ti].clips[i]
                if coEdited.contains(c.id) { continue }
                if let b = beforeByID[c.id], let tb = CaptionOps.text(b), let tc = CaptionOps.text(c), !tb.sameLook(as: tc) { return }
            }
        }
        let diff = lookChanged ? Diff(t0, t1) : nil
        for i in siblings {
            var c = after.timeline.tracks[ti].clips[i]
            guard case .text(var t) = c.content, t.caption != nil else { continue }
            if let diff {
                diff.apply(to: &t)
                if t0.caption?.subStyle != t1.caption?.subStyle { t.caption?.subStyle = t1.caption?.subStyle }
                if t0.caption?.display != t1.caption?.display, t.caption?.translation != nil { t.caption?.display = t1.caption?.display }
                c.content = .text(t)
            }
            if old.transform != new.transform { c.transform = new.transform }
            if old.opacity != new.opacity { c.opacity = new.opacity }
            if old.blendMode != new.blendMode { c.blendMode = new.blendMode }
            after.timeline.tracks[ti].clips[i] = c
        }
    }

    /// The `TextContent` properties that differ between two looks. Known properties are copied through key paths
    /// (fast enough for every tick of a slider drag over hundreds of captions); anything else (a property added later)
    /// goes through a JSON merge so it is never silently skipped.
    struct Diff {
        var copies: [(inout TextContent, TextContent) -> Void] = []
        var source: TextContent
        var jsonKeys: [String: Any] = [:]
        var jsonRemoved: [String] = []

        init(_ a: TextContent, _ b: TextContent) {
            source = b
            var probe = a
            for f in Self.fields where !f.equal(a, b) {
                copies.append(f.copy)
                f.copy(&probe, b)
            }
            if !probe.sameLook(as: b), let ja = Self.json(a), let jb = Self.json(b) {
                for k in Set(ja.keys).union(jb.keys) where !excluded.contains(k) && !Self.knownKeys.contains(k) {
                    let va = ja[k].map { $0 as AnyObject }, vb = jb[k].map { $0 as AnyObject }
                    if let vb, !(va?.isEqual(vb) ?? false) { jsonKeys[k] = vb } else if vb == nil, va != nil { jsonRemoved.append(k) }
                }
            }
        }

        func apply(to t: inout TextContent) {
            for c in copies { c(&t, source) }
            guard !jsonKeys.isEmpty || !jsonRemoved.isEmpty, var j = Self.json(t) else { return }
            for (k, v) in jsonKeys { j[k] = v }
            for k in jsonRemoved { j[k] = nil }
            if let d = try? JSONSerialization.data(withJSONObject: j), let n = try? JSONDecoder().decode(TextContent.self, from: d) { t = n }
        }

        static func json(_ t: TextContent) -> [String: Any]? {
            guard let d = try? JSONEncoder().encode(t) else { return nil }
            return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        }

        struct Field: Sendable {
            let name: String
            let equal: @Sendable (TextContent, TextContent) -> Bool
            let copy: @Sendable (inout TextContent, TextContent) -> Void
        }
        static func f<V: Equatable & Sendable>(_ name: String, _ kp: WritableKeyPath<TextContent, V> & Sendable) -> Field {
            Field(name: name, equal: { $0[keyPath: kp] == $1[keyPath: kp] }, copy: { $0[keyPath: kp] = $1[keyPath: kp] })
        }
        static let fields: [Field] = [
            f("fontName", \.fontName), f("fontSize", \.fontSize), f("color", \.color), f("alignment", \.alignment),
            f("bold", \.bold), f("italic", \.italic), f("strokeColor", \.strokeColor), f("strokeWidth", \.strokeWidth),
            f("backgroundColor", \.backgroundColor), f("shadowColor", \.shadowColor), f("lineSpacing", \.lineSpacing),
            f("letterSpacing", \.letterSpacing), f("styleID", \.styleID), f("underline", \.underline), f("textCase", \.textCase),
            f("orientation", \.orientation), f("extraStrokes", \.extraStrokes), f("background", \.background), f("shadow", \.shadow),
            f("glow", \.glow), f("fill", \.fill), f("curve", \.curve), f("path", \.path), f("boxWidth", \.boxWidth),
            f("bubbleID", \.bubbleID), f("bubbleColor", \.bubbleColor), f("karaoke", \.karaoke),
        ]
        static let knownKeys = Set(fields.map(\.name))
    }
}
