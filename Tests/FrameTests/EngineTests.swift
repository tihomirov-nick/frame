import CoreImage
import XCTest
@testable import FrameCore

/// The edit's math and the renderer, on made-up data.
final class EngineTests: XCTestCase {
    func testTheClockTakesPausesOut() throws {
        let clock = RecordingClock()
        XCTAssertNil(clock.time(forHost: 5))
        clock.start(at: 100)
        clock.pause(at: 102)
        clock.resume(at: 103.5)
        clock.stop(at: 106)
        XCTAssertNil(clock.time(forHost: 99))
        XCTAssertEqual(try XCTUnwrap(clock.time(forHost: 101)), 1, accuracy: 1e-9)
        XCTAssertNil(clock.time(forHost: 102.5))
        XCTAssertEqual(try XCTUnwrap(clock.time(forHost: 104)), 2.5, accuracy: 1e-9)
        XCTAssertNil(clock.time(forHost: 107))
        XCTAssertEqual(clock.elapsed(at: 110), 4.5, accuracy: 1e-9)
    }

    func testTheTrackKeepsChangesAndWhereThePointerRested() throws {
        var builder = CursorTrackBuilder()
        builder.move(t: 0, x: 0.1, y: 0.1)
        builder.move(t: 0.1, x: 0.1, y: 0.1)
        builder.move(t: 0.2, x: 0.1, y: 0.1)
        builder.move(t: 0.3, x: 0.5, y: 0.5)
        builder.move(t: 0.25, x: 0.9, y: 0.9)
        let track = builder.finished
        XCTAssertEqual(track.samples.map(\.t), [0, 0.2, 0.3])
        XCTAssertEqual(track.position(at: 0.15), CGPoint(x: 0.1, y: 0.1))
        XCTAssertEqual(try XCTUnwrap(track.position(at: 0.25)).x, 0.3, accuracy: 1e-9)
    }

