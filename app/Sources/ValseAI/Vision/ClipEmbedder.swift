import CoreML
import Vision
import CoreGraphics
import Foundation
import ValseCore

/// CLIP byte-level BPE tokenizer (OpenAI `simple_tokenizer.py`, as used by OpenCLIP): lower-cased text, CLIP's
/// pre-tokenizer pattern, byte → unicode mapping, merges by rank, `</w>` word ends, `<|startoftext|>` … `<|endoftext|>`
/// padded with 0 to 77 tokens.
public final class CLIPTokenizer: @unchecked Sendable {
    public static let contextLength = 77
    let encoder: [String: Int32]
    let ranks: [String: Int]
    let byteEncoder: [Character]
    public let sot: Int32, eot: Int32
    private var cache: [String: [Int32]] = [:]
    private let lock = NSLock()
    static let pattern = try! NSRegularExpression(
        pattern: #"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#,
        options: [.caseInsensitive])

    public init(vocab: URL, merges: URL) throws {
        let v = try JSONDecoder().decode([String: Int32].self, from: Data(contentsOf: vocab))
        encoder = v
        let lines = try String(contentsOf: merges, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: true)
        var r: [String: Int] = [:]
        for (i, l) in lines.dropFirst().enumerated() {   // first line: "#version: …"
            r[String(l)] = i
        }
        ranks = r
        // GPT-2 / CLIP bytes_to_unicode
        var bs = Array(33...126) + Array(161...172) + Array(174...255)
        var cs = bs
        var n = 0
        for b in 0..<256 where !bs.contains(b) { bs.append(b); cs.append(256 + n); n += 1 }
        var table = [Character](repeating: " ", count: 256)
        for (b, c) in zip(bs, cs) { table[b] = Character(Unicode.Scalar(UInt32(c))!) }
        byteEncoder = table
        sot = v["<|startoftext|>"] ?? 49406
        eot = v["<|endoftext|>"] ?? 49407
    }

    func bpe(_ token: String) -> [String] {
        var word = token.map { String($0) }
        guard !word.isEmpty else { return [] }
        word[word.count - 1] += "</w>"
        while word.count > 1 {
            var best: (Int, Int)? = nil
            for i in 0..<(word.count - 1) {
                if let r = ranks[word[i] + " " + word[i + 1]], r < (best?.1 ?? .max) { best = (i, r) }
            }
            guard let (i, _) = best else { break }
            let a = word[i], b = word[i + 1]
            var merged: [String] = []
            var j = 0
            while j < word.count {
                if j < word.count - 1 && word[j] == a && word[j + 1] == b { merged.append(a + b); j += 2 }
                else { merged.append(word[j]); j += 1 }
            }
            word = merged
        }
        return word
    }

    /// Token ids of `text` without start / end markers.
    public func encode(_ text: String) -> [Int32] {
        let clean = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var out: [Int32] = []
        let ns = clean as NSString
        for m in Self.pattern.matches(in: clean, range: NSRange(location: 0, length: ns.length)) {
            let piece = ns.substring(with: m.range)
            if let c = lock.withLock({ cache[piece] }) { out += c; continue }
            let mapped = String(piece.utf8.map { byteEncoder[Int($0)] })
            let ids = bpe(mapped).compactMap { encoder[$0] }
            lock.withLock { cache[piece] = ids }
            out += ids
        }
        return out
    }

    /// The 77-token model input: SOT, tokens (truncated), EOT, zero padding.
    public func tokens(_ text: String) -> [Int32] {
        var t = [sot] + encode(text).prefix(Self.contextLength - 2) + [eot]
        t += [Int32](repeating: 0, count: Self.contextLength - t.count)
        return t
    }
}

