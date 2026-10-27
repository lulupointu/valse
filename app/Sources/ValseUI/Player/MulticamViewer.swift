import SwiftUI
import AppKit
import ValseCore
import ValseEngine
import Perception

// MARK: Store (TL-024)

extension EditorStore {
    /// Selected multi-camera clip (single selection), if any.
    var selectedMulticam: ClipID? {
        guard let c = singleSelectedClip, Multicam.compound(of: c.id, in: project) != nil else { return nil }
        return c.id
    }

    /// Right-click ▸ Create multi-camera clip ▸ Sync by audio / by timeline position.
    public func createMulticam(syncByAudio: Bool) {
        let clips = project.timeline.allClips.filter { selection.contains($0.id) && $0.mediaID.flatMap(project.asset)?.kind == .video }
            .sorted { $0.start < $1.start }
        guard clips.count >= 2 else { showToast(tr("multicam.needTwo"), error: true); return }
        guard clips.count <= Multicam.maxAngles else { showToast(tr("multicam.tooMany", Multicam.maxAngles), error: true); return }
        let ids = clips.map(\.id)
        let name = tr("multicam.name")
        func finish(_ starts: [ClipID: Time]) {
            let box = ResultBox(ClipID())
            if edit("cmd.multicam", { p in box.value = try Multicam.create(ids, starts: starts, name: name, in: &p) }) {
                selection = [box.value]
                playerUI.multicamGrid = true
                showToast(tr("multicam.created", ids.count))
            }
        }
        guard syncByAudio else { finish(Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0.start) })); return }
        let assets = Dictionary(uniqueKeysWithValues: project.media.map { ($0.id, $0) })
        let box = AudioResultBox<[ClipID: Time]>([:])
        let ref = clips[0]
        Task {
            let job = await JobQueue.shared.enqueue(titleKey: "job.sync", priority: 1) { _ in
                func mono(_ c: Clip) async throws -> [Float] {
                    guard let a = c.mediaID.flatMap({ assets[$0] }), a.hasAudio else { return [] }
                    return try await AudioFileIO.read(a.url, sampleRate: AudioAnalysis.onsetSampleRate, channels: 1,
                                                      range: c.sourceRange).channel(0)
                }
                let r = try await mono(ref)
                box.update { $0[ref.id] = ref.start }
                for c in clips.dropFirst() {
                    let other = try await mono(c)
                    let off = r.isEmpty || other.isEmpty ? 0 : await Task.detached { AudioAnalysis.syncOffset(r, other, maxLag: 20) }.value
                    box.update { $0[c.id] = r.isEmpty || other.isEmpty ? c.start : ref.start + Time(-off) }
                }
            }
            guard await JobQueue.shared.wait(job) == .done else { showToast(tr("audio.error.analysis"), error: true); return }
            finish(box.value)
        }
    }

    /// Angle grid click / 1–9: cut to angle `k` at the playhead.
    public func switchMulticamAngle(_ k: Int) {
        guard let id = selectedMulticam else { return }
        let t = playhead
        edit("cmd.switchAngle") { p in try Multicam.switchAngle(id, to: k, at: t, in: &p) }
    }
}

@MainActor
enum MulticamShortcuts {
    static let all: [Shortcut] = (1...9).map { k in
        Shortcut("multicamAngle\(k)", "multicam.angleShortcut.\(k)", .char(Character("\(k)")),
                 isEnabled: { $0.selectedMulticam != nil }) { $0.switchMulticamAngle(k - 1) }
    }
}

// MARK: Viewer (PB-016)

/// 2×2 / 3×3 angle grid (top-left of the player, the program output stays visible) while a multi-camera clip is selected: each cell shows its angle at the
/// playhead (thumbnail, refreshed as it moves), the live angle is outlined; a click (or 1–9) cuts to it.
struct MulticamGrid: View {
    @Perception.Bindable var store: EditorStore
    @Perception.Bindable var ui: PlayerUIState
    var body: some View {
        WithPerceptionTracking {
            if ui.multicamGrid, let id = store.selectedMulticam, let comp = Multicam.compound(of: id, in: store.project) {
                let n = Multicam.angleTracks(comp.timeline).count
                let cols = n <= 4 ? 2 : 3
                let t = store.transport.playhead
                let active = Multicam.activeAngle(id, at: t, in: store.project)
                VStack(spacing: 4) {
                    ForEach(0..<Int((Double(n) / Double(cols)).rounded(.up)), id: \.self) { r in
                        WithPerceptionTracking {
                            HStack(spacing: 4) {
                                ForEach(0..<cols, id: \.self) { c in
                                    WithPerceptionTracking {
                                        let k = r * cols + c
                                        if k < n {
                                            AngleCell(store: store, clipID: id, angle: k, time: t, active: active == k)
                                        } else {
                                            Color.clear
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(4)
                .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: 380, maxHeight: 230)   // compact angle viewer; the program output stays visible
                .aspectRatio(16 / 10, contentMode: .fit)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .testID("multicam.grid")
            }
        }
    }
}

struct AngleCell: View {
    let store: EditorStore
    let clipID: ClipID
    let angle: Int
    let time: Time
    let active: Bool
    @State private var image: CGImage?
    var body: some View {
        WithPerceptionTracking {
            Button { store.switchMulticamAngle(angle) } label: {
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color(white: 0.12))
                    if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit) }
                    Text(verbatim: "\(angle + 1)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(active ? Theme.accent : Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                        .padding(4)
                }
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(active ? Theme.accent : Color.white.opacity(0.15), lineWidth: active ? 2 : 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .testID("multicam.angle.\(angle)")
            .task(id: Int(time.seconds * 4)) { await load() }
        }
    }

    func load() async {
        guard let (m, src) = Multicam.angleSource(clipID, angle: angle, at: time, in: store.project), let a = store.project.asset(m) else { return }
        if let c = ThumbnailCache.shared.cached(a, at: src, height: 180) { image = c; return }
        image = await ThumbnailCache.shared.thumbnail(a, at: src, height: 180)
    }
}