    func testTheSmoothPointerCalmsTheShakeAndArrivesInTime() throws {
        var builder = CursorTrackBuilder()
        var seed: UInt64 = 7
        func noise() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(UInt64(1) << 53) - 0.5
        }
        for i in 0...480 {
            let t = Double(i) / 120
            var p = Ease.lerp(CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.8, y: 0.5), Ease.smooth(t - 1))
            if t > 1, t < 2 { p.y += 0.02 * noise() }
            builder.move(t: t, x: p.x, y: p.y)
        }
        let track = builder.finished
        let smooth = SmoothCursor(track: track)
        func wobble(_ at: (Double) -> CGPoint?) -> Double {
            stride(from: 1.0, to: 2.0, by: 1 / 120).reduce(0) { $0 + abs(at($1 + 1 / 120)!.y - at($1)!.y) }
        }
        XCTAssertLessThan(wobble(smooth.position), 0.25 * wobble(track.position))
        XCTAssertEqual(try XCTUnwrap(smooth.position(at: 0.5)).x, 0.2, accuracy: 1e-6)
        let end = try XCTUnwrap(smooth.position(at: 3.5))
        XCTAssertEqual(end.x, 0.8, accuracy: 1e-3)
        XCTAssertEqual(end.y, 0.5, accuracy: 1e-3)
        // The lead makes up for the spring's lag: halfway through the move the two are close.
        XCTAssertEqual(try XCTUnwrap(smooth.position(at: 1.5)).x, try XCTUnwrap(track.position(at: 1.5)).x, accuracy: 0.05)
    }

    func testTheZoomComesInBeforeTheClickGlidesAndGoesOut() {
        let clicks = [CursorTrack.Click(t: 1.0, x: 0.7, y: 0.3), .init(t: 1.8, x: 0.4, y: 0.6),
                      .init(t: 6.0, x: 0.5, y: 0.5), .init(t: 7.0, x: 1.4, y: 0.5)]
        let plan = ZoomPlan(clicks: clicks, scale: 2)
        XCTAssertEqual(plan.segments.count, 2, "the first two clicks make one zoom, the one outside the area none")
        XCTAssertEqual(plan.state(at: 0.3).scale, 1)
        let coming = plan.state(at: 0.8)
        XCTAssertTrue(coming.scale > 1 && coming.scale < 2)
        let first = plan.state(at: 1.2)
        XCTAssertEqual(first.scale, 2, accuracy: 1e-9)
        XCTAssertEqual(first.focus.x, 0.7, accuracy: 1e-6)
        let second = plan.state(at: 2.0)
        XCTAssertEqual(second.scale, 2, accuracy: 1e-9)
        XCTAssertEqual(second.focus.x, 0.4, accuracy: 1e-6)
        XCTAssertEqual(plan.state(at: 4.0).scale, 1)
        XCTAssertEqual(plan.state(at: 6.2).scale, 2, accuracy: 1e-9)
        var last: CGFloat = 1
        for t in stride(from: 0.5, through: 1.15, by: 0.05) {
            XCTAssertGreaterThanOrEqual(plan.state(at: t).scale, last)
            last = plan.state(at: t).scale
        }
        XCTAssertTrue(ZoomPlan(clicks: clicks, scale: 1).segments.isEmpty)
    }

    func testTheZoomedViewStaysOnTheScreenPicture() {
        let canvas = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let layout = FrameLayout(canvas: canvas.size, source: CGSize(width: 1280, height: 800), padding: 0.07, cornerRadius: 0.02)
        XCTAssertEqual(layout.content.width / layout.content.height, 1.6, accuracy: 1e-6)
        XCTAssertEqual(layout.content.midX, 960, accuracy: 1e-6)
        for focus in [CGPoint(x: 0.02, y: 0.02), CGPoint(x: 0.98, y: 0.97), CGPoint(x: 0.5, y: 0.5)] {
            let shown = layout.content.applying(layout.zoomTransform(scale: 2, focus: layout.point(focus), amount: 1))
            XCTAssertTrue(shown.insetBy(dx: -0.5, dy: -0.5).contains(canvas), "\(focus): \(shown)")
        }
        XCTAssertEqual(layout.zoomTransform(scale: 1, focus: .zero, amount: 0), .identity)
    }

    func testTheEditReadsOlderFilesAndKeepsTheTrimInside() throws {
        let edit = try JSONDecoder().decode(EditSettings.self, from: Data(#"{"zoom": false}"#.utf8))
        XCTAssertFalse(edit.zoom)
        XCTAssertEqual(edit.background, BackgroundPreset.defaultID)
        var trimmed = EditSettings()
        trimmed.trimStart = 5
        trimmed.trimEnd = 2
        XCTAssertEqual(trimmed.range(duration: 4), 3.9...4)
        XCTAssertEqual(EditSettings().range(duration: 10), 0...10)
    }

    func testTheRendererZoomsDrawsThePointerAndTheCamera() throws {
        let spec = SyntheticRecording.Spec()
        var settings = EditSettings()
        settings.background = "graphite"
        let canvas = CGSize(width: 960, height: 540)
        let renderer = FrameRenderer(canvas: canvas, source: spec.size, settings: settings, cursor: SyntheticRecording.cursor(spec))
        let screen = CIImage(cgImage: try XCTUnwrap(SyntheticRecording.screenImage(spec: spec)))
        let c = SyntheticRecording.cameraColor
        let camera = CIImage(color: CIColor(red: c.r, green: c.g, blue: c.b)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480))
        let context = CIContext()
        func draw(_ t: Double) throws -> Pixels {
            let image = renderer.render(screen: screen, camera: camera, at: t, context: context)
            return Pixels(try XCTUnwrap(context.createCGImage(image, from: CGRect(origin: .zero, size: canvas))))
        }
        checkFrames(before: try draw(0.3), zoomed: try draw(1.6), renderer: renderer, times: (0.3, 1.6), tolerance: 10)
    }

    /// The camera in the finished video, whichever corner the bubble was in on screen: a circle and not its square,
    /// mirrored as the bubble shows it, in that corner of the frame.
    func testTheCameraInTheVideoIsACircleMirroredInTheCornerItWasIn() throws {
        let spec = SyntheticRecording.Spec()
        let canvas = CGSize(width: 960, height: 540)
        let red = CIImage(color: CIColor(red: 0.9, green: 0.1, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 480))
        let blue = CIImage(color: CIColor(red: 0.1, green: 0.2, blue: 0.9)).cropped(to: CGRect(x: 320, y: 0, width: 320, height: 480))
        let camera = blue.composited(over: red)
        let context = CIContext()
        func draw(_ corner: EditSettings.Corner, camera: CIImage?) throws -> (pixels: Pixels, bubble: CGRect) {
            var settings = EditSettings()
            settings.cameraCorner = corner
            let renderer = FrameRenderer(canvas: canvas, source: spec.size, settings: settings, cursor: SyntheticRecording.cursor(spec))
            let image = renderer.render(screen: nil, camera: camera, at: 0.3, context: context)
            let cg = try XCTUnwrap(context.createCGImage(image, from: CGRect(origin: .zero, size: canvas)))
            return (Pixels(cg), renderer.bubbleRect)
        }
        func same(_ a: RGB8, _ b: RGB8) -> Bool { abs(a.r - b.r) <= 3 && abs(a.g - b.g) <= 3 && abs(a.b - b.b) <= 3 }

        for corner in EditSettings.Corner.allCases {
            let (with, bubble) = try draw(corner, camera: camera)
            let without = try draw(corner, camera: nil).pixels
            // In its corner (Core Image counts from the lower left).
            let left = corner == .topLeft || corner == .bottomLeft, bottom = corner == .bottomLeft || corner == .bottomRight
            XCTAssertEqual(bubble.midX < canvas.width / 2, left, "\(corner)")
            XCTAssertEqual(bubble.midY < canvas.height / 2, bottom, "\(corner)")
            // Mirrored: the right half of the camera's picture is blue, so the left of the circle is.
            let l = with.rgb(CGPoint(x: bubble.midX - bubble.width * 0.3, y: bubble.midY))
            let r = with.rgb(CGPoint(x: bubble.midX + bubble.width * 0.3, y: bubble.midY))
            XCTAssertTrue(l.near(0.1, 0.2, 0.9, 12), "\(corner): left of the bubble \(l)")
            XCTAssertTrue(r.near(0.9, 0.1, 0.1, 12), "\(corner): right of the bubble \(r)")
            // A circle: the four corners of its square are the frame as it is without the camera, while the middle
            // of each side, a few pixels in, is the camera.
            let inset: CGFloat = 4
            let corners = [CGPoint(x: bubble.minX + inset, y: bubble.minY + inset), CGPoint(x: bubble.maxX - inset, y: bubble.minY + inset),
                           CGPoint(x: bubble.minX + inset, y: bubble.maxY - inset), CGPoint(x: bubble.maxX - inset, y: bubble.maxY - inset)]
            for p in corners {
                XCTAssertTrue(same(with.rgb(p), without.rgb(p)), "\(corner): the square's corner \(p) is \(with.rgb(p)), not \(without.rgb(p))")
            }
            let sides = [CGPoint(x: bubble.midX, y: bubble.minY + inset), CGPoint(x: bubble.midX, y: bubble.maxY - inset),
                         CGPoint(x: bubble.minX + inset, y: bubble.midY), CGPoint(x: bubble.maxX - inset, y: bubble.midY)]
            for p in sides {
                XCTAssertFalse(same(with.rgb(p), without.rgb(p)), "\(corner): the circle's edge at \(p) shows no camera")
            }
        }
    }
}
