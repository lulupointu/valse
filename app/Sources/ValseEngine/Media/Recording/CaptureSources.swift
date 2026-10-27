@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import CoreGraphics
import Foundation

/// Privacy permissions the recorders need (MI-015 / MI-017).
public enum RecordingPermission {
    public enum Status: String, Sendable { case notDetermined, denied, granted }
    public enum Kind: String, Sendable, CaseIterable { case screen, camera, microphone }

    /// UI tests: deterministic statuses instead of the machine's (never prompt in CI).
    nonisolated(unsafe) public static var override: [Kind: Status]?

    public static func status(_ k: Kind) -> Status {
        if let o = override { return o[k] ?? .notDetermined }
        switch k {
        case .screen: return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        case .camera: return map(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone: return map(AVCaptureDevice.authorizationStatus(for: .audio))
        }
    }

    static func map(_ s: AVAuthorizationStatus) -> Status {
        switch s {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// Asks the system (shows its prompt once). Screen: macOS only grants after a relaunch, so a refusal maps to denied.
    public static func request(_ k: Kind) async -> Status {
        if override != nil {
            override?[k] = .denied   // UI tests: the "denied" flow, never a real prompt
            return .denied
        }
        switch k {
        case .screen: return CGRequestScreenCaptureAccess() ? .granted : .denied
        case .camera: return await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
        case .microphone: return await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
        }
    }

    /// System Settings ▸ Privacy & Security pane for a permission.
    public static func settingsURL(_ k: Kind) -> URL {
        let anchor = switch k { case .screen: "Privacy_ScreenCapture"; case .camera: "Privacy_Camera"; case .microphone: "Privacy_Microphone" }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

/// Something to record: a display or a window.
public struct ScreenSource: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case display, window }
    public let kind: Kind
    public let id: UInt32
    public let name: String
    public let size: CGSize
    public init(kind: Kind, id: UInt32, name: String, size: CGSize) { self.kind = kind; self.id = id; self.name = name; self.size = size }
}

/// Camera / microphone devices.
public enum CaptureDevices {
    public struct Device: Identifiable, Hashable, Sendable { public let id: String; public let name: String }
    public static func cameras() -> [Device] {
        // macOS 13 names: `.externalUnknown` (renamed `.external` in 14; Continuity Camera is reported under it on 13).
        let types: [AVCaptureDevice.DeviceType] = if #available(macOS 14, *) {
            [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera]
        } else {
            [.builtInWideAngleCamera, .externalUnknown, .deskViewCamera]
        }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
            .devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }
    public static func microphones() -> [Device] {
        // macOS 13 names: `.builtInMicrophone` / `.externalUnknown` (renamed `.microphone` / `.external` in 14).
        let types: [AVCaptureDevice.DeviceType] = if #available(macOS 14, *) { [.microphone, .external] }
            else { [.builtInMicrophone, .externalUnknown] }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .audio, position: .unspecified)
            .devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }
}

/// ScreenCaptureKit display / window capture → `RecordingWriter` video (MI-015). Valse's own windows are excluded.
public final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public struct Options: Sendable {
        public var source: ScreenSource
        public var showsCursor = true
        public var fps = 30
        public init(source: ScreenSource, showsCursor: Bool = true, fps: Int = 30) { self.source = source; self.showsCursor = showsCursor; self.fps = fps }
    }

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "valse.record.screen", qos: .userInitiated)
    private let writer: RecordingWriter
    public var onError: (@Sendable (Error) -> Void)?

    public init(writer: RecordingWriter) { self.writer = writer }

    /// Displays and on-screen windows (other apps' normal windows with a title).
    public static func sources() async throws -> [ScreenSource] {
        let c = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let me = ProcessInfo.processInfo.processIdentifier
        let displays = c.displays.enumerated().map { i, d in
            ScreenSource(kind: .display, id: d.displayID, name: "\(i + 1)", size: CGSize(width: d.width, height: d.height))
        }
        let windows = c.windows.filter { w in
            w.windowLayer == 0 && w.owningApplication?.processID != me && (w.title?.isEmpty == false) && w.frame.width > 80
        }.map { w in
            ScreenSource(kind: .window, id: w.windowID, name: "\(w.owningApplication?.applicationName ?? "") — \(w.title ?? "")", size: w.frame.size)
        }
        return displays + windows
    }

    public func start(_ o: Options) async throws {
        let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let me = ProcessInfo.processInfo.processIdentifier
        let filter: SCContentFilter
        var size = o.source.size
        var scale = 1.0
        switch o.source.kind {
        case .display:
            guard let d = c.displays.first(where: { $0.displayID == o.source.id }) else { throw RecordingWriter.WriterError.failed("display gone") }
            let mine = c.applications.filter { $0.processID == me }
            filter = SCContentFilter(display: d, excludingApplications: mine, exceptingWindows: [])
            size = CGSize(width: d.width, height: d.height)
            scale = Double(CGDisplayPixelsWide(d.displayID)) / max(Double(d.width), 1)
            if let mode = CGDisplayCopyDisplayMode(d.displayID) { scale = Double(mode.pixelWidth) / max(Double(d.width), 1) }
        case .window:
            guard let w = c.windows.first(where: { $0.windowID == o.source.id }) else { throw RecordingWriter.WriterError.failed("window gone") }
            filter = SCContentFilter(desktopIndependentWindow: w)
            size = w.frame.size
            scale = 2
        }
        let cfg = SCStreamConfiguration()
        let (w, h) = Self.captureSize(points: size, scale: scale)
        cfg.width = w; cfg.height = h
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, o.fps)))
        cfg.showsCursor = o.showsCursor
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.queueDepth = 6
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    /// Capture pixel size: native resolution, long side capped at 3840 (base Air: keep encoders real-time).
    public static func captureSize(points: CGSize, scale: Double) -> (Int, Int) {
        var w = Double(points.width) * scale, h = Double(points.height) * scale
        let longSide = max(w, h)
        if longSide > 3840 { w *= 3840 / longSide; h *= 3840 / longSide }
        return (max(2, Int(w) / 2 * 2), max(2, Int(h) / 2 * 2))
    }

    public func stop() async {
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid, Self.isCompleteFrame(sb) else { return }
        writer.appendVideo(sb)
    }

    /// SCStream also delivers idle/blank status buffers without an image: only `.complete` frames are written.
    static func isCompleteFrame(_ sb: CMSampleBuffer) -> Bool {
        guard let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = att.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) { onError?(error) }
}