/// CLIP image / text embeddings (AI-028 free-text media search) with the `ModelCatalog.clip` Core ML models.
/// Embeddings are L2-normalised, so the dot product is the cosine similarity (CLIP ViT-B/32: matching image-text
/// pairs ≈ 0.25–0.35, unrelated ≈ 0.10–0.20). Models load lazily on first use and stay loaded (≈ 450 MB) until
/// `unload()` (memory pressure / tests).
public final class ClipEmbedder: @unchecked Sendable {
    public static let shared = ClipEmbedder()
    public static let dimension = 512

    private let lock = NSLock()
    private var image: MLModel?
    private var text: MLModel?
    private var tokenizer: CLIPTokenizer?
    private var textCache: [String: [Float]] = [:]

    /// The model is downloaded (cheap check).
    public static var isInstalled: Bool { ModelCatalog.installedURL(ModelCatalog.clip) != nil }

    public func unload() { lock.withLock { image = nil; text = nil; tokenizer = nil; textCache = [:] } }

    private func load() throws -> (MLModel, MLModel, CLIPTokenizer) {
        try lock.withLock {
            if let image, let text, let tokenizer { return (image, text, tokenizer) }
            guard let dir = ModelCatalog.installedURL(ModelCatalog.clip) else { throw AIToolError.modelMissing(ModelCatalog.clip.id) }
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .all
            let i = try MLModel(contentsOf: dir.appendingPathComponent("CLIP_ImageEncoder.mlmodelc"), configuration: cfg)
            let t = try MLModel(contentsOf: dir.appendingPathComponent("CLIP_TextEncoder.mlmodelc"), configuration: cfg)
            let tok = try CLIPTokenizer(vocab: dir.appendingPathComponent("vocab.json"), merges: dir.appendingPathComponent("merges.txt"))
            image = i; text = t; tokenizer = tok
            return (i, t, tok)
        }
    }

    static func normalized(_ a: MLMultiArray) -> [Float] {
        let n = a.count
        var v = [Float](repeating: 0, count: n)
        if a.dataType == .float32 {
            let p = a.dataPointer.bindMemory(to: Float.self, capacity: n)
            for i in 0..<n { v[i] = p[i] }
        } else {
            for i in 0..<n { v[i] = a[i].floatValue }
        }
        let len = max(v.reduce(0) { $0 + $1 * $1 }.squareRoot(), 1e-9)
        return v.map { $0 / len }
    }

    /// Image embedding (the model resizes + centre-crops to 224², normalisation is inside the model).
    public func embed(image cg: CGImage) throws -> [Float] {
        let (img, _, _) = try load()
        guard let desc = img.modelDescription.inputDescriptionsByName["image"], let c = desc.imageConstraint else { throw AIToolError.noInput }
        let fv = try MLFeatureValue(cgImage: cg, constraint: c, options: [.cropAndScale: VNImageCropAndScaleOption.centerCrop.rawValue])
        let out = try img.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": fv]))
        guard let name = out.featureNames.first, let arr = out.featureValue(for: name)?.multiArrayValue else { throw AIToolError.noInput }
        return Self.normalized(arr)
    }

    /// Text embedding of an (English) query; cached per string.
    public func embed(text query: String) throws -> [Float] {
        let key = query.lowercased()
        if let v = lock.withLock({ textCache[key] }) { return v }
        let (_, txt, tok) = try load()
        let ids = tok.tokens(query)
        let arr = try MLMultiArray(shape: [1, NSNumber(value: CLIPTokenizer.contextLength)], dataType: .int32)
        for (i, t) in ids.enumerated() { arr[i] = NSNumber(value: t) }
        let out = try txt.prediction(from: MLDictionaryFeatureProvider(dictionary: ["text": MLFeatureValue(multiArray: arr)]))
        guard let name = out.featureNames.first, let e = out.featureValue(for: name)?.multiArrayValue else { throw AIToolError.noInput }
        let v = Self.normalized(e)
        lock.withLock { textCache[key] = v }
        return v
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var s: Float = 0
        for i in 0..<a.count { s += a[i] * b[i] }
        return s
    }
}
