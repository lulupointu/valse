import SwiftUI
import MontageCore
import MontageEngine
import Perception

/// Voice-over recorder popover (timeline toolbar 🎙, MI-016): input device, live level meter, echo reduction, mute the
/// project while recording, 3-2-1 countdown, then records from the playhead while the timeline plays; Stop inserts
/// the clip on an audio track at the start position.
struct VoiceoverPanel: View {
    let store: EditorStore
    @State private var recorder = VoiceRecorder()
    @State private var devices: [VoiceRecorder.InputDevice] = VoiceRecorder.inputDevices()
    @State private var device: UInt32 = AudioDevices.id(forUID: AppPreferences.shared.settings.audioInputDeviceUID,
                                                         in: AudioDevices.inputs()) ?? 0
    @State private var echoReduction = false
    @State private var muteProject = true
    @State private var phase: Phase = .idle
    @State private var level: Float = 0
    @State private var elapsed: Double = 0
    @State private var permission = VoiceRecorder.permission
    @State private var startTime: Time = .zero
    @State private var ticker: Task<Void, Never>?
    @State private var errorKey: String?

    enum Phase: Equatable { case idle, countdown(Int), recording }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 12) {
                Text(loc: "record.title").font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.textPrimary)
                if permission == .denied {
                    Text(loc: "record.permissionDenied").font(Theme.Fonts.hint).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(tr("record.openSettings")) {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(u) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                } else {
                    HStack {
                        Text(loc: "record.input").font(Theme.Fonts.row).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Picker(tr("record.input"), selection: $device) {
                            Text(loc: "record.input.default").tag(UInt32(0))
                            ForEach(devices) { Text(verbatim: $0.name).tag($0.id) }
                        }
                        .labelsHidden().frame(width: 180).disabled(phase != .idle)
                    }
                    // level meter
                    GeometryReader { g in
                        WithPerceptionTracking {
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3).fill(Theme.inset)
                                RoundedRectangle(cornerRadius: 3).fill(level > 0.9 ? Theme.danger : Theme.accent)
                                    .frame(width: g.size.width * CGFloat(min(1, sqrt(level))))
                            }
                        }
                    }
                    .frame(height: 6)
                    ToggleRow(tr("record.echoReduction"), isOn: $echoReduction).disabled(phase != .idle)
                    ToggleRow(tr("record.muteProject"), isOn: $muteProject).disabled(phase != .idle)
                    HStack {
                        Spacer()
                        Button(action: toggle) {
                            ZStack {
                                Circle().stroke(Color.white.opacity(0.8), lineWidth: 2).frame(width: 46, height: 46)
                                if phase == .recording {
                                    RoundedRectangle(cornerRadius: 3).fill(Theme.danger).frame(width: 18, height: 18)
                                } else if case .countdown(let n) = phase {
                                    Text(verbatim: "\(n)").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.textPrimary)
                                } else {
                                    Circle().fill(Theme.danger).frame(width: 34, height: 34)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .help(tr(phase == .recording ? "record.stop" : "record.start"))
                        Spacer()
                    }
                    Text(verbatim: phase == .recording ? Timecode.shortDuration(Time(elapsed)) : tr("record.hint"))
                        .font(Theme.Fonts.hint.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                    if let errorKey { Text(loc: errorKey).font(Theme.Fonts.hint).foregroundStyle(Theme.dangerText) }
                }
            }
            .padding(16)
            .frame(width: 300)
            .onAppear { Task { await prepare() } }
            .onDisappear { stopAll(insert: phase == .recording) }
        }
    }

    private func prepare() async {
        if permission == .undetermined { permission = await VoiceRecorder.requestPermission() ? .granted : .denied }
        guard permission == .granted else { return }
        startMetering()
    }

    private func startMetering() {
        do { try recorder.start(device: device == 0 ? nil : device, echoReduction: echoReduction, recordTo: nil); errorKey = nil }
        catch { errorKey = "record.error.device" }
        runTicker()
    }

    private func runTicker() {
        ticker?.cancel()
        ticker = Task { @MainActor in
            while !Task.isCancelled {
                level = recorder.level
                if phase == .recording { elapsed = recorder.duration.seconds }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func toggle() {
        switch phase {
        case .idle: countdown()
        case .countdown: phase = .idle
        case .recording: stopAll(insert: true); startMetering()
        }
    }

    private func countdown() {
        phase = .countdown(3)
        Task { @MainActor in
            for n in [3, 2, 1] {
                guard case .countdown = phase else { return }
                phase = .countdown(n)
                try? await Task.sleep(for: .seconds(1))
            }
            guard case .countdown = phase else { return }
            begin()
        }
    }

    private func begin() {
        let url = store.nextRecordingURL
        do {
            try recorder.start(device: device == 0 ? nil : device, echoReduction: echoReduction, recordTo: url)
        } catch { errorKey = "record.error.device"; phase = .idle; return }
        startTime = store.transport.playhead
        if muteProject { store.engine.player.isMuted = true }
        if !store.engine.isPlaying { store.togglePlay() }
        elapsed = 0
        phase = .recording
        runTicker()
    }

    private func stopAll(insert: Bool) {
        ticker?.cancel()
        let wasRecording = phase == .recording
        let url = recorder.stop()
        if wasRecording {
            if store.engine.isPlaying { store.togglePlay() }
            store.engine.player.isMuted = false
            store.seek(to: startTime)
        }
        phase = .idle
        if insert, wasRecording, let url { store.insertRecording(url, at: startTime) }
    }
}

/// Timeline toolbar 🎙 "Voiceover" (opens the recorder popover).
struct VoiceoverButton: View {
    let store: EditorStore
    @State private var shown = false
    var body: some View {
        WithPerceptionTracking {
            IconButton("mic", help: tr("toolbar.voiceover"), active: shown) { shown.toggle() }
                .popover(isPresented: $shown, arrowEdge: .bottom) { WithPerceptionTracking { VoiceoverPanel(store: store) } }
        }
    }
}

/// Timeline toolbar ♥ for audio clips (UX [132]): None / Beats 1 / Beats 2 (auto) + Mark beat (manual, M).
struct BeatsMenu: View {
    let store: EditorStore
    var body: some View {
        WithPerceptionTracking {
            Menu {
                Button(tr("audio.beats.noneItem")) { store.autoBeats(level: nil) }
                Button(tr("audio.beats.level1")) { store.autoBeats(level: 1) }
                Button(tr("audio.beats.level2")) { store.autoBeats(level: 2) }
                Divider()
                Button(tr("tlmenu.markBeat")) { store.addMarker() }
            } label: {
                Image(systemName: "heart").font(.system(size: 14)).foregroundStyle(Theme.textPrimary.opacity(0.85))
            }
            .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
            .help(tr("toolbar.beat"))
        }
    }
}
