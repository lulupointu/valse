import SwiftUI
import AppKit
import Observation
import MontageCore
import MontageEngine

/// Screen / webcam recorder (MI-015 "Record screen" ⇧⌘R, MI-017 camera): an in-window modal like Export.
/// Setup (source, camera + layout, microphone, cursor) → 3-2-1 countdown → recording (timer, pause/resume, stop) →
/// the files are imported into the bin and placed on the timeline at the playhead (camera as a picture-in-picture
/// overlay on its own track, or nested with the screen into one compound clip for "Single track").
@MainActor @Observable
public final class RecorderModel {
    public enum Phase: String, Sendable { case setup, countdown, recording, saving }

    public var mode: RecordingSession.Mode
    public var phase: Phase = .setup
    public var countdown = 3
    public var sources: [ScreenSource] = []
    public var sourceID: String = ""
    public var showsCursor = true
    public var microphone = true
    public var microphoneID = ""
    public var camera = false
    public var cameraID = ""
    public var layout: RecordingSession.Layout = .separate
    public var cameras: [CaptureDevices.Device] = []
    public var microphones: [CaptureDevices.Device] = []
    public var permissions: [RecordingPermission.Kind: RecordingPermission.Status] = [:]
    public var elapsed: Double = 0
    public var paused = false
    public var errorKey: String?
    @ObservationIgnored var session: RecordingSession?
    @ObservationIgnored var timer: Timer?
    @ObservationIgnored var task: Task<Void, Never>?

    init(mode: RecordingSession.Mode) {
        self.mode = mode
        camera = mode == .camera
        refresh()
    }

    /// Permissions this setup needs (screen mode: screen [+ camera] [+ mic]; camera mode: camera [+ mic]).
    var needed: [RecordingPermission.Kind] {
        var k: [RecordingPermission.Kind] = mode == .screen ? [.screen] : [.camera]
        if mode == .screen && camera { k.append(.camera) }
        if microphone { k.append(.microphone) }
        return k
    }

    /// First permission not granted yet.
    var missing: RecordingPermission.Kind? { needed.first { permissions[$0] != .granted } }

    var canStart: Bool { missing == nil && (mode == .camera || selectedSource != nil) && phase == .setup }

    var selectedSource: ScreenSource? { sources.first { key($0) == sourceID } }
    func key(_ s: ScreenSource) -> String { "\(s.kind.rawValue).\(s.id)" }

    func refresh() {
        for k in RecordingPermission.Kind.allCases { permissions[k] = RecordingPermission.status(k) }
        // UI tests / unit tests (sandboxed permissions): no machine-dependent devices/windows, never a system prompt
        guard !TestAnchors.isEnabled, RecordingPermission.override == nil else { return }
        cameras = CaptureDevices.cameras()
        microphones = CaptureDevices.microphones()
        if permissions[.screen] == .granted && sources.isEmpty {
            Task {
                let s = (try? await ScreenCapture.sources()) ?? []
                sources = s
                if selectedSource == nil, let first = s.first { sourceID = key(first) }
            }
        }
    }

    func request(_ k: RecordingPermission.Kind) {
        Task {
            permissions[k] = await RecordingPermission.request(k)
            refresh()
        }
    }

    func openSettings(_ k: RecordingPermission.Kind) {
        guard !TestAnchors.isEnabled else { return }
        NSWorkspace.shared.open(RecordingPermission.settingsURL(k))
    }

    var dump: [String: Any] {
        ["mode": mode.rawValue, "phase": phase.rawValue, "missing": missing?.rawValue ?? "", "canStart": canStart,
         "camera": camera, "microphone": microphone, "showsCursor": showsCursor, "layout": layout.rawValue,
         "permissions": Dictionary(uniqueKeysWithValues: permissions.map { ($0.key.rawValue, $0.value.rawValue) })]
    }
}

/// Global recorder state (one recording at a time), read by the editor overlay and the state dump.
@MainActor @Observable
public final class RecordingUI {
    public static let shared = RecordingUI()
    public var model: RecorderModel?
    var dump: [String: Any] { model.map { ["open": true].merging($0.dump) { a, _ in a } } ?? ["open": false] }
}

