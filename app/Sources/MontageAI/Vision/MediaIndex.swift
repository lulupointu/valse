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

    public func isIndexed(_ a: MediaAsset) -> Bool { a.kind == .audio || entry(a) != nil }

    /// Analyses one media (no-op when cached).
    public func index(_ a: MediaAsset) async throws {
        guard a.kind != .audio, entry(a) == nil else { return }
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
        var labels: [String: Float] = [:], texts: [String] = []
        for img in images {
            try Task.checkCancellation()
            let cls = VNClassifyImageRequest()
            let txt = VNRecognizeTextRequest(); txt.recognitionLanguages = ["fr-FR", "en-US"]; txt.recognitionLevel = .fast
            try VNImageRequestHandler(cgImage: img).perform([cls, txt])
            for o in cls.results ?? [] where o.confidence > 0.2 { labels[o.identifier] = max(labels[o.identifier] ?? 0, o.confidence) }
            texts += (txt.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        }
        let e = Entry(labels: labels, text: texts.joined(separator: " "))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(e).write(to: url(a.contentHash), options: .atomic)
        lock.withLock { entries[a.contentHash] = e }
    }

    // MARK: Search

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
