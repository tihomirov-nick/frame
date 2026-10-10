import AVFoundation
import CoreGraphics

/// A made-up recording for the tests and the preview pictures: an app window drawn frame by frame, a pointer that rests,
/// glides to an orange button and clicks it, a camera picture, a tone on the microphone and another in the system
/// sound. Nothing is captured from the Mac.
public enum SyntheticRecording {
    public struct Spec {
        public var duration = 3.0
        public var size = CGSize(width: 1280, height: 800)
        public var fps = 30.0
        public var camera = true
        public var audio = true
        /// Where the pointer rests, then the button it moves to and clicks.
        public var rest = CGPoint(x: 0.3, y: 0.62)
        public var target = CGPoint(x: 0.72, y: 0.34)
        public var moveStart = 0.6
        public var moveEnd = 0.9
        public var click = 1.1

        public init() {}
    }

    public static let targetColor = (r: 1.0, g: 0.45, b: 0.0)
    /// The button's size, a share of the screen.
    public static let targetSize = CGSize(width: 0.1, height: 0.075)
    public static let cameraColor = (r: 0.15, g: 0.7, b: 0.45)
    static let cameraSize = (width: 640, height: 480)
    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    public static func make(in root: URL, spec: Spec = Spec(), edit: EditSettings = EditSettings()) async throws -> RecordingFolder {
        let folder = try RecordingFolder.create(in: root)
        let clock = RecordingClock()
        clock.start(at: 0)
        let width = Int(spec.size.width), height = Int(spec.size.height)
        let screen = try MovieWriter(url: folder.screenURL, video: .init(width: width, height: height, fps: spec.fps),
                                     audioChannels: spec.audio ? [1, 2] : [], clock: clock, realTime: false)
        let camera = spec.camera ? try MovieWriter(url: folder.cameraURL, video: .init(width: cameraSize.width,
                                                                                         height: cameraSize.height, fps: spec.fps),
                                                   clock: clock, realTime: false) : nil
        let chunk = 1024
        var audioTime = 0.0
        for i in 0..<Int((spec.duration * spec.fps).rounded()) {
            let t = Double(i) / spec.fps
            if let sample = videoSample(width: width, height: height, time: t, draw: {
                drawScreen($0, size: spec.size, spec: spec, progress: t / spec.duration)
            }) {
                screen.appendVideo(sample, hostTime: t)
            }
            if let camera, let sample = videoSample(width: cameraSize.width, height: cameraSize.height, time: t, draw: drawCamera) {
                camera.appendVideo(sample, hostTime: t)
            }
            while spec.audio, audioTime < t + 1 / spec.fps {
                if let mic = tone(channels: 1, frequency: 440, start: audioTime, frames: chunk) {
                    screen.appendAudio(mic, track: 0, hostTime: audioTime)
                }
                if let system = tone(channels: 2, frequency: 660, start: audioTime, frames: chunk) {
                    screen.appendAudio(system, track: 1, hostTime: audioTime)
                }
                audioTime += Double(chunk) / 48_000
            }
        }
        try await screen.finish(at: spec.duration)
        try await camera?.finish(at: spec.duration)
        try folder.save(cursor(spec))
        try folder.save(RecordingProject(duration: spec.duration, source: .display, screenSize: spec.size,
                                         hasCamera: spec.camera, hasMicrophone: spec.audio, hasSystemAudio: spec.audio,
                                         edit: edit))
        await folder.makeThumbnail()
        return folder
    }

    /// The pointer of the made-up recording, 120 positions a second, and its one click.
    public static func cursor(_ spec: Spec) -> CursorTrack {
        var builder = CursorTrackBuilder()
        for i in 0...Int(spec.duration * 120) {
            let t = Double(i) / 120
            let p = Ease.lerp(spec.rest, spec.target, Ease.smooth((t - spec.moveStart) / (spec.moveEnd - spec.moveStart)))
            builder.move(t: t, x: p.x, y: p.y)
        }
        builder.click(t: spec.click, x: spec.target.x, y: spec.target.y)
        return builder.finished
    }

