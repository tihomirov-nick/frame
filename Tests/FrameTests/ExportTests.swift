import AVFoundation
import XCTest
@testable import FrameCore

/// The recording files and the export, end to end on a made-up recording in a temporary folder.
final class ExportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FrameTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTheWriterTakesPausesOutOfTheFile() async throws {
        let clock = RecordingClock()
        clock.start(at: 10)
        let url = root.appendingPathComponent("paused.mov")
        let writer = try MovieWriter(url: url, video: .init(width: 320, height: 200, fps: 30), clock: clock, realTime: false)
        for i in 0..<60 {
            let host = 10 + Double(i) / 30
            if i == 21 { clock.pause(at: host) }
            if i == 36 { clock.resume(at: host) }
            if let sample = SyntheticRecording.videoSample(width: 320, height: 200, time: host, draw: { _ in }) {
                writer.appendVideo(sample, hostTime: host)
            }
        }
        let end = clock.elapsed(at: 12)
        try await writer.finish(at: end)
        XCTAssertEqual(end, 1.5, accuracy: 0.001)
        XCTAssertEqual(writer.videoFrames, 45)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertEqual(duration, 1.5, accuracy: 0.02)
    }

    func testTheExportIsAnMP4WithTheZoomThePointerAndTheCamera() async throws {
        var edit = EditSettings()
        edit.background = "graphite"
        edit.trimStart = 0.2
        edit.trimEnd = 2.9
        let folder = try await SyntheticRecording.make(in: root, edit: edit)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.thumbnailURL.path))
        XCTAssertEqual(RecordingFolder.recent(in: root), [folder])
        let project = try folder.loadProject()
        let url = folder.exportURL
        let options = ExportOptions(codec: .h264, resolution: .p1080, fps: 30)
        try await Exporter().export(folder: folder, settings: project.edit, duration: project.duration, options: options, to: url)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2.7, accuracy: 0.05)
        let video = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(video.count, 1)
        let size = try await video[0].load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 1920, height: 1080))
        let format = try await video[0].load(.formatDescriptions)
        XCTAssertEqual(format.first.map(CMFormatDescriptionGetMediaSubType), kCMVideoCodecType_H264)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1, "the microphone and the system sound are mixed into one track")
        let bytes = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertGreaterThan(bytes, 50_000)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let before = Pixels(try await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image)
        let zoomed = Pixels(try await generator.image(at: CMTime(seconds: 1.4, preferredTimescale: 600)).image)
        let renderer = FrameRenderer(canvas: size, source: project.screenSize, settings: project.edit, cursor: folder.loadCursor())
        // The composition starts at the trimmed start: 0.1 and 1.4 of the video are 0.3 and 1.6 of the recording.
        checkFrames(before: before, zoomed: zoomed, renderer: renderer, times: (0.3, 1.6), tolerance: 24)
    }

    func testHEVCAtTheRecordingsOwnSize() async throws {
        var spec = SyntheticRecording.Spec()
        spec.duration = 1
        spec.camera = false
        spec.audio = false
        let folder = try await SyntheticRecording.make(in: root, spec: spec)
        let url = root.appendingPathComponent("hevc.mp4")
        try await Exporter().export(folder: folder, settings: EditSettings(), duration: 1,
                                    options: ExportOptions(codec: .hevc, resolution: .source, fps: 30), to: url)
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 1280, height: 800))
        let format = try await track.load(.formatDescriptions)
        XCTAssertEqual(format.first.map(CMFormatDescriptionGetMediaSubType), kCMVideoCodecType_HEVC)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.05)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audio.isEmpty)
    }

    func testTheCanvasFitsTheCodec() {
        XCTAssertEqual(ExportOptions(codec: .h264, resolution: .source).canvas(for: CGSize(width: 5120, height: 2880)),
                       CGSize(width: 4096, height: 2304))
        XCTAssertEqual(ExportOptions(codec: .hevc, resolution: .source).canvas(for: CGSize(width: 5120, height: 2881)),
                       CGSize(width: 5120, height: 2880))
        XCTAssertEqual(ExportOptions(codec: .hevc, resolution: .p1080).canvas(for: CGSize(width: 3024, height: 1964)),
                       CGSize(width: 1920, height: 1080))
    }
}
