import AppKit
import AVFoundation
import FrameCore
import ScreenCaptureKit

/// What to record and how ScreenCaptureKit is set up for it: the whole display, one window or an area of a display.
/// The system cursor stays out of the picture (it is drawn again in the edit), and so do the app's own windows: the
/// panel, the countdown, the camera bubble.
struct CapturePlan {
    enum Target {
        case display(SCDisplay)
        case window(SCWindow)
        /// An area of the display, in its points from the top left corner.
        case area(SCDisplay, CGRect)
    }

    let filter: SCContentFilter
    let configuration: SCStreamConfiguration
    let source: RecordingProject.Source
    /// The captured area in global points, top left origin: where the pointer is measured from.
    let area: CGRect
    let width: Int
    let height: Int
    let fps = 60.0

    init(target: Target, content: SCShareableContent, systemAudio: Bool) {
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let configuration = SCStreamConfiguration()
        var size: CGSize
        switch target {
        case .display(let display):
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            area = display.frame
            size = display.frame.size
            source = .display
        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
            area = window.frame
            size = window.frame.size
            source = .window
        case .area(let display, let rect):
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            configuration.sourceRect = rect
            area = rect.offsetBy(dx: display.frame.minX, dy: display.frame.minY)
            size = rect.size
            source = .area
        }
        let scale = CGFloat(filter.pointPixelScale)
        size = CGSize(width: size.width * scale, height: size.height * scale)
        width = max(2, Int(size.width / 2) * 2)
        height = max(2, Int(size.height / 2) * 2)
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 6
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.capturesAudio = systemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        self.configuration = configuration
    }
}

/// The screen and the system sound from ScreenCaptureKit into the recording's writer. A still screen sends no new
/// frames, so the last one is written again a few times a second: the writer interleaves its tracks and would hold
/// the sound back while the picture is missing.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "Frame.screen", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "Frame.systemAudio", qos: .userInteractive)
    private var stream: SCStream?
    private var heartbeat: DispatchSourceTimer?
    private var lastFrame: CVPixelBuffer?
    private var lastWritten = 0.0
    private let writer: MovieWriter
    private let systemTrack: Int
    var onStop: ((Error) -> Void)?

    init(writer: MovieWriter, systemTrack: Int) {
        self.writer = writer
        self.systemTrack = systemTrack
    }

    func start(_ plan: CapturePlan) async throws {
        let stream = SCStream(filter: plan.filter, configuration: plan.configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if plan.configuration.capturesAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        try await stream.startCapture()
        self.stream = stream
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 1.0 / 15)
        timer.setEventHandler { [weak self] in self?.repeatLastFrame() }
        timer.resume()
        heartbeat = timer
    }

    func stop() async {
        heartbeat?.cancel()
        heartbeat = nil
        try? await stream?.stopCapture()
        stream = nil
        queue.sync {}
        audioQueue.sync {}
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sample.isValid else { return }
        switch type {
        case .screen:
            // Only complete frames carry a picture; idle ones say nothing has changed.
            guard let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
                  let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
                  let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
            lastFrame = buffer
            if writer.appendVideo(sample) { lastWritten = RecordingClock.hostNow }
        case .audio:
            writer.appendAudio(sample, track: systemTrack)
        default:
            break
        }
    }

    private func repeatLastFrame() {
        let now = RecordingClock.hostNow
        guard let lastFrame, now - lastWritten > 0.1 else { return }
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: lastFrame, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: now, preferredTimescale: 90_000),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard let format else { return }
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: lastFrame, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        if let sample, writer.appendVideo(sample, hostTime: now) { lastWritten = now }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onStop?(error) }
    }
}

