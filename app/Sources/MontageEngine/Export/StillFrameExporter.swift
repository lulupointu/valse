import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import MontageCore

/// "Export still frame" (EX-012): the frame at a time, at full canvas resolution (or a target short side), PNG or JPEG.
/// Also produces the export cover (JPEG data for the artwork metadata and the dialog preview).
public enum StillFrameExporter {
    public enum Format: String, Codable, Sendable, CaseIterable {
        case png, jpeg
        public var fileExtension: String { self == .png ? "png" : "jpg" }
        var uti: CFString { (self == .png ? UTType.png : UTType.jpeg).identifier as CFString }
        public static func from(extension ext: String) -> Format { ["jpg", "jpeg"].contains(ext.lowercased()) ? .jpeg : .png }
    }

    /// Renders `time` (canvas size by default; `shortSide` scales it) through the export compositor.
    public static func image(project: Project, at time: Time, shortSide: Int? = nil) async throws -> CGImage {
        var p = project
        p.settings.colorSpace = .sdr709     // stills are SDR (HDR projects are tone-mapped)
        let c = p.settings.canvasSize
        var size = CGSize(width: c.width, height: c.height)
        if let s = shortSide {
            let k = Double(s) / min(c.width, c.height)
            size = CGSize(width: (c.width * k / 2).rounded() * 2, height: (c.height * k / 2).rounded() * 2)
        }
        return try await OfflineRenderer.renderFrame(p, at: time, size: size)
    }

    public static func encode(_ img: CGImage, format: Format, quality: Double = 0.92) throws -> Data {
        let data = NSMutableData()
        guard let d = CGImageDestinationCreateWithData(data, format.uti, 1, nil) else { throw ExportError.failed("image destination") }
        CGImageDestinationAddImage(d, img, format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary : nil)
        guard CGImageDestinationFinalize(d) else { throw ExportError.failed("image encode") }
        return data as Data
    }

    public static func export(project: Project, at time: Time, format: Format? = nil, to url: URL, shortSide: Int? = nil) async throws {
        guard project.duration > .zero else { throw ExportError.emptyProject }
        let img = try await image(project: project, at: time, shortSide: shortSide)
        try encode(img, format: format ?? .from(extension: url.pathExtension)).write(to: url, options: .atomic)
    }

    /// Cover JPEG (≤ 1280 px short side) for artwork metadata / dialog preview.
    public static func coverJPEG(project: Project, at time: Time) async throws -> Data {
        let short = min(project.settings.canvasSize.width, project.settings.canvasSize.height)
        let img = try await image(project: project, at: time, shortSide: Int(min(short, 720)))
        return try encode(img, format: .jpeg, quality: 0.85)
    }
}
