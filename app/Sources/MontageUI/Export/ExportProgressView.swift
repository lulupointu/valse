import SwiftUI
import AppKit
import AVKit
import MontageCore
import MontageEngine

/// The export window after "Export" (screenshot 114): left, the cover with "Generating… N %" then the result playing;
/// right, the outputs with progress / ETA; footer [Open folder] … [Close] [Share] (local share sheet only).
struct ExportProgressView: View {
    let store: EditorStore
    let jobs: [ExportJobItem]
    let cover: NSImage?
    let onClose: () -> Void
    @State private var player: AVPlayer?

    var running: Bool { jobs.contains(where: \.isActive) }
    var progress: Double { jobs.isEmpty ? 0 : jobs.map(\.progress).reduce(0, +) / Double(jobs.count) }
    var allDone: Bool { jobs.allSatisfy { $0.state == .done } }
    var firstVideo: URL? { jobs.lazy.flatMap { $0.written }.first { ["mov", "mp4", "m4v"].contains($0.pathExtension.lowercased()) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                preview
                VStack(alignment: .leading, spacing: 14) {
                    Text(loc: allDone ? "export.saved" : (running ? "export.generating.title" : "export.stopped"))
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(jobs) { job in JobRow(job: job, queue: store.exports.queue) }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(hex: 0x141414), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(16)
            Rectangle().fill(ExportStyle.separator).frame(height: 1)
            HStack(spacing: 10) {
                Button { reveal() } label: { Label(tr("export.openFolder"), systemImage: "folder") }
                    .buttonStyle(ExportButtonStyle(accent: false)).disabled(jobs.allSatisfy { $0.written.isEmpty })
                Spacer()
                if running {
                    Button(tr("export.stop")) { jobs.forEach(store.exports.queue.cancel) }.buttonStyle(ExportButtonStyle(accent: false))
                }
                Button(tr(running ? "export.hide" : "export.close")) { onClose() }
                    .buttonStyle(ExportButtonStyle(accent: false)).keyboardShortcut(.cancelAction)
                ShareButton(urls: jobs.flatMap(\.written)).disabled(!allDone)
            }
            .padding(.horizontal, 16).frame(height: 60)
        }
        .onChange(of: allDone) { if allDone, let u = firstVideo { player = AVPlayer(url: u); player?.play() } }
    }

    var preview: some View {
        ZStack {
            if let player, allDone {
                VideoPlayer(player: player)
            } else {
                Group { if let cover { Image(nsImage: cover).resizable().aspectRatio(contentMode: .fit) } else { Color.black } }
                Color.black.opacity(0.55)
                VStack(spacing: 8) {
                    Text(verbatim: tr("export.generating", Int((progress * 100).rounded(.down)))).font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                    ProgressView(value: progress).tint(Theme.accent).frame(width: 200)
                }
            }
        }
        .frame(width: 320, height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    func reveal() {
        let urls = jobs.flatMap(\.written)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
}

/// One job: outputs, progress bar, ETA, state, ✕ cancel / Reveal.
struct JobRow: View {
    let job: ExportJobItem
    let queue: ExportQueue
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(verbatim: job.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                Spacer()
                Text(verbatim: status).font(Theme.Fonts.hint).foregroundStyle(statusColor)
                if job.isActive {
                    Button { queue.cancel(job) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Theme.textTertiary).help(tr("export.stop"))
                } else if job.state == .done {
                    Button { NSWorkspace.shared.activateFileViewerSelecting(job.written) } label: { Image(systemName: "magnifyingglass.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Theme.textTertiary).help(tr("export.reveal"))
                }
            }
            if job.isActive { ProgressView(value: job.progress).tint(Theme.accent).controlSize(.small) }
            ForEach(job.outputs, id: \.url) { o in
                HStack(spacing: 6) {
                    Image(systemName: Self.icon(o.kind)).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).frame(width: 14)
                    Text(verbatim: o.url.lastPathComponent).font(.system(size: 11.5)).foregroundStyle(ExportStyle.label).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if job.written.contains(o.url), let size = Self.size(o.url) {
                        Text(verbatim: size).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
    }

    var status: String {
        switch job.state {
        case .queued: return tr("export.state.queued")
        case .running:
            let pct = Int((job.progress * 100).rounded(.down))
            if let eta = job.eta { return tr("export.state.runningEta", pct, Self.eta(eta)) }
            return tr("export.state.running", pct)
        case .done: return tr("export.state.done")
        case .cancelled: return tr("export.state.cancelled")
        case .failed(let m): return m
        }
    }

    var statusColor: Color {
        if case .failed = job.state { return .red }
        return job.state == .done ? Theme.accent : Theme.textSecondary
    }

    static func eta(_ s: TimeInterval) -> String {
        let f = DateComponentsFormatter(); f.allowedUnits = s >= 60 ? [.minute, .second] : [.second]; f.unitsStyle = .abbreviated
        return f.string(from: max(1, s.rounded())) ?? "\(Int(s)) s"
    }

    static func size(_ u: URL) -> String? {
        guard let n = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? Int64 else { return nil }
        return ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func icon(_ k: ExportJobSpec.OutputKind) -> String {
        switch k {
        case .video: "film"; case .audio: "waveform"; case .gif: "photo.stack"; case .captions: "captions.bubble"; case .timeline: "list.bullet.rectangle"
        }
    }
}

/// macOS share sheet for the exported files (local; no upload by Montage itself).
struct ShareButton: NSViewRepresentable {
    let urls: [URL]
    func makeNSView(context: Context) -> NSButton {
        let b = NSButton(title: tr("export.share"), target: context.coordinator, action: #selector(Coordinator.share(_:)))
        b.bezelStyle = .rounded
        b.bezelColor = NSColor(red: 0x57 / 255, green: 0xBE / 255, blue: 0xCB / 255, alpha: 1)
        return b
    }
    func updateNSView(_ b: NSButton, context: Context) { context.coordinator.urls = urls; b.title = tr("export.share") }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject {
        var urls: [URL] = []
        @objc func share(_ sender: NSButton) {
            NSSharingServicePicker(items: urls).show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}

/// Title-bar export indicator (next to the Export button): progress ring while jobs run; click → queue popover.
struct ExportQueueButton: View {
    @Bindable var queue: ExportQueue
    @State private var open = false
    var body: some View {
        if !queue.items.isEmpty {
            Button { open.toggle() } label: {
                ZStack {
                    Circle().stroke(Theme.control, lineWidth: 2.5)
                    if let p = queue.overallProgress {
                        Circle().trim(from: 0, to: p).stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
                    } else {
                        Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.accent)
                    }
                }
                .frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("export.queue"))
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(loc: "export.queue").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        Spacer()
                        Button(tr("export.queue.clear")) { queue.clearFinished() }.buttonStyle(.plain).font(Theme.Fonts.hint).foregroundStyle(Theme.accent)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) { ForEach(queue.items.reversed()) { JobRow(job: $0, queue: queue) } }
                    }.frame(maxHeight: 320)
                }
                .padding(14).frame(width: 360).background(Theme.menu)
            }
        }
    }
}
