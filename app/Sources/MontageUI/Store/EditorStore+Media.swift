import SwiftUI
import AppKit
import MontageCore
import MontageEngine

/// Media pipeline flows of the editor: import (breadth, folders, sequences, Live Photos, captions, fonts),
/// background conversion, media bin folders, relinking and consolidation.
extension EditorStore {
    /// Import entry point (button, ⌘I, Finder drop). `folder` = bin folder the files go into (imported directories
    /// keep their structure below it). Caption files become a caption track, font files are installed.
    public func importMedia(_ urls: [URL], thenInsertAt time: Time? = nil, target: InsertTarget = .automatic, folder: MediaFolderID? = nil) {
        let captions = urls.filter { CaptionFile.extensions.contains($0.pathExtension.lowercased()) }
        let fonts = urls.filter { FontLibrary.extensions.contains($0.pathExtension.lowercased()) }
        for c in captions { importCaptions(from: c) }   // F3: dropped caption files become a real caption track (origin, lyrics for LRC)
        if !fonts.isEmpty { importFonts(fonts) }
        let items = MediaProbe.expandWithFolders(urls.filter { !captions.contains($0) && !fonts.contains($0) })
        guard !items.isEmpty else { return }
        let folderOf = Dictionary(items.map { ($0.url, $0.folderPath) }, uniquingKeysWith: { a, _ in a })
        Task {
            let (assets, failed) = await Task.detached { await Self.probeImport(items.map(\.url)) }.value
            if !failed.isEmpty { showToast(tr("toast.importFailed", failed.count), error: true) }
            guard !assets.isEmpty else { return }
            let existing = Dictionary(project.media.map { ($0.contentHash, $0) }, uniquingKeysWith: { a, _ in a })
            let fresh = assets.filter { existing[$0.contentHash] == nil }
            if !fresh.isEmpty {
                let paths = fresh.map { folderOf[$0.url] ?? [] }
                perform(Edit("cmd.import") { p in
                    var add: [MediaAsset] = []
                    for (a, path) in zip(fresh, paths) {
                        var a = a
                        a.folderID = path.isEmpty ? folder : try BinOps.ensurePath(path, under: folder, in: &p)
                        add.append(a)
                    }
                    try AddMedia(add).apply(to: &p)
                })
            }
            let all = assets.map { existing[$0.contentHash] ?? $0 }
            if !fresh.isEmpty && copiesMediaOnImport { copyMediaToProject(quiet: true) }
            await PlayableMediaCache.shared.request(all)
            convertPending.formUnion(all.filter { PlayableMediaCache.shared.isPending($0) }.map(\.contentHash))
            await ProxyManager.shared.request(all)
            proxyPending.formUnion(all.filter { ProxyManager.shared.isPending($0) }.map(\.contentHash))
            offerTranscode(fresh)   // MI-009
            if let time {
                var t = time
                for a in all {
                    addToTimeline(a.id, at: t, target: target)
                    t += a.defaultClipDuration
                }
            }
            for a in all { Task.detached { _ = await ThumbnailCache.shared.thumbnail(a, at: .zero, height: 96) } }
        }
    }

    /// Probing with Live Photo pairing and image-sequence detection (off-main).
    nonisolated static func probeImport(_ urls: [URL]) async -> (assets: [MediaAsset], failed: [URL]) {
        let (pairs, rest0) = LivePhoto.pair(urls)
        let (seqs, rest) = MediaProbe.detectSequences(rest0)
        var (assets, failed) = await MediaProbe.probeAll(pairs.map(\.still) + rest)
        for i in assets.indices {
            if let pair = pairs.first(where: { $0.still == assets[i].url }) { assets[i].livePhotoVideoURL = pair.video }
        }
        for s in seqs {
            if let a = try? MediaProbe.probeSequence(first: s.first, info: s.info) { assets.append(a) } else { failed.append(s.first) }
        }
        return (assets, failed)
    }

    /// Hooks engine callbacks (called once from init).
    func installMediaPipelineHooks() {
        PlayableMediaCache.shared.onReady = { [weak self] hash in
            guard let self else { return }
            self.convertPending.remove(hash)
            guard let a = self.project.media.first(where: { $0.contentHash == hash }) else { return }
            self.engine.forceRebuild()
            Task {
                await ProxyManager.shared.request([a])
                if ProxyManager.shared.isPending(a) { self.proxyPending.insert(hash) }
            }
        }
        Task.detached { FontLibrary.loadAll() }
    }

