import AVFoundation
import FrameCore
import XCTest
@testable import Frame

/// The camera's capture session without a camera. A real AVCaptureSession with no device in it starts, stops and takes a
/// preview layer just as it does in a recording, so the order of these calls can be tried as it is. Nothing here
/// touches the camera or the microphone, asks for a permission or shows a window.
///
/// The crash these tests keep out was a race: the preview layer was made on the main thread while `startRunning` ran on
/// the session's queue. AVFoundation answers that with an NSGenericException, so when the order slips the test run ends
/// in a crash, not in a failed assertion.
@MainActor
final class CaptureSessionTests: XCTestCase {
    /// Sets the session up with neither camera nor microphone: nothing to ask permission for.
    private func configureEmpty(_ devices: CameraMic) async {
        await devices.configure(camera: false, microphone: false)
    }

    func testAPreviewMadeWhileTheSessionStartsDoesNotCrash() async {
        for _ in 0..<300 {
            let devices = CameraMic(runsWithoutDevices: true)
            await configureEmpty(devices)
            // Asked for from two tasks at once, in whichever order they land: the queue takes them one after the other.
            async let preview = devices.makePreview()
            devices.start(cameraURL: nil, micWriter: nil, clock: RecordingClock())
            let layer = await preview
            _ = await devices.stop()
            XCTAssertEqual(layer.session?.isRunning, false)
        }
    }

    func testTheSessionRunsBetweenTheStartAndTheStop() async throws {
        let devices = CameraMic(runsWithoutDevices: true)
        await configureEmpty(devices)
        let preview = await devices.makePreview()
        let session = try XCTUnwrap(preview.session)
        XCTAssertFalse(session.isRunning)
        devices.start(cameraURL: nil, micWriter: nil, clock: RecordingClock())
        // The next job on the queue comes after the start.
        _ = await devices.makePreview()
        XCTAssertTrue(session.isRunning)
        let writer = await devices.stop()
        XCTAssertNil(writer, "no frame came, so there is no camera writer")
        XCTAssertFalse(session.isRunning)
    }

    func testStoppingRightAfterStartingLeavesTheSessionStopped() async throws {
        for _ in 0..<100 {
            let devices = CameraMic(runsWithoutDevices: true)
            await configureEmpty(devices)
            let preview = await devices.makePreview()
            let session = try XCTUnwrap(preview.session)
            devices.start(cameraURL: nil, micWriter: nil, clock: RecordingClock())
            _ = await devices.stop()
            XCTAssertFalse(session.isRunning, "the stop waits for the start before it, it does not overtake it")
        }
    }

    func testACameraStoppedBeforeItStartedNeverStarts() async throws {
        let devices = CameraMic(runsWithoutDevices: true)
        await configureEmpty(devices)
        let preview = await devices.makePreview()
        let session = try XCTUnwrap(preview.session)
        _ = await devices.stop()
        devices.start(cameraURL: nil, micWriter: nil, clock: RecordingClock())
        _ = await devices.makePreview()
        XCTAssertFalse(session.isRunning)
        // And a second stop does no harm.
        _ = await devices.stop()
    }

    func testARecordingWithoutCameraAndMicrophoneStartsNothing() async throws {
        let devices = CameraMic()
        await configureEmpty(devices)
        XCTAssertFalse(devices.hasCamera)
        XCTAssertFalse(devices.hasMicrophone)
        let preview = await devices.makePreview()
        let session = try XCTUnwrap(preview.session)
        devices.start(cameraURL: nil, micWriter: nil, clock: RecordingClock())
        _ = await devices.makePreview()
        XCTAssertFalse(session.isRunning, "an empty session is left alone")
        let writer = await devices.stop()
        XCTAssertNil(writer)
    }

    func testTheMainThreadIsFreeWhileTheQueueIsBusy() async {
        let devices = CameraMic(runsWithoutDevices: true)
        // A startRunning that takes its time, as one with a real camera can.
        devices.sessionQueue.async { Thread.sleep(forTimeInterval: 0.5) }
        let begun = Date()
        let waiting = Task { @MainActor () -> TimeInterval in
            await devices.configure(camera: false, microphone: false)
            _ = await devices.stop()
            return Date().timeIntervalSince(begun)
        }
        var ticks = 0
        while Date().timeIntervalSince(begun) < 0.4 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            ticks += 1
        }
        XCTAssertGreaterThan(ticks, 3, "the main thread went on while the calls waited for the queue")
        let waited = await waiting.value
        XCTAssertGreaterThan(waited, 0.45, "the calls wait for their turn on the queue")
    }
}
