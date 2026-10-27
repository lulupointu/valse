import AppKit
import ValseCore
import ValseEffects
import ValseEngine

/// OB-05: what the empty-track context menu's "Paste" would insert.
enum TimelinePasteContent: Equatable {
    /// Timeline items copied in Valse (on the pasteboard, or the in-app clipboard).
    case items
    /// Importable media files (Finder copy).
    case files([URL])
    /// A bitmap (screenshot, image copied from a browser…).
    case image
    /// Plain text: becomes a text clip.
    case text(String)

    /// Longest pasted text kept for a text clip.
    static let maxTextLength = 1000

    /// Reads the pasteboard: Valse clips first, then files (only importable ones: a Finder copy of other files is not
    /// pasteable, even though it carries the file icon and name too), a bitmap, text, and last the in-app clipboard
    /// (older than anything another app copied since, which replaced the pasteboard payload).
    static func read(_ pb: NSPasteboard, hasInternalItems: Bool) -> TimelinePasteContent? {
        if pb.data(forType: ClipboardPayload.type) != nil { return .items }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let ok = urls.filter(MediaProbe.isImportable)
            return ok.isEmpty ? nil : .files(ok)
        }
        if pb.availableType(from: [.png, .tiff]) != nil { return .image }
        if let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return .text(String(s.prefix(maxTextLength)))
        }
        return hasInternalItems ? .items : nil
    }
}

extension EditorStore {
    /// OB-05: what "Paste" on an empty part of the timeline would insert (nil = the item is greyed out).
    func timelinePasteContent(_ pb: NSPasteboard = AppPasteboard.general) -> TimelinePasteContent? {
        TimelinePasteContent.read(pb, hasInternalItems: !ui.clipboard.isEmpty)
    }

    /// OB-05: pastes the clipboard at `time` (the right-clicked point; the playhead does not move). Copied clips keep
    /// their tracks (TimelineOps.paste); files are imported onto `target`; a bitmap is saved as a PNG and imported; text
    /// becomes a 3 s text clip (default style) on a new text track.
    func paste(at time: Time, target: InsertTarget = .automatic, from pb: NSPasteboard = AppPasteboard.general) {
        guard let content = timelinePasteContent(pb) else { return }
        switch content {
        case .items:
            var items = ui.clipboard
            var assets: [MediaAsset] = []
            if let data = pb.data(forType: ClipboardPayload.type),
               let payload = try? JSONDecoder().decode(ClipboardPayload.self, from: data) {
                items = payload.items; assets = payload.assets
            }
            pasteItems(items, assets: assets, at: time)
        case .files(let urls):
            importFiles(urls, thenInsertAt: time, target: target)
        case .image:
            guard let url = Self.savePastedImage(pb) else { return }
            importFiles([url], thenInsertAt: time, target: target)
        case .text(let s):
            var t = TextContent(string: s)
            BuiltinTextStyles.basics.first?.apply(&t)
            let c = Clip(content: .text(t), start: time, duration: Time(3))
            if perform(InsertClip(c, target: .automatic, nameKey: "cmd.text")) { selection = [c.id] }
        }
    }

    /// Pasted bitmaps are written to Application Support/Valse/Pasted Media/<uuid>.png (the project references them
    /// like any imported file).
    static func savePastedImage(_ pb: NSPasteboard) -> URL? {
        guard let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let dir = ValsePaths.supportDirectory.appendingPathComponent("Pasted Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        do { try png.write(to: url) } catch { return nil }
        return url
    }
}