/// The camera and the microphone through one AVCaptureSession. The camera goes into camera.mov (its writer is made
/// with the first frame, when its size is known), the microphone into the first audio track of screen.mov.
final class CameraMic: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    /// Samples arrive here; the session starts and stops on a queue of its own, so stopping never waits for itself.
    private let queue = DispatchQueue(label: "Frame.cameraMic", qos: .userInteractive)
    private let sessionQueue = DispatchQueue(label: "Frame.captureSession", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private(set) var hasCamera = false
    private(set) var hasMicrophone = false
    private var cameraWriter: MovieWriter?
    private var cameraURL: URL?
    private var clock: RecordingClock?
    private var micWriter: MovieWriter?

    func configure(camera: Bool, microphone: Bool) {
        session.beginConfiguration()
        if camera, let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
                hasCamera = true
            }
        }
        if microphone, let device = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            audioOutput.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
                hasMicrophone = true
            }
        }
        session.commitConfiguration()
    }

    /// Starts the devices; samples go to the writers once `clock` has started.
    func start(cameraURL: URL?, micWriter: MovieWriter?, clock: RecordingClock) {
        queue.async { [self] in
            self.cameraURL = cameraURL
            self.micWriter = micWriter
            self.clock = clock
        }
        sessionQueue.async { [self] in
            if hasCamera || hasMicrophone { session.startRunning() }
        }
    }

    /// Stops the devices and hands over the camera's writer, if a frame ever came.
    func stop() -> MovieWriter? {
        sessionQueue.sync { session.stopRunning() }
        return queue.sync { cameraWriter }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let host = session.synchronizationClock.map { CMSyncConvertTime(pts, from: $0, to: CMClockGetHostTimeClock()).seconds }
            ?? pts.seconds
        if output === videoOutput {
            if cameraWriter == nil, let cameraURL, let clock, clock.time(forHost: host) != nil,
               let buffer = CMSampleBufferGetImageBuffer(sample) {
                cameraWriter = try? MovieWriter(url: cameraURL, video: .init(width: CVPixelBufferGetWidth(buffer),
                                                                             height: CVPixelBufferGetHeight(buffer), fps: 30),
                                                clock: clock)
            }
            cameraWriter?.appendVideo(sample, hostTime: host)
        } else {
            micWriter?.appendAudio(sample, track: 0, hostTime: host)
        }
    }
}

/// The pointer during a recording: its position 120 times a second and the clicks, in the captured area. A global
/// monitor sees mouse clicks without the Accessibility permission, and it does not see clicks on the app's own
/// windows, so pressing «Стоп» makes no zoom.
@MainActor
final class CursorTracker {
    private var builder = CursorTrackBuilder()
    private var timer: Timer?
    private var monitor: Any?
    private let clock: RecordingClock
    private let area: CGRect

    init(clock: RecordingClock, area: CGRect) {
        self.clock = clock
        self.area = area
    }

    func start() {
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.click() }
        }
    }

    func stop() -> CursorTrack {
        timer?.invalidate()
        timer = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        return builder.finished
    }

    private var position: CGPoint {
        Self.normalized(NSEvent.mouseLocation, in: area, mainScreenTop: NSScreen.screens.first?.frame.maxY ?? 0)
    }

    /// A point of AppKit's screen coordinates (origin at the bottom left of the main screen) in `area` (global points,
    /// origin at the top left, as ScreenCaptureKit counts): 0…1 from the area's top left corner, four decimals.
    nonisolated static func normalized(_ p: CGPoint, in area: CGRect, mainScreenTop: CGFloat) -> CGPoint {
        func round(_ v: CGFloat) -> CGFloat { (v * 10_000).rounded() / 10_000 }
        return CGPoint(x: round((p.x - area.minX) / max(area.width, 1)),
                       y: round((mainScreenTop - p.y - area.minY) / max(area.height, 1)))
    }

    private func poll() {
        guard let t = clock.time(forHost: RecordingClock.hostNow) else { return }
        let p = position
        builder.move(t: t, x: p.x, y: p.y)
    }

    private func click() {
        guard let t = clock.time(forHost: RecordingClock.hostNow) else { return }
        let p = position
        guard (0...1).contains(p.x), (0...1).contains(p.y) else { return }
        builder.move(t: t, x: p.x, y: p.y)
        builder.click(t: t, x: p.x, y: p.y)
    }
}
