import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ValseCore
import ValseEngine

/// File ▸ Import timeline (FCPXML)… (MI-018): the sequence opens as a new timeline tab of this project; its media
/// are probed and added to the bin (already-imported files are reused); missing files are reported.
extension EditorStore {
    public func importTimelinePanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = ["fcpxml", "fcpxmld", "xml"].compactMap { UTType(filenameExtension: $0) }
        p.treatsFilePackagesAsDirectories = false
        guard p.runModal() == .OK, let url = p.url else { return }
        importTimeline(from: url)
    }

    public func importTimeline(from url: URL) {
        // an .fcpxmld bundle holds Info.fcpxml
        let file = url.pathExtension == "fcpxmld" ? url.appendingPathComponent("Info.fcpxml") : url
        guard let data = try? Data(contentsOf: file), let seq = try? FCPXMLImport.parse(data) else {
            showToast(tr("importTimeline.failed"), error: true); return
        }
        Task {
            let urls = Array(Set(seq.assets.values.map(\.url))).filter { FileManager.default.fileExists(atPath: $0.path) }
            let (probed, _) = await Task.detached { await MediaProbe.probeAll(urls) }.value
            let existing = Dictionary(project.media.map { ($0.contentHash, $0) }, uniquingKeysWith: { a, _ in a })
            let byURL = Dictionary(probed.map { ($0.url.standardizedFileURL, existing[$0.contentHash] ?? $0) }, uniquingKeysWith: { a, _ in a })
            var media: [String: MediaAsset] = [:]
            for (k, a) in seq.assets { if let m = byURL[a.url.standardizedFileURL] { media[k] = m } }
            let fresh = Array(Set(media.values.map(\.id))).compactMap { id in media.values.first { $0.id == id } }
                .filter { existing[$0.contentHash] == nil }
            let missing = seq.assets.count - media.count
            let tl = FCPXMLImport.timeline(seq, media: media)
            var settings = project.settings
            if let r = seq.frameRate { settings.frameRate = r }
            if let s = seq.size, s.width > 0, s.height > 0 { settings.canvasSize = s }
            let name = seq.name, first = tr("timelines.nameN", 1), seqSettings = settings
            engine.pause()
            if perform(Edit("cmd.importTimeline") { p in
                if !fresh.isEmpty { try AddMedia(fresh).apply(to: &p) }
                CompoundEditing.exitAll(&p)
                try MultiTimelineOps.newTimeline(&p, name: name, firstName: first, settings: seqSettings)
                p.timeline = tl
            }) {
                selection = []
                seek(to: .zero)
                showToast(missing > 0 ? tr("importTimeline.missing", name, missing) : tr("importTimeline.done", name), error: missing > 0)
                await ProxyManager.shared.request(fresh)
            }
        }
    }
}
