import AVFoundation

/// Writes what is being recorded into a QuickTime file on the recording's timeline. Every sample gets its time from
/// `RecordingClock` in place of the host time it was captured at, so pauses leave no gaps and the screen, the camera and
/// the sounds, written into separate files on separate queues, all start together at zero.
public final class MovieWriter {
    public struct Video {
        public var width: Int
        public var height: Int
        public var fps: Double

        public init(width: Int, height: Int, fps: Double) {
            self.width = width
            self.height = height
            self.fps = fps
        }

        /// HEVC for what H.264 does not take (beyond 4096 × 2304), H.264 otherwise. A high bit rate: the edit
        /// compresses once more.
        var settings: [String: Any] {
            let hevc = width > 4096 || height > 2304
            let bitRate = min(80_000_000, max(8_000_000, Double(width * height) * fps * 0.12))
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: Int(bitRate),
                AVVideoExpectedSourceFrameRateKey: Int(fps),
                AVVideoMaxKeyFrameIntervalKey: Int(fps * 2),
                AVVideoAllowFrameReorderingKey: false,
            ]
            if !hevc { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            return [
                AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: compression,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
            ]
        }
    }

    public enum Failure: Error {
        case setup
    }

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput?
    private let audioInputs: [AVAssetWriterInput]
    private let clock: RecordingClock
    private let realTime: Bool
    private let lock = NSLock()
    private var lastVideo = -Double.infinity
    private var audioEnds: [Double]
    public private(set) var videoFrames = 0

    /// `audioChannels`: one audio track per entry, with that many channels. Out of real time (`realTime` false) the
    /// writer waits for a busy input instead of dropping the sample.
    public init(url: URL, video: Video?, audioChannels: [Int] = [], clock: RecordingClock, realTime: Bool = true) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var videoInput: AVAssetWriterInput?
        if let video {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: video.settings)
            input.expectsMediaDataInRealTime = realTime
            guard writer.canAdd(input) else { throw Failure.setup }
            writer.add(input)
            videoInput = input
        }
        var audioInputs: [AVAssetWriterInput] = []
        for channels in audioChannels {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels == 1 ? 1 : 2,
                AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000,
                AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
            ])
            input.expectsMediaDataInRealTime = realTime
            guard writer.canAdd(input) else { throw Failure.setup }
            writer.add(input)
            audioInputs.append(input)
        }
        guard writer.startWriting() else { throw writer.error ?? Failure.setup }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.videoInput = videoInput
        self.audioInputs = audioInputs
        self.clock = clock
        self.realTime = realTime
        audioEnds = Array(repeating: -Double.infinity, count: audioInputs.count)
    }

    /// `hostTime`: when the sample was captured; by default its own presentation time. The first frame starts the file
    /// at zero: a screen sends frames only when something changes, and the picture before the first one was the same.
    @discardableResult
    public func appendVideo(_ sample: CMSampleBuffer, hostTime: Double? = nil) -> Bool {
        guard let input = videoInput,
              var t = clock.time(forHost: hostTime ?? CMSampleBufferGetPresentationTimeStamp(sample).seconds) else { return false }
        return lock.withLock {
            if videoFrames == 0 { t = 0 }
            guard t > lastVideo, ready(input),
                  let copy = sample.retimed(to: CMTime(seconds: t, preferredTimescale: 90_000)), input.append(copy)
            else { return false }
            lastVideo = t
            videoFrames += 1
            return true
        }
    }

    @discardableResult
    public func appendAudio(_ sample: CMSampleBuffer, track: Int, hostTime: Double? = nil) -> Bool {
        guard audioInputs.indices.contains(track),
              var t = clock.time(forHost: hostTime ?? CMSampleBufferGetPresentationTimeStamp(sample).seconds) else { return false }
        let input = audioInputs[track]
        let rate = sample.sampleRate ?? 48_000
        return lock.withLock {
            // The clocks jitter: a buffer starting a hair off the end of the previous one joins it, so the sound stays
            // one piece. One from the past would stop the writer.
            let end = audioEnds[track]
            if abs(t - end) < 0.03 { t = end } else if t < end { return false }
            guard ready(input), let copy = sample.retimed(to: CMTime(seconds: t, preferredTimescale: CMTimeScale(rate))),
                  input.append(copy) else { return false }
            audioEnds[track] = t + Double(CMSampleBufferGetNumSamples(sample)) / rate
            return true
        }
    }

    /// In real time a busy input drops the sample; otherwise the writer waits for it.
    private func ready(_ input: AVAssetWriterInput) -> Bool {
        guard writer.status == .writing else { return false }
        if realTime { return input.isReadyForMoreMediaData }
        while !input.isReadyForMoreMediaData, writer.status == .writing {
            Thread.sleep(forTimeInterval: 0.002)
        }
        return writer.status == .writing
    }

    /// Closes the file at `time` of the recording: the last frame lasts until then.
    public func finish(at time: Double) async throws {
        let writing = lock.withLock { () -> Bool in
            guard writer.status == .writing else { return false }
            writer.endSession(atSourceTime: CMTime(seconds: max(time, 0.01), preferredTimescale: 90_000))
            return true
        }
        if writing { await writer.finishWriting() }
        guard writer.status == .completed else { throw writer.error ?? Failure.setup }
    }

    public func cancel() {
        lock.withLock {
            if writer.status == .writing { writer.cancelWriting() }
        }
    }
}

extension CMSampleBuffer {
    /// A copy that starts at `start`, its samples keeping their spacing.
    func retimed(to start: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(self, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: start,
                                                                          decodeTimeStamp: .invalid), count: max(count, 1))
        if count > 0 {
            CMSampleBufferGetSampleTimingInfoArray(self, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
            let shift = CMTimeSubtract(start, CMSampleBufferGetPresentationTimeStamp(self))
            for i in timing.indices {
                timing[i].presentationTimeStamp = CMTimeAdd(timing[i].presentationTimeStamp, shift)
                timing[i].decodeTimeStamp = .invalid
            }
        }
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: self, sampleTimingEntryCount: timing.count,
                                              sampleTimingArray: &timing, sampleBufferOut: &copy)
        return copy
    }

    var sampleRate: Double? {
        guard let format = CMSampleBufferGetFormatDescription(self),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { return nil }
        return description.pointee.mSampleRate
    }
}
