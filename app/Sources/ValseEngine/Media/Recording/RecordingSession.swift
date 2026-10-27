@preconcurrency import AVFoundation
import Foundation
import ValseCore

/// One recording (MI-015 "Record screen" / MI-017 webcam): starts the captures, routes the microphone, pause/resume,
/// stop → finished files. Screen + camera write two files (the camera is placed as an overlay by the editor; "single
/// track" layout makes the editor nest both into one compound clip).
public final class RecordingSession: @unchecked Sendable {
    public enum Mode: String, Sendable { case screen, camera }
    public enum Layout: String, Sendable, CaseIterable { case separate, single }

    public struct Options: Sendable {
        public var mode: Mode
        public var screen: ScreenSource?
        public var showsCursor = true
        public var microphone = true
        public var microphoneID: String?
        /// Screen mode: also record the camera.
        public var camera = false
        public var cameraID: String?
        public var layout: Layout = .separate
        public init(mode: Mode) { self.mode = mode }
    }

    public struct Result: Sendable {
        public var screenURL: URL?
        public var cameraURL: URL?
        public var layout: Layout
        public init(screenURL: URL?, cameraURL: URL?, layout: Layout) { self.screenURL = screenURL; self.cameraURL = cameraURL; self.layout = layout }
        /// The file that goes on the main/track position (screen, or the camera in camera mode).
        public var primary: URL? { screenURL ?? cameraURL }
    }

    public let options: Options
    public let folder: URL
    let stamp: String
    private(set) var screenWriter: RecordingWriter?
    private(set) var cameraWriter: RecordingWriter?
    private var screen: ScreenCapture?
    private var devices: DeviceCapture?
    public private(set) var isRecording = false

    /// Recordings land in `<projects folder>/Recordings` (kept with the user's projects, survive cache clears).
    public static var defaultFolder: URL { ValsePaths.draftsDirectory.appendingPathComponent("Recordings", isDirectory: true) }

    public init(options: Options, folder: URL = RecordingSession.defaultFolder, date: Date = Date()) {
        self.options = options; self.folder = folder
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"; f.locale = Locale(identifier: "en_US_POSIX")
        stamp = f.string(from: date)
    }

    /// File names: "Screen recording 2026-10-19 14.03.22.mov" / "Camera …".
    public func fileURL(_ kind: Mode, baseName: String) -> URL {
        folder.appendingPathComponent("\(baseName) \(stamp).mov")
    }

    public func start(screenName: String, cameraName: String) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let o = options
        switch o.mode {
        case .screen:
            guard let src = o.screen else { throw RecordingWriter.WriterError.failed("no source") }
            let sw = RecordingWriter(url: fileURL(.screen, baseName: screenName), recordsAudio: o.microphone)
            screenWriter = sw
            let cw = o.camera ? RecordingWriter(url: fileURL(.camera, baseName: cameraName), recordsAudio: false) : nil
            cameraWriter = cw
            if o.microphone || o.camera {
                let d = DeviceCapture(videoWriter: cw, audioWriter: o.microphone ? sw : nil)
                try d.configure(camera: o.camera ? o.cameraID : nil, microphone: o.microphone ? o.microphoneID : nil)
                devices = d
                d.start()
            }
            let s = ScreenCapture(writer: sw)
            try await s.start(.init(source: src, showsCursor: o.showsCursor))
            screen = s
        case .camera:
            let cw = RecordingWriter(url: fileURL(.camera, baseName: cameraName), recordsAudio: o.microphone)
            cameraWriter = cw
            let d = DeviceCapture(videoWriter: cw, audioWriter: o.microphone ? cw : nil)
            try d.configure(camera: o.cameraID, microphone: o.microphone ? o.microphoneID : nil)
            devices = d
            d.start()
        }
        isRecording = true
    }

    public var isPaused: Bool { (screenWriter ?? cameraWriter)?.isPaused ?? false }
    public var recordedSeconds: Double { (screenWriter ?? cameraWriter)?.recordedSeconds ?? 0 }

    public func pause() {
        let t = CMClockGetTime(CMClockGetHostTimeClock())
        screenWriter?.pause(at: t); cameraWriter?.pause(at: t)
    }

    public func resume() {
        let t = CMClockGetTime(CMClockGetHostTimeClock())
        screenWriter?.resume(at: t); cameraWriter?.resume(at: t)
    }

    public func stop() async throws -> Result {
        isRecording = false
        await screen?.stop()
        devices?.stop()
        screen = nil; devices = nil
        var r = Result(screenURL: nil, cameraURL: nil, layout: options.layout)
        if let w = screenWriter { r.screenURL = try await w.finish() }
        if let w = cameraWriter { r.cameraURL = try? await w.finish() }
        if r.primary == nil { throw RecordingWriter.WriterError.noFrames }
        return r
    }

    public func cancel() async {
        isRecording = false
        await screen?.stop()
        devices?.stop()
        screenWriter?.cancel(); cameraWriter?.cancel()
    }
}
