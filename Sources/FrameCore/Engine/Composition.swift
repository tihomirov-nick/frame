import AVFoundation
import CoreImage

/// What the compositor needs for the whole video: the renderer with the edit, the tracks, and where the recording's
/// time starts (the trimmed start).
public final class StudioInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    public let timeRange: CMTimeRange
    public let enablePostProcessing = false
    public let containsTweening = true
    public let requiredSourceTrackIDs: [NSValue]?
    public let passthroughTrackID = kCMPersistentTrackID_Invalid
    public let renderer: FrameRenderer
    public let offset: Double
    let screenTrack: CMPersistentTrackID
    let cameraTrack: CMPersistentTrackID?

    init(timeRange: CMTimeRange, renderer: FrameRenderer, offset: Double, screenTrack: CMPersistentTrackID,
         cameraTrack: CMPersistentTrackID?) {
        self.timeRange = timeRange
        self.renderer = renderer
        self.offset = offset
        self.screenTrack = screenTrack
        self.cameraTrack = cameraTrack
        requiredSourceTrackIDs = ([screenTrack] + (cameraTrack.map { [$0] } ?? [])).map { NSNumber(value: $0) }
    }
}

/// The compositor of the preview, the export and the still frames: every frame goes through `FrameRenderer`.
public final class StudioCompositor: NSObject, AVVideoCompositing {
    public static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                    .cacheIntermediates: false])
    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private let queue = DispatchQueue(label: "StudioCompositor", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0
    /// The screen track can end a moment before the sound: its last frame stays.
    private var lastScreen: CVPixelBuffer?

    public var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let started = lock.withLock { generation }
        queue.async { [self] in
            guard lock.withLock({ generation }) == started else {
                request.finishCancelledRequest()
                return
            }
            guard let instruction = request.videoCompositionInstruction as? StudioInstruction,
                  let output = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "StudioCompositor", code: 1))
                return
            }
            if let frame = request.sourceFrame(byTrackID: instruction.screenTrack) { lastScreen = frame }
            let screen = lastScreen.map { CIImage(cvPixelBuffer: $0) }
            let camera = instruction.cameraTrack.flatMap { request.sourceFrame(byTrackID: $0) }.map { CIImage(cvPixelBuffer: $0) }
            let renderer = instruction.renderer
            var image = renderer.render(screen: screen, camera: camera, at: request.compositionTime.seconds + instruction.offset,
                                        context: Self.context)
            let size = request.renderContext.size
            if size.width != renderer.canvas.width {
                let k = size.width / renderer.canvas.width
                image = image.transformed(by: CGAffineTransform(scaleX: k, y: k))
            }
            Self.context.render(image, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: Self.space)
            request.finish(withComposedVideoFrame: output)
        }
    }

    public func cancelAllPendingVideoCompositionRequests() {
        lock.withLock { generation += 1 }
    }
}

/// The recording put together for the editor and the export: the tracks of the trimmed part and the video
/// composition that draws every frame.
public struct StudioComposition {
    public let asset: AVComposition
    public let videoComposition: AVVideoComposition
    public let renderer: FrameRenderer
    public let videoTracks: [AVAssetTrack]
    public let audioTracks: [AVAssetTrack]
    /// Where the composition's zero is in the recording.
    public let offset: Double
    public let source: CGSize
    public let hasCamera: Bool
    private let screenID: CMPersistentTrackID
    private let cameraID: CMPersistentTrackID?
    private let cursor: CursorTrack
    private let smooth: SmoothCursor
    private let fps: Int
    private let overlays: [FrameOverlay]

    public var duration: Double { asset.duration.seconds }

    public enum Failure: Error {
        case noScreen
    }

    /// `range`: the part of the recording, the whole of it by default. `fps`: frames per second of the result. The
    /// camera track goes in when the edit shows the camera, or always with `keepCamera` (the editor's preview, where
    /// the switch only changes the drawing).
    public static func build(folder: RecordingFolder, settings: EditSettings, canvas: CGSize, fps: Int,
                             range: ClosedRange<Double>? = nil, keepCamera: Bool = false,
                             overlays: [FrameOverlay] = []) async throws -> StudioComposition {
        let composition = AVMutableComposition()
        let screen = AVURLAsset(url: folder.screenURL)
        guard let screenTrack = try await screen.loadTracks(withMediaType: .video).first else { throw Failure.noScreen }
        let whole = try await screen.load(.duration)
        let part = range.map { CMTimeRange(start: CMTime(seconds: $0.lowerBound, preferredTimescale: 600),
                                           end: CMTime(seconds: $0.upperBound, preferredTimescale: 600)) }
            ?? CMTimeRange(start: .zero, duration: whole)

        func add(_ track: AVAssetTrack, _ type: AVMediaType) async throws -> CMPersistentTrackID? {
            let available = try await track.load(.timeRange)
            let piece = part.intersection(available)
            guard piece.duration > .zero,
                  let out = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { return nil }
            try out.insertTimeRange(piece, of: track, at: CMTimeSubtract(piece.start, part.start))
            return out.trackID
        }

        guard let screenID = try await add(screenTrack, .video) else { throw Failure.noScreen }
        var cameraID: CMPersistentTrackID?
        // The asset stays referenced while its track is inserted: a track of a released asset cannot be read.
        let camera = AVURLAsset(url: folder.cameraURL)
        if settings.cameraVisible || keepCamera, FileManager.default.fileExists(atPath: folder.cameraURL.path),
           let cameraTrack = try await camera.loadTracks(withMediaType: .video).first {
            cameraID = try await add(cameraTrack, .video)
        }
        for track in try await screen.loadTracks(withMediaType: .audio) {
            _ = try await add(track, .audio)
        }

        let source = try await screenTrack.load(.naturalSize)
        let cursor = folder.loadCursor()
        let studio = StudioComposition(asset: composition, videoComposition: AVMutableVideoComposition(),
                                       renderer: FrameRenderer(canvas: canvas, source: source, settings: settings,
                                                               cursor: CursorTrack()),
                                       videoTracks: composition.tracks(withMediaType: .video),
                                       audioTracks: composition.tracks(withMediaType: .audio), offset: part.start.seconds,
                                       source: source, hasCamera: cameraID != nil, screenID: screenID, cameraID: cameraID,
                                       cursor: cursor, smooth: SmoothCursor(track: cursor), fps: fps, overlays: overlays)
        return studio.with(settings, canvas: canvas)
    }

    /// The same tracks drawn with another edit or frame size: only the video composition is new, so the editor's
    /// player keeps its place.
    public func with(_ settings: EditSettings, canvas: CGSize) -> StudioComposition {
        let renderer = FrameRenderer(canvas: canvas, source: source, settings: settings, cursor: cursor, smooth: smooth,
                                     overlays: overlays)
        let instruction = StudioInstruction(timeRange: CMTimeRange(start: .zero, duration: asset.duration), renderer: renderer,
                                            offset: offset, screenTrack: screenID, cameraTrack: cameraID)
        let video = AVMutableVideoComposition()
        video.customVideoCompositorClass = StudioCompositor.self
        video.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        video.renderSize = canvas
        video.instructions = [instruction]
        return StudioComposition(asset: asset, videoComposition: video, renderer: renderer, videoTracks: videoTracks,
                                 audioTracks: audioTracks, offset: offset, source: source, hasCamera: hasCamera,
                                 screenID: screenID, cameraID: cameraID, cursor: cursor, smooth: smooth, fps: fps,
                                 overlays: overlays)
    }

    /// One finished frame at `time` of the composition, as the export draws it.
    public func frame(at time: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
    }
}
