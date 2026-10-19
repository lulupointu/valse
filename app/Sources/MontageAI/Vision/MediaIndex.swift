@preconcurrency import AVFoundation
import Vision
import ImageIO
import NaturalLanguage
import Foundation
import MontageCore
import MontageEngine

/// Smart media search (AI-028): each media gets Vision scene labels (`VNClassifyImageRequest` on 3 frames, English
/// taxonomy identifiers) and on-screen text (`VNRecognizeTextRequest`, fr/en), cached per content hash in
/// `Caches/Montage/mediaindex`; cached transcripts add the dialogue. Queries match labels (exact / plural /
/// English word-embedding neighbours; French queries are translated on device first when the pair is installed),
/// recognised text, dialogue and file names.
public final class MediaIndex: @unchecked Sendable {
    public static let shared = MediaIndex()

    public struct Entry: Codable, Sendable {
        public var labels: [String: Float]
        public var text: String
        /// CLIP image embeddings of the sampled frames (Float32, `ClipEmbedder.dimension` each), when the CLIP model
        /// was installed at indexing time (AI-028 free-text search).
        public var clipData: Data?

        public var clipFrames: [[Float]]? {
            guard let d = clipData, !d.isEmpty else { return nil }
            let all: [Float] = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let n = ClipEmbedder.dimension
            guard all.count >= n else { return nil }
            return stride(from: 0, to: all.count - n + 1, by: n).map { Array(all[$0..<$0 + n]) }
        }

        static func pack(_ frames: [[Float]]) -> Data? {
            frames.isEmpty ? nil : frames.flatMap { $0 }.withUnsafeBufferPointer { Data(buffer: $0) }
        }
    }

    let directory = MontagePaths.cacheDirectory.appendingPathComponent("mediaindex", isDirectory: true)
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func url(_ hash: String) -> URL { directory.appendingPathComponent("\(hash).json") }

    public func entry(_ a: MediaAsset) -> Entry? {
        if let e = lock.withLock({ entries[a.contentHash] }) { return e }
        guard let d = try? Data(contentsOf: url(a.contentHash)), let e = try? JSONDecoder().decode(Entry.self, from: d) else { return nil }
        lock.withLock { entries[a.contentHash] = e }
        return e
    }

    public func isIndexed(_ a: MediaAsset) -> Bool {
        guard a.kind != .audio, let e = entry(a) else { return a.kind == .audio }
        // entries made before the CLIP model was installed get their embeddings added
        return e.clipData != nil || !ClipEmbedder.isInstalled
    }