    /// Conversions for media of an opened project (GIF / sequences / FFmpeg-only formats whose cache was cleared).
    func requestConversions(_ media: [MediaAsset]) {
        Task {
            await PlayableMediaCache.shared.request(media)
            convertPending.formUnion(media.filter { PlayableMediaCache.shared.isPending($0) }.map(\.contentHash))
        }
    }

    // MARK: Bin folders

    public func createFolder(in parent: MediaFolderID?) -> MediaFolderID? {
        let before = Set(project.folders.map(\.id))
        guard perform(BinCommand.createFolder(BinOps.uniqueName(tr("media.folder.new"), parent: parent, in: project), parent: parent)) else { return nil }
        return project.folders.first { !before.contains($0.id) }?.id
    }

    public func renameFolder(_ id: MediaFolderID, to name: String) { perform(BinCommand.rename(id, name)) }
    public func deleteFolder(_ id: MediaFolderID) { perform(BinCommand.deleteFolder(id)) }
    public func moveMedia(_ ids: Set<MediaID>, to folder: MediaFolderID?) { perform(BinCommand.moveMedia(ids, to: folder)) }
    public func moveFolder(_ id: MediaFolderID, to parent: MediaFolderID?) { perform(BinCommand.moveFolder(id, to: parent)) }

    // MARK: Missing media / relink

    public func isMissing(_ a: MediaAsset) -> Bool { MediaRelinker.isMissing(a) }

    /// "Link media": points `id` at `url`, then looks in that file's folder for every other missing item.
    public func linkMedia(_ id: MediaID, to url: URL) {
        Task {
            let probed = try? await MediaProbe.probe(url)
            let others = MediaRelinker.missing(in: project).filter { $0.id != id }
            let folder = url.deletingLastPathComponent()
            MediaAutoRelink.remember(folder)
            let found = await Task.detached { MediaRelinker.search(folder, for: others) }.value
            let ok = perform(Edit("cmd.relink") { p in
                if let i = p.media.firstIndex(where: { $0.id == id }) {
                    let keep = p.media[i]
                    if var n = probed {
                        n.id = keep.id; n.name = keep.name; n.folderID = keep.folderID
                        p.media[i] = n
                    } else {
                        p.media[i].url = url
                    }
                    p.media[i].relativePath = nil
                }
                MediaRelinker.apply(found, to: &p)
            })
            if ok { showToast(tr("toast.relinked", found.count + 1)) }
        }
    }

    /// Batch relink of every missing item found under `folder` ("Link media when selecting a folder").
    public func relinkMissing(searching folder: URL) {
        let missing = MediaRelinker.missing(in: project)
        guard !missing.isEmpty else { return }
        MediaAutoRelink.remember(folder)
        Task {
            let found = await Task.detached { MediaRelinker.search(folder, for: missing) }.value
            if found.isEmpty { showToast(tr("toast.relinkNone"), error: true); return }
            perform(Edit("cmd.relink") { MediaRelinker.apply(found, to: &$0) })
            showToast(tr("toast.relinked", found.count))
        }
    }

    // MARK: Copy media to project (consolidate)

    /// `quiet`: after an import with "Import material: Copy to project" (SE-010), no toast.
    public func copyMediaToProject(quiet: Bool = false) {
        if packageURL == nil { save() }
        guard let pkg = packageURL else { return }
        let snapshot = project
        Task {
            let box = MapBox()
            let id = await JobQueue.shared.enqueue(titleKey: "job.consolidate", priority: 1) { progress in
                box.map = try MediaConsolidator.consolidate(snapshot, packageURL: pkg) { progress.report($0) }
            }
            guard await JobQueue.shared.wait(id) == .done else { showToast(tr("toast.consolidateFailed"), error: true); return }
            let map = box.map
            guard !map.isEmpty else { return }
            perform(Edit("cmd.consolidate") { MediaRelinker.apply(map, to: &$0) })
            if !quiet { showToast(tr("toast.consolidated", map.count)) }
        }
    }

    // MARK: Live Photo

    /// Puts the Live Photo's motion video on the timeline ("Apply as a LIVE photo").
    public func addLivePhotoVideo(_ id: MediaID) {
        guard let still = project.asset(id), let video = still.livePhotoVideoURL else { return }
        Task {
            guard var a = try? await MediaProbe.probe(video) else { showToast(tr("toast.importFailed", 1), error: true); return }
            if let e = project.media.first(where: { $0.contentHash == a.contentHash }) { a = e } else {
                a.folderID = still.folderID
                perform(AddMedia([a]))
            }
            addToTimeline(a.id)
        }
    }

