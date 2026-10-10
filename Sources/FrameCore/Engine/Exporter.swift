import AVFoundation

/// How the video is exported.
public struct ExportOptions: Codable, Equatable, Sendable {
    public enum Codec: String, Codable, CaseIterable, Sendable {
        case h264, hevc
    }

    public enum Resolution: String, Codable, CaseIterable, Sendable {
        /// 1920 × 1080, the screen fitted inside.
        case p1080
        /// The frame as large as the recorded screen.
        case source
    }

    public var codec: Codec = .h264
    public var resolution: Resolution = .p1080
    public var fps = 60

    public init(codec: Codec = .h264, resolution: Resolution = .p1080, fps: Int = 60) {
        self.codec = codec
        self.resolution = resolution
        self.fps = fps
    }

    /// The frame's size in pixels, even numbers. H.264 goes up to 4096 × 2304, a larger screen is scaled down to fit.
    public func canvas(for source: CGSize) -> CGSize {
        var size = resolution == .p1080 ? CGSize(width: 1920, height: 1080) : source
        if codec == .h264 {
            let k = min(1, 4096 / size.width, 2304 / size.height)
            size = CGSize(width: size.width * k, height: size.height * k)
        }
        func even(_ x: CGFloat) -> CGFloat { max(2, (x / 2).rounded(.down) * 2) }
        return CGSize(width: even(size.width), height: even(size.height))
    }
}

/// Makes the MP4: the composition's frames (`StudioCompositor`) and its sound tracks mixed into one go through
/// AVAssetReader into AVAssetWriter. Everything stays on this Mac.
public final class Exporter: @unchecked Sendable {
    public enum Failure: LocalizedError {
        case cancelled
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .cancelled: return "cancelled"
            case .failed(let text): return text
            }
        }
    }

    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.withLock { cancelled = true }
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    /// Writes the trimmed recording with its edit to `url` (replacing a file there). `progress` gets 0…1 on a
    /// background queue.
    public func export(folder: RecordingFolder, settings: EditSettings, duration: Double, options: ExportOptions,
                       overlays: [FrameOverlay] = [], to url: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let source = try await AVURLAsset(url: folder.screenURL).loadTracks(withMediaType: .video).first?.load(.naturalSize)
        guard let source else { throw Failure.failed("no screen track") }
        let canvas = options.canvas(for: source)
        let studio = try await StudioComposition.build(folder: folder, settings: settings, canvas: canvas, fps: options.fps,
                                                       range: settings.range(duration: duration), overlays: overlays)
        let total = max(studio.duration, 0.001)

        let reader = try AVAssetReader(asset: studio.asset)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: studio.videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        videoOutput.videoComposition = studio.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw Failure.failed("reader") }
        reader.add(videoOutput)
        var audioOutput: AVAssetReaderAudioMixOutput?
        if !studio.audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: studio.audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let pixels = Double(canvas.width * canvas.height) * Double(options.fps)
        let bitRate = Int(min(60_000_000, max(4_000_000, pixels * (options.codec == .hevc ? 0.07 : 0.12))))
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitRate,
            AVVideoExpectedSourceFrameRateKey: options.fps,
            AVVideoMaxKeyFrameIntervalKey: options.fps * 2,
        ]
        if options.codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: options.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(canvas.width),
            AVVideoHeightKey: Int(canvas.height),
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw Failure.failed("writer") }
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
                AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard reader.startReading() else { throw Failure.failed(reader.error?.localizedDescription ?? "reader") }
        guard writer.startWriting() else { throw Failure.failed(writer.error?.localizedDescription ?? "writer") }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        func pump(_ pipe: Pipe, label: String, report: Bool) {
            group.enter()
            let state = Pipe.State()
            pipe.input.requestMediaDataWhenReady(on: DispatchQueue(label: "Exporter.\(label)")) { [self] in
                while !state.done && pipe.input.isReadyForMoreMediaData {
                    let sample = isCancelled ? nil : pipe.output.copyNextSampleBuffer()
                    if let sample, pipe.input.append(sample) {
                        if report { progress(min(1, CMSampleBufferGetPresentationTimeStamp(sample).seconds / total)) }
                        continue
                    }
                    if sample != nil { pipe.reader.cancelReading() }
                    state.done = true
                    pipe.input.markAsFinished()
                    group.leave()
                }
            }
        }
        pump(Pipe(input: videoInput, output: videoOutput, reader: reader), label: "video", report: true)
        if let audioInput, let audioOutput {
            pump(Pipe(input: audioInput, output: audioOutput, reader: reader), label: "audio", report: false)
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { done.resume() }
        }

        if isCancelled || reader.status == .failed || writer.status == .failed {
            let message = writer.error?.localizedDescription ?? reader.error?.localizedDescription
            writer.cancelWriting()
            reader.cancelReading()
            try? FileManager.default.removeItem(at: url)
            throw isCancelled ? Failure.cancelled : Failure.failed(message ?? "export")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw Failure.failed(writer.error?.localizedDescription ?? "export")
        }
        progress(1)
    }

    /// One input fed from one output on a queue of its own (AVFoundation's objects are used there one at a time).
    private struct Pipe: @unchecked Sendable {
        final class State: @unchecked Sendable {
            var done = false
        }

        let input: AVAssetWriterInput
        let output: AVAssetReaderOutput
        let reader: AVAssetReader
    }
}