    /// Analyses one media (no-op when cached).
    public func index(_ a: MediaAsset) async throws {
        guard a.kind != .audio, !isIndexed(a) else { return }
        let existing = entry(a)
        var images: [CGImage] = []
        if a.kind == .image {
            if let s = CGImageSourceCreateWithURL(a.url as CFURL, nil),
               let i = CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceThumbnailMaxPixelSize: 640, kCGImageSourceCreateThumbnailFromImageAlways: true] as CFDictionary) { images = [i] }
        } else {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: a.url))
            g.maximumSize = CGSize(width: 640, height: 640); g.appliesPreferredTrackTransform = true
            for f in [0.15, 0.5, 0.85] {
                if let i = try? await g.image(at: CMTime(seconds: a.duration.seconds * f, preferredTimescale: 600)).image { images.append(i) }
            }
        }
        var labels: [String: Float] = [:], texts: [String] = [], clips: [[Float]] = []
        for img in images {
            try Task.checkCancellation()
            if existing == nil {
                let cls = VNClassifyImageRequest()
                let txt = VNRecognizeTextRequest(); txt.recognitionLanguages = ["fr-FR", "en-US"]; txt.recognitionLevel = .fast
                try VNImageRequestHandler(cgImage: img).perform([cls, txt])
                for o in cls.results ?? [] where o.confidence > 0.2 { labels[o.identifier] = max(labels[o.identifier] ?? 0, o.confidence) }
                texts += (txt.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            }
            if ClipEmbedder.isInstalled, let v = try? ClipEmbedder.shared.embed(image: img) { clips.append(v) }
        }
        var e = existing ?? Entry(labels: labels, text: texts.joined(separator: " "))
        e.clipData = Entry.pack(clips)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(e).write(to: url(a.contentHash), options: .atomic)
        lock.withLock { entries[a.contentHash] = e }
    }

    // MARK: Search

    /// CLIP relevance of each media (its best frame) for a query embedding. Raw CLIP similarities aren't comparable
    /// between pictures (a drawing scores lower than a photo for every text), so each picture is calibrated against
    /// a "neutral" caption ("a photo" / "an image" / "a picture", `neutral`): lift = query similarity − neutral
    /// similarity. A media matches when its lift is ≥ `minLift` (a specific description of a picture scores about as
    /// well as the generic caption, unrelated ones 0.06–0.15 lower; measured on the UI fixtures and bench cards), the
    /// raw similarity is plausible (≥ `minSimilarity`) and the lift is close to the best media of the set
    /// (`relativeMargin`).
    public static let minSimilarity: Float = 0.10
    public static let minLift: Float = -0.045
    public static let relativeMargin: Float = 0.03
    public static func clipRelevance(query: [Float], neutral: [Float]? = nil, embeddings: [[[Float]]?]) -> [Double] {
        let pairs: [(s: Float, lift: Float)?] = embeddings.map { frames in
            frames.flatMap { fs in
                fs.map { f -> (Float, Float) in
                    let s = ClipEmbedder.cosine(query, f)
                    return (s, neutral.map { s - ClipEmbedder.cosine($0, f) } ?? s - 0.17)
                }.max { $0.1 < $1.1 }
            }
        }
        let bestLift = pairs.compactMap { $0?.lift }.max() ?? 0
        return pairs.map { p in
            guard let p, p.s >= minSimilarity, p.lift >= minLift, p.lift >= bestLift - relativeMargin else { return 0 }
            return min(1.2, 0.4 + Double(p.lift - minLift) * 6)
        }
    }

    static let neutralPrompts = ["a photo", "an image", "a picture"]
    private var neutralEmbedding: [Float]?
    public var clipNeutral: [Float]? { lock.withLock { neutralEmbedding } }

    private var clipQueries: [String: [Float]] = [:]

    /// CLIP's zero-shot prompt template ("a photo of …") — it lifts matching similarities by ≈ 0.02–0.05.
    static func clipPrompt(_ q: String) -> String {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = t.lowercased()
        return l.hasPrefix("a photo") || l.hasPrefix("a picture") || l.hasPrefix("an image") ? t : "a photo of \(t)"
    }

    /// Cached CLIP embedding of a query (nil until `prepareClipQuery` ran, or when CLIP isn't installed).
    public func clipQuery(_ q: String) -> [Float]? { lock.withLock { clipQueries[q.lowercased()] } }

    /// Embeds a query off the main thread (first call loads the CLIP models, ~1 s). True when an embedding is ready.
    @discardableResult
    public func prepareClipQuery(_ q: String) async -> Bool {
        guard ClipEmbedder.isInstalled, !q.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if clipQuery(q) != nil { return true }
        // prompt ensemble: the raw words + the zero-shot template (footage is photos, graphics / screenshots aren't)
        let prompts = Array(Set([q, Self.clipPrompt(q)]))
        let needNeutral = clipNeutral == nil
        let (v, n): ([Float]?, [Float]?) = await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                func mean(_ ps: [String]) -> [Float]? {
                    let es = ps.compactMap { try? ClipEmbedder.shared.embed(text: $0) }
                    guard !es.isEmpty else { return nil }
                    var m = [Float](repeating: 0, count: es[0].count)
                    for e in es { for i in m.indices { m[i] += e[i] } }
                    let len = max(m.reduce(0) { $0 + $1 * $1 }.squareRoot(), 1e-9)
                    return m.map { $0 / len }
                }
                c.resume(returning: (mean(prompts), needNeutral ? mean(Self.neutralPrompts) : nil))
            }
        }
        guard let v else { return false }
        lock.withLock {
            clipQueries[q.lowercased()] = v
            if let n { neutralEmbedding = n }
        }
        return true
    }

    /// Media matching a smart search, best first: Vision labels / on-screen text / dialogue / names (`score`) plus
    /// CLIP free-text similarity when the model is installed. `english` = the query translated to English (CLIP's
    /// language); the CLIP query must have been prepared (`prepareClipQuery`) — synchronous callers (the UI) never
    /// run the model.
    public func search(_ items: [MediaAsset], query: String, english: String?) -> [MediaAsset] {
        let base = items.map { score($0, query: query, english: english) }
        var clip = [Double](repeating: 0, count: items.count)
        if let qv = clipQuery(english ?? query) ?? clipQuery(query) {
            clip = Self.clipRelevance(query: qv, neutral: clipNeutral, embeddings: items.map { $0.kind == .audio ? nil : entry($0)?.clipFrames })
        }
        return items.indices.map { (items[$0], max(base[$0], clip[$0])) }
            .filter { $0.1 > 0.3 }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Async convenience (tests, EditPilot): prepares the CLIP query, then searches.
    public func find(_ items: [MediaAsset], query: String, english: String?) async -> [MediaAsset] {
        await prepareClipQuery(english ?? query)
        return search(items, query: query, english: english)
    }

    static func norm(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).replacingOccurrences(of: "_", with: " ")
    }

    /// Built-in FR / EN query words → Vision taxonomy labels, so everyday searches work without a translation pack and
    /// where word embeddings are too far apart ("person" ↔ "people": AI QA found 0 hits for a talking person).
    static let synonyms: [String: [String]] = {
        let groups: [([String], [String])] = [
            (["person", "persons", "personne", "personnes", "gens", "humain", "humains", "human", "humans", "someone", "quelqu'un"], ["people", "adult"]),
            (["woman", "women", "femme", "femmes", "fille", "filles", "girl", "girls", "dame"], ["people", "adult"]),
            (["man", "men", "homme", "hommes", "garcon", "garcons", "boy", "boys", "monsieur"], ["people", "adult"]),
            (["child", "children", "kid", "kids", "enfant", "enfants", "bebe", "baby"], ["child", "baby", "people"]),
            (["face", "faces", "visage", "visages", "portrait", "selfie"], ["people", "portrait"]),
            (["chien", "chiens", "dog", "dogs", "chiot"], ["dog", "canine", "animal"]),
            (["chat", "chats", "cat", "cats", "chaton"], ["cat", "feline", "animal"]),
            (["animal", "animaux", "animals"], ["animal"]),
            (["voiture", "voitures", "auto", "car", "cars"], ["car", "vehicle", "automobile"]),
            (["plage", "beach"], ["beach", "shore", "sand"]),
            (["mer", "ocean", "sea"], ["sea", "ocean", "water", "beach"]),
            (["ciel", "sky"], ["sky", "cloudy", "cloud"]),
            (["montagne", "montagnes", "mountain", "mountains"], ["mountain", "hill"]),
            (["arbre", "arbres", "tree", "trees", "foret", "forest", "bois"], ["tree", "forest", "plant"]),
            (["fleur", "fleurs", "flower", "flowers"], ["flower", "plant"]),
            (["nourriture", "repas", "food", "meal", "plat"], ["food", "meal", "dish"]),
            (["boisson", "drink", "cafe", "coffee"], ["drink", "beverage", "coffee"]),
            (["ville", "city", "rue", "street"], ["city", "street", "building", "structure"]),
            (["maison", "house", "batiment", "building"], ["house", "building", "structure"]),
            (["neige", "snow"], ["snow", "winter"]),
            (["nuit", "night"], ["night", "dark"]),
            (["eau", "water"], ["water"]),
            (["texte", "text", "ecriture"], ["text", "document"]),
        ]
        var m: [String: [String]] = [:]
        for (words, labels) in groups { for w in words { m[w, default: []] += labels } }
        return m
    }()

    static func labelSynonyms(_ word: String) -> [String] { synonyms[word] ?? [] }

    /// Relevance of a media for query words (0 = no match). `english` = the query translated to English (labels).
    public func score(_ a: MediaAsset, query: String, english: String? = nil) -> Double {
        let words = Self.norm(query).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 2 }
        guard !words.isEmpty else { return 0 }
        let enWords = english.map { Self.norm($0).split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 2 } } ?? []
        let e = entry(a)
        let haystack = Self.norm([a.name, e?.text ?? "", TranscriptStore.shared.latest(hash: a.contentHash)?.text ?? ""].joined(separator: " "))
        let emb = NLEmbedding.wordEmbedding(for: .english)
        var total = 0.0
        for w in words {
            var best = haystack.contains(w) ? 1.0 : 0
            for (label, conf) in e?.labels ?? [:] {
                let l = Self.norm(label)
                for q in Set([w] + enWords + Self.labelSynonyms(w)) {
                    let singular = q.hasSuffix("s") ? String(q.dropLast()) : q
                    if l == q || l == singular || l.split(separator: " ").contains(Substring(singular)) { best = max(best, Double(conf) + 0.5) }
                    else if let emb, q.count >= 3, !l.contains(" "), emb.distance(between: q, and: l) < 0.55 { best = max(best, Double(conf) * 0.6) }
                }
            }
            total += best
        }
        return total / Double(words.count)
    }
}