    // MARK: Captions & fonts

    public func importCaptions(_ url: URL) {
        Task {
            let result = await Task.detached { () -> Result<[CaptionCue], CaptionFile.ParseError> in
                do { return .success(try CaptionFile.load(url)) } catch let e as CaptionFile.ParseError { return .failure(e) } catch { return .failure(.unreadable) }
            }.value
            switch result {
            case .success(let cues):
                let style = TextContent(string: "", fontSize: 0.05)
                if perform(Edit("cmd.importCaptions") { p in try CaptionFile.insert(cues, style: style, into: &p) }) {
                    showToast(tr("toast.captionsImported", cues.count))
                }
            case .failure:
                showToast(tr("toast.captionsFailed"), error: true)
            }
        }
    }

    public func importFonts(_ urls: [URL]) {
        Task {
            let names = await Task.detached { (try? FontLibrary.importFonts(urls)) ?? [] }.value
            FontCatalog.invalidate(); TextUIState.shared.fontsRevision += 1   // MI-021 (F3): font book / picker re-list
            if names.isEmpty { showToast(tr("toast.fontsFailed"), error: true) } else { showToast(tr("toast.fontsInstalled", names.count)) }
        }
    }

    // MARK: Generators

    /// Built-in colour clips (CapCut Library ▸ black video / colour canvas).
    public func addColorClip(_ color: RGBA, nameKey: String) {
        var c = Clip(content: .solid(color), start: transport.playhead, duration: Time(3))
        c.name = tr(nameKey)
        guard perform(InsertClip(c, target: .automatic)) else { return }
        selection = [c.id]
    }
}

nonisolated final class MapBox: @unchecked Sendable { var map: [MediaID: URL] = [:] }

// MARK: Playback lag → transcode (MI-009)

extension EditorStore {
    /// Imported videos likely to lag that get no proxy on their own: show "Your media may cause playback lag".
    func offerTranscode(_ assets: [MediaAsset]) {
        let heavy = assets.filter { !PlaybackLagAdvisor.reasons($0).isEmpty && ProxyManager.shared.readyProxyURL(for: $0) == nil
            && !ProxyManager.shared.isPending($0) }
        guard !heavy.isEmpty else { return }
        timelineUI.lagPrompt = heavy.map(\.id)
    }

    /// [Transcode]: make edit proxies now (preview switches to them when ready; export keeps the originals).
    public func transcodeForPlayback(_ ids: [MediaID]) {
        timelineUI.lagPrompt = nil
        let assets = project.media.filter { ids.contains($0.id) }
        guard !assets.isEmpty else { return }
        if !playerUI.usesProxies { setUsesProxies(true) }
        Task {
            await ProxyManager.shared.request(assets, force: true)
            proxyPending.formUnion(assets.filter { ProxyManager.shared.isPending($0) }.map(\.contentHash))
        }
        showToast(tr("lag.transcoding", assets.count))
    }
}

/// "Your media may cause playback lag" banner above the timeline (MI-009): reasons, [Transcode] [Ignore].
struct PlaybackLagPrompt: View {
    let store: EditorStore
    let ids: [MediaID]
    var body: some View {
        let assets = store.project.media.filter { ids.contains($0.id) }
        let reasons = Array(Set(assets.flatMap(PlaybackLagAdvisor.reasons))).sorted { $0.rawValue < $1.rawValue }
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(red: 0.91, green: 0.70, blue: 0.23))
            Text(verbatim: tr("lag.prompt", assets.count) + " (" + reasons.map { tr($0.nameKey) }.joined(separator: ", ") + ")")
                .font(.system(size: 12)).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.tail)
            Spacer()
            Button(tr("lag.transcode")) { store.transcodeForPlayback(ids) }
                .buttonStyle(SecondaryButtonStyle()).controlSize(.small).testID("lag.transcode")
            Button(tr("lag.ignore")) { store.timelineUI.lagPrompt = nil }
                .buttonStyle(SecondaryButtonStyle()).controlSize(.small).testID("lag.ignore")
        }
        .padding(.horizontal, 12).frame(height: 34)
        .background(Color(red: 0.91, green: 0.70, blue: 0.23).opacity(0.12))
        .testID("lag.prompt")
    }
}
