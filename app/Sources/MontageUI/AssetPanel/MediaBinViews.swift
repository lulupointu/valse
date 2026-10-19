import SwiftUI
import UniformTypeIdentifiers
import MontageCore
import MontageEngine

/// Media-bin folder UI pieces used by `MediaTab` (MI-002/004/005/006/007/012/026).

/// Breadcrumb "Media › Footage › Day 1" (click a crumb to go up).
struct BinBreadcrumb: View {
    let store: EditorStore
    @Binding var folder: MediaFolderID?
    var body: some View {
        HStack(spacing: 4) {
            crumb(tr("media.folder.root"), nil)
            ForEach(BinOps.path(to: folder, in: store.mediaBin)) { f in
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
                crumb(f.name, f.id)
            }
            Spacer()
        }
        .padding(.horizontal, 12).frame(height: 22)
    }

    func crumb(_ title: String, _ id: MediaFolderID?) -> some View {
        Text(verbatim: title).font(.system(size: 11))
            .foregroundStyle(id == folder ? Theme.textPrimary : Theme.textTertiary)
            .lineLimit(1)
            .onTapGesture { folder = id }
            .onDrop(of: [.text], isTargeted: nil) { providers in dropMedia(providers, into: id, store: store) }
    }
}

/// Folder card in the media grid: double-click opens, drop media onto it, context menu Rename / Delete.
struct FolderCard: View {
    let store: EditorStore
    let folder: MediaFolder
    @Binding var current: MediaFolderID?
    @State private var hover = false
    @State private var targeted = false
    @State private var renaming = false
    @State private var newName = ""

    var count: Int { BinOps.media(in: folder.id, of: store.mediaBin).count + BinOps.children(of: folder.id, in: store.mediaBin).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Theme.inset)
                Image(systemName: "folder.fill").font(.system(size: 26)).foregroundStyle(Theme.accent.opacity(0.8))
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay(alignment: .bottomTrailing) {
                Text(verbatim: "\(count)").font(.system(size: 10).monospacedDigit())
                    .padding(.horizontal, 4).padding(.vertical, 1).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3)).padding(4)
            }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(hover || targeted ? Theme.accent : .clear, lineWidth: 1.5))
            Text(verbatim: folder.name).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { current = folder.id }
        .onDrag { NSItemProvider(object: BinPayload.folder(folder.id) as NSString) }
        .onDrop(of: [.text], isTargeted: $targeted) { providers in dropMedia(providers, into: folder.id, store: store) }
        .contextMenu {
            Button(tr("media.folder.open")) { current = folder.id }
            Button(tr("media.folder.rename")) { newName = folder.name; renaming = true }
            Divider()
            Button(tr("media.folder.delete"), role: .destructive) { store.deleteFolder(folder.id) }
        }
        .alert(tr("media.folder.rename"), isPresented: $renaming) {
            TextField(tr("media.folder.name"), text: $newName)
            Button(tr("common.ok")) { store.renameFolder(folder.id, to: newName) }
            Button(tr("common.cancel"), role: .cancel) {}
        }
    }
}

enum BinPayload {
    static func folder(_ id: MediaFolderID) -> String { "montage-folder:\(id.raw.uuidString)" }
    static func parseFolder(_ s: String) -> MediaFolderID? {
        guard s.hasPrefix("montage-folder:") else { return nil }
        return MediaFolderID(string: String(s.dropFirst("montage-folder:".count)))
    }
}

/// Handles a media-card or folder drag dropped on a folder (or the root crumb).
@MainActor func dropMedia(_ providers: [NSItemProvider], into folder: MediaFolderID?, store: EditorStore) -> Bool {
    var handled = false
    for p in providers where p.canLoadObject(ofClass: NSString.self) {
        handled = true
        _ = p.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? String else { return }
            Task { @MainActor in
                if let fid = BinPayload.parseFolder(s) {
                    if fid != folder { store.moveFolder(fid, to: folder) }
                } else if case .media(let id)? = DragPayload.parse(s) {
                    store.moveMedia([id], to: folder)
                }
            }
        }
    }
    return handled
}