/// AVCaptureSession for a camera and/or microphone (MI-017 webcam, mic of the screen recorder). Video and audio may go
/// to different writers (camera on its own track while the mic goes with the screen).
public final class DeviceCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate,
                                  @unchecked Sendable {
    private let session = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "valse.record.camera", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "valse.record.mic", qos: .userInitiated)
    private weak var videoOut: AVCaptureVideoDataOutput?
    private let videoWriter: RecordingWriter?
    private let audioWriter: RecordingWriter?

    public init(videoWriter: RecordingWriter?, audioWriter: RecordingWriter?) {
        self.videoWriter = videoWriter; self.audioWriter = audioWriter
    }

    /// Live preview layer (camera framing in the recorder dialog).
    public func previewLayer() -> AVCaptureVideoPreviewLayer { AVCaptureVideoPreviewLayer(session: session) }

    public func configure(camera: String?, microphone: String?) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if videoWriter != nil || camera != nil {
            let dev = camera.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .video)
            guard let dev else { throw RecordingWriter.WriterError.failed("no camera") }
            let input = try AVCaptureDeviceInput(device: dev)
            if session.canAddInput(input) { session.addInput(input) }
            if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 } else { session.sessionPreset = .high }
            if videoWriter != nil {
                let out = AVCaptureVideoDataOutput()
                out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                out.alwaysDiscardsLateVideoFrames = true
                out.setSampleBufferDelegate(self, queue: videoQueue)
                if session.canAddOutput(out) { session.addOutput(out); videoOut = out }
            }
        }
        if audioWriter != nil {
            let dev = microphone.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .audio)
            guard let dev else { throw RecordingWriter.WriterError.failed("no microphone") }
            let input = try AVCaptureDeviceInput(device: dev)
            if session.canAddInput(input) { session.addInput(input) }
            let out = AVCaptureAudioDataOutput()
            out.setSampleBufferDelegate(self, queue: audioQueue)
            if session.canAddOutput(out) { session.addOutput(out) }
        }
    }

    public func start() { videoQueue.async { [session] in session.startRunning() } }
    public func stop() { session.stopRunning() }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOut { videoWriter?.appendVideo(sb) } else { audioWriter?.appendAudio(sb) }
    }
}