extension EditorStore {
    /// File ▸ Record screen (⇧⌘R) / Record camera.
    public func openRecorder(_ mode: RecordingSession.Mode) {
        if TestAnchors.isEnabled && RecordingPermission.override == nil { RecordingPermission.override = [:] }
        if let m = RecordingUI.shared.model, m.phase != .setup { return }   // a recording is running
        engine.pause()
        RecordingUI.shared.model = RecorderModel(mode: mode)
    }

    func closeRecorder() {
        guard let m = RecordingUI.shared.model else { return }
        m.timer?.invalidate(); m.task?.cancel()
        if let s = m.session { Task { await s.cancel() } }
        RecordingUI.shared.model = nil
    }

    func startRecording(_ m: RecorderModel) {
        guard m.canStart else { return }
        var o = RecordingSession.Options(mode: m.mode)
        o.screen = m.selectedSource
        o.showsCursor = m.showsCursor
        o.microphone = m.microphone
        o.microphoneID = m.microphoneID.isEmpty ? nil : m.microphoneID
        o.camera = m.mode == .camera || m.camera
        o.cameraID = m.cameraID.isEmpty ? nil : m.cameraID
        o.layout = m.layout
        m.phase = .countdown
        m.countdown = 3
        m.errorKey = nil
        m.task = Task {
            for n in stride(from: 3, through: 1, by: -1) {
                m.countdown = n
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
            let s = RecordingSession(options: o)
            do {
                try await s.start(screenName: tr("record.file.screen"), cameraName: tr("record.file.camera"))
            } catch {
                await s.cancel()
                m.phase = .setup; m.errorKey = "record.error.start"
                return
            }
            m.session = s
            m.phase = .recording
            m.elapsed = 0
            let t = Timer(timeInterval: 0.25, repeats: true) { [weak m] _ in
                MainActor.assumeIsolated { if let m, let s = m.session { m.elapsed = s.recordedSeconds } }
            }
            RunLoop.main.add(t, forMode: .common)
            m.timer = t
        }
    }

    func togglePauseRecording(_ m: RecorderModel) {
        guard let s = m.session else { return }
        if m.paused { s.resume() } else { s.pause() }
        m.paused.toggle()
    }

    func stopRecording(_ m: RecorderModel) {
        guard let s = m.session else { return }
        m.timer?.invalidate()
        m.phase = .saving
        Task {
            do {
                let r = try await s.stop()
                m.session = nil
                RecordingUI.shared.model = nil
                await placeRecording(r)
            } catch {
                m.session = nil
                m.phase = .setup; m.errorKey = "record.error.empty"
            }
        }
    }

    /// Imports the recorded files and puts them at the playhead (one undo step): screen (or camera-only) on the main
    /// track, the camera as a bottom-right picture-in-picture on a new track; "Single track" nests both in a compound.
    func placeRecording(_ r: RecordingSession.Result) async {
        let urls = [r.screenURL, r.cameraURL].compactMap { $0 }
        let (assets, _) = await Task.detached { await Self.probeImport(urls) }.value
        guard let main = assets.first(where: { $0.url == r.primary }) else { showToast(tr("record.error.import"), error: true); return }
        let cam = r.screenURL != nil ? assets.first { $0.url == r.cameraURL } : nil
        let at = transport.playhead
        let single = r.layout == .single && cam != nil
        let name = tr("record.compound")
        let box = UncheckedSendableBox<ClipID?>(nil)
        let pip = Self.cameraPiP
        let ok = perform(Edit("cmd.record") { p in
            try AddMedia([main] + (cam.map { [$0] } ?? [])).apply(to: &p)
            let clip = TimelineOps.makeClip(for: main, at: at)
            _ = try TimelineOps.insert(clip, into: &p)
            var ids: Set<ClipID> = [clip.id]
            if let cam {
                var c = TimelineOps.makeClip(for: cam, at: p.timeline.clip(clip.id)?.start ?? at)
                c.transform = pip
                _ = try TimelineOps.insert(c, into: &p, target: .newTrack)
                ids.insert(c.id)
                if single { box.value = try TimelineOps.createCompound(ids, name: name, in: &p) }
            }
            if box.value == nil { box.value = clip.id }
        })
        guard ok else { return }
        if let id = box.value { selection = [id] }
        Task { await ProxyManager.shared.request([main] + (cam.map { [$0] } ?? [])) }
        showToast(tr("record.saved"))
    }

    /// Camera overlay placement: bottom-right, 30 % size (CapCut's default camera bubble corner).
    static let cameraPiP = Transform(position: Vec2(0.32, -0.3), scale: Vec2(0.3, 0.3))
}

@MainActor
enum RecordingShortcuts {
    static let all: [Shortcut] = [
        Shortcut("recordScreen", "record.menu.screen", .char("r"), [.command, .shift]) { $0.openRecorder(.screen) },
        Shortcut("closeRecorder", "record.close", .escape,
                 isEnabled: { _ in RecordingUI.shared.model?.phase == .setup }) { $0.closeRecorder() },
    ]
}

// MARK: - View

struct RecorderModal: View {
    @Bindable var store: EditorStore
    @Bindable var model: RecorderModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture {}
            DialogCard(title: tr(model.mode == .screen ? "record.title.screen" : "record.title.camera"), width: 520,
                       onClose: model.phase == .setup ? { store.closeRecorder() } : nil) {
                VStack(alignment: .leading, spacing: 14) {
                    switch model.phase {
                    case .setup: setup
                    case .countdown: big(Text(verbatim: "\(model.countdown)").font(.system(size: 64, weight: .bold)).foregroundStyle(Theme.accent),
                                         caption: tr("record.countdown")).testID("record.countdown")
                    case .recording: recording
                    case .saving: big(ProgressView().controlSize(.large), caption: tr("record.saving"))
                    }
                }
                .padding(16)
            }
            .testID("record.dialog")
            // offscreen snapshots redraw the modal above the panels / Metal views (SnapshotRegistry.modalFrame)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { SnapshotRegistry.shared.modalFrame = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { _, f in SnapshotRegistry.shared.modalFrame = f }
            })
        }
        .onDisappear { SnapshotRegistry.shared.modalFrame = nil }
    }

    func big<V: View>(_ v: V, caption: String) -> some View {
        VStack(spacing: 10) {
            v
            Text(verbatim: caption).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    @ViewBuilder var setup: some View {
        SubTabBar(items: [("screen", tr("record.tab.screen")), ("camera", tr("record.tab.camera"))], selection: model.mode.rawValue) { v in
            model.mode = v == "camera" ? .camera : .screen
            if model.mode == .camera { model.camera = true }
        }
        .testID("record.modeTabs")
        if let k = model.missing { permissionCard(k) }
        if let e = model.errorKey {
            Text(loc: e).font(.system(size: 12)).foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4)).testID("record.error")
        }
        VStack(alignment: .leading, spacing: 12) {
            if model.mode == .screen {
                row(tr("record.source")) {
                    if model.sources.isEmpty {
                        Text(loc: "record.source.none").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    } else {
                        Dropdown(items: model.sources.map { s in
                            (model.key(s), s.kind == .display ? tr("record.source.display", s.name, Int(s.size.width), Int(s.size.height)) : s.name)
                        }, selection: model.sourceID) { model.sourceID = $0 }
                        .frame(width: 300)
                    }
                }
                row(tr("record.cursor")) { SwitchButton(isOn: $model.showsCursor, id: "record.cursor", label: tr("record.cursor")) }
                row(tr("record.camera")) {
                    HStack(spacing: 10) {
                        SwitchButton(isOn: $model.camera, id: "record.camera", label: tr("record.camera"))
                        if model.camera { deviceMenu(model.cameras, selection: $model.cameraID) }
                    }
                }
                if model.camera {
                    row(tr("record.layout")) {
                        HStack(spacing: 14) {
                            RadioLine(label: tr("record.layout.separate"), selected: model.layout == .separate, id: "record.separate") { model.layout = .separate }
                            RadioLine(label: tr("record.layout.single"), selected: model.layout == .single, id: "record.single") { model.layout = .single }
                        }
                    }
                }
            } else {
                row(tr("record.camera")) { deviceMenu(model.cameras, selection: $model.cameraID) }
            }
            row(tr("record.microphone")) {
                HStack(spacing: 10) {
                    SwitchButton(isOn: $model.microphone, id: "record.microphone", label: tr("record.microphone"))
                    if model.microphone { deviceMenu(model.microphones, selection: $model.microphoneID) }
                }
            }
            HintText(text: tr(model.mode == .screen ? "record.hint.screen" : "record.hint.camera"))
        }
        .padding(14)
        .background(Theme.inset.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        DialogFooter(okTitle: tr("record.start"), okEnabled: model.canStart, onCancel: { store.closeRecorder() },
                     onOK: { store.startRecording(model) })
    }

    func deviceMenu(_ list: [CaptureDevices.Device], selection: Binding<String>) -> some View {
        Dropdown(items: [("", tr("record.device.default"))] + list.map { ($0.id, $0.name) }, selection: selection.wrappedValue) {
            selection.wrappedValue = $0
        }
        .frame(width: 220)
    }

    func permissionCard(_ k: RecordingPermission.Kind) -> some View {
        let denied = model.permissions[k] == .denied
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield").font(.system(size: 18)).foregroundStyle(Color(red: 0.91, green: 0.70, blue: 0.23))
            VStack(alignment: .leading, spacing: 8) {
                Text(loc: "record.permission.\(k.rawValue)").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(loc: denied ? "record.permission.denied" : "record.permission.ask").font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if denied {
                        Button(tr("record.permission.openSettings")) { model.openSettings(k) }
                            .buttonStyle(SecondaryButtonStyle()).controlSize(.small).testID("record.openSettings")
                        Button(tr("record.permission.recheck")) { model.refresh() }
                            .buttonStyle(SecondaryButtonStyle()).controlSize(.small).testID("record.recheck")
                    } else {
                        Button(tr("record.permission.allow")) { model.request(k) }
                            .buttonStyle(SecondaryButtonStyle()).controlSize(.small).testID("record.allow")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(red: 0.91, green: 0.70, blue: 0.23).opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .testID("record.permission")
    }

    @ViewBuilder var recording: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(model.paused ? Theme.textTertiary : Color.red).frame(width: 10, height: 10)
                Text(loc: model.paused ? "record.paused" : "record.recording").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(verbatim: Self.clock(model.elapsed)).font(.system(size: 40, weight: .medium).monospacedDigit()).foregroundStyle(.white)
                .testID("record.elapsed")
            HStack(spacing: 12) {
                Button { store.togglePauseRecording(model) } label: {
                    Label(tr(model.paused ? "record.resume" : "record.pause"), systemImage: model.paused ? "record.circle" : "pause.fill")
                        .frame(width: 140, height: 32)
                        .background(Theme.buttonSecondary, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).testID("record.pause")
                Button { store.stopRecording(model) } label: {
                    Label(tr("record.stop"), systemImage: "stop.fill").frame(width: 140, height: 32)
                        .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).testID("record.stop")
            }
            .foregroundStyle(.white)
            HintText(text: tr("record.hint.recording"))
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    func row<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(alignment: .center, spacing: 0) {
            Text(verbatim: label).font(.system(size: 12)).foregroundStyle(IStyle.label).frame(width: 130, alignment: .leading)
            c()
            Spacer(minLength: 0)
        }
        .frame(minHeight: 28)
    }

    static func clock(_ s: Double) -> String {
        let t = Int(s)
        return String(format: "%02d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }
}

/// Media tab ▸ empty bin: "No media? Create with these tools" + big Record buttons (UX.md §2.3; Generate is out of scope).
struct RecordTools: View {
    let store: EditorStore
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Rectangle().fill(Theme.separator).frame(height: 1)
                Text(loc: "record.tools.caption").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary).fixedSize()
                Rectangle().fill(Theme.separator).frame(height: 1)
            }
            HStack(spacing: 10) {
                tool("record.tool.screen", "rectangle.dashed.badge.record", id: "media.record.screen") { store.openRecorder(.screen) }
                tool("record.tool.camera", "web.camera", id: "media.record.camera") { store.openRecorder(.camera) }
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
    }

    func tool(_ key: String, _ symbol: String, id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 18))
                Text(loc: key).font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Theme.control, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .testID(id)
    }
}