/// Context menu of a media card.
struct MediaCardMenu: View {
    let store: EditorStore
    let asset: MediaAsset
    @Binding var showInfo: Bool
    var body: some View {
        Button(tr("asset.addToTrack")) { store.addToTimeline(asset.id) }
        if asset.livePhotoVideoURL != nil {
            Button(tr("media.livePhoto.apply")) { store.addLivePhotoVideo(asset.id) }
        }
        if store.isMissing(asset) {
            Button(tr("media.link")) { LinkMediaPanel.run(store, asset) }
            Button(tr("media.linkFolder")) { LinkMediaPanel.runFolder(store) }
        }
        if asset.kind == .video {
            Button(tr("lag.transcodeMenu")) { store.transcodeForPlayback([asset.id]) }   // MI-009
        }
        Button(tr("media.info")) { showInfo = true }
        Button(tr("media.showInFinder")) { NSWorkspace.shared.activateFileViewerSelecting([asset.url]) }
        Divider()
        Menu(tr("media.moveTo")) {
            Button(tr("media.folder.root")) { store.moveMedia([asset.id], to: nil) }
            ForEach(store.mediaBin.folders) { f in
                Button(BinOps.path(to: f.id, in: store.mediaBin).map(\.name).joined(separator: " › ")) { store.moveMedia([asset.id], to: f.id) }
            }
        }
        Button(tr("media.copyToProject")) { store.copyMediaToProject() }
    }
}

/// "Material info" (MI-005).
struct MediaInfoView: View {
    let asset: MediaAsset
    var rows: [(String, String)] {
        var r: [(String, String)] = [(tr("media.info.name"), asset.name), (tr("media.info.path"), asset.url.path)]
        if asset.kind != .image { r.append((tr("media.info.duration"), Timecode.shortDuration(asset.duration))) }
        if asset.pixelSize.width > 0 { r.append((tr("media.info.resolution"), "\(Int(asset.pixelSize.width))×\(Int(asset.pixelSize.height))")) }
        if let f = asset.frameRate { r.append((tr("media.info.fps"), String(format: "%.2f", f.fps) + (asset.techInfo?.isVariableFrameRate == true ? " (VFR)" : ""))) }
        if let c = asset.codec { r.append((tr("media.info.codec"), c)) }
        if let i = asset.techInfo {
            if let b = i.bitrate, b > 0 { r.append((tr("media.info.bitrate"), String(format: "%.1f Mb/s", Double(b) / 1_000_000))) }
            if let a = i.audioCodec { r.append((tr("media.info.audio"), "\(a) · \(Int(i.audioSampleRate ?? 0)) Hz · \(i.audioChannels ?? 0) ch")) }
            if let n = i.audioTrackCount, n > 1 { r.append((tr("media.info.audioTracks"), "\(n)")) }
            if i.hasAlpha == true { r.append((tr("media.info.alpha"), tr("common.yes"))) }
            if let p = i.colorPrimaries { r.append((tr("media.info.color"), p + (i.transferFunction.map { " / \($0)" } ?? ""))) }
        }
        r.append((tr("media.info.size"), ByteCountFormatter.string(fromByteCount: asset.fileSize, countStyle: .file)))
        return r
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(loc: "media.info").font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.textPrimary)
            ForEach(rows, id: \.0) { InfoRow($0.0, $0.1) }
        }
        .padding(14).frame(width: 340)
    }
}

enum LinkMediaPanel {
    @MainActor static func run(_ store: EditorStore, _ asset: MediaAsset) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = false
        p.message = tr("media.link.message", asset.name)
        p.prompt = tr("media.link")
        p.directoryURL = asset.url.deletingLastPathComponent()
        if p.runModal() == .OK, let u = p.url { store.linkMedia(asset.id, to: u) }
    }

    @MainActor static func runFolder(_ store: EditorStore) {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.message = tr("media.linkFolder.message")
        p.prompt = tr("media.link")
        if p.runModal() == .OK, let u = p.url { store.relinkMissing(searching: u) }
    }
}