    /// One frame of the made-up screen.
    public static func screenImage(spec: Spec = Spec(), progress: Double = 0) -> CGImage? {
        let ctx = CGContext(data: nil, width: Int(spec.size.width), height: Int(spec.size.height), bitsPerComponent: 8,
                            bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx else { return nil }
        ctx.translateBy(x: 0, y: spec.size.height)
        ctx.scaleBy(x: 1, y: -1)
        drawScreen(ctx, size: spec.size, spec: spec, progress: progress)
        return ctx.makeImage()
    }

    /// A light app window: a title bar, a sidebar, lines of text, the orange button and a progress bar that grows,
    /// so frames differ. y goes down.
    static func drawScreen(_ ctx: CGContext, size: CGSize, spec: Spec, progress: Double) {
        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
            CGRect(x: x * size.width, y: y * size.height, width: w * size.width, height: h * size.height)
        }
        func fill(_ r: CGRect, _ red: Double, _ green: Double, _ blue: Double, radius: CGFloat = 0) {
            ctx.setFillColor(CGColor(colorSpace: space, components: [red, green, blue, 1])!)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }
        fill(rect(0, 0, 1, 1), 0.93, 0.93, 0.94)
        fill(rect(0.03, 0.05, 0.94, 0.9), 1, 1, 1, radius: size.width * 0.01)
        fill(rect(0.03, 0.05, 0.94, 0.06), 0.9, 0.9, 0.91)
        for (i, color) in [(1.0, 0.37, 0.34), (1.0, 0.74, 0.18), (0.16, 0.79, 0.25)].enumerated() {
            let d = size.width * 0.012
            fill(CGRect(x: size.width * (0.045 + 0.02 * Double(i)), y: size.height * 0.08 - d / 2, width: d, height: d),
                 color.0, color.1, color.2, radius: d / 2)
        }
        fill(rect(0.03, 0.11, 0.18, 0.84), 0.96, 0.96, 0.97)
        for i in 0..<6 { fill(rect(0.05, 0.16 + Double(i) * 0.05, 0.12, 0.018), 0.82, 0.82, 0.84, radius: 3) }
        for (i, w) in [0.33, 0.28, 0.31, 0.2, 0.26].enumerated() {
            fill(rect(0.27, 0.18 + Double(i) * 0.045, w, 0.02), 0.85, 0.85, 0.87, radius: 3)
        }
        let c = targetColor
        fill(rect(spec.target.x - targetSize.width / 2, spec.target.y - targetSize.height / 2, targetSize.width,
                  targetSize.height), c.r, c.g, c.b, radius: size.width * 0.008)
        fill(rect(0.27, 0.86, 0.6, 0.012), 0.88, 0.88, 0.9, radius: 2)
        fill(rect(0.27, 0.86, 0.6 * min(max(progress, 0), 1), 0.012), 0.2, 0.5, 1, radius: 2)
    }

    /// A person in front of a green wall. y goes down.
    static func drawCamera(_ ctx: CGContext) {
        let w = CGFloat(cameraSize.width), h = CGFloat(cameraSize.height)
        let c = cameraColor
        ctx.setFillColor(CGColor(colorSpace: space, components: [c.r, c.g, c.b, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(colorSpace: space, components: [0.25, 0.3, 0.42, 1])!)
        ctx.fillEllipse(in: CGRect(x: w / 2 - 0.32 * w, y: 0.78 * h, width: 0.64 * w, height: 0.5 * h))
        ctx.setFillColor(CGColor(colorSpace: space, components: [0.96, 0.8, 0.69, 1])!)
        ctx.fillEllipse(in: CGRect(x: w / 2 - 0.17 * h, y: 0.4 * h - 0.17 * h, width: 0.34 * h, height: 0.34 * h))
    }

    static func videoSample(width: Int, height: Int, time: Double, draw: (CGContext) -> Void) -> CMSampleBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { return nil }
        // Tagged like the frames of ScreenCaptureKit and the camera: sRGB.
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            draw(ctx)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 600),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        return sample
    }

    /// A sine tone, 32-bit float, 48 kHz.
    static func tone(channels: Int, frequency: Double, start: Double, frames: Int) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1,
                                               mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels),
                                               mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let bytes = frames * channels * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                           flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let format, let block else { return nil }
        var values = [Float](repeating: 0, count: frames * channels)
        for f in 0..<frames {
            let v = Float(0.2 * sin(2 * .pi * frequency * (start + Double(f) / 48_000)))
            for c in 0..<channels { values[f * channels + c] = v }
        }
        let status = values.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        }
        guard status == noErr else { return nil }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                             sampleCount: frames,
                                                             presentationTimeStamp: CMTime(seconds: start, preferredTimescale: 48_000),
                                                             packetDescriptions: nil, sampleBufferOut: &sample)
        return sample
    }
}
