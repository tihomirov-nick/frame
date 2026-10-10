import AppKit
import FrameCore
import ScreenCaptureKit
import SwiftUI

/// One recording from the start to the editor: choosing what to record, the devices, the countdown, the panel with
/// the controls, pausing, stopping and cancelling. Started from the panel under the icon, the icon's menu or the
/// shortcut.
@MainActor
final class RecordingController: ObservableObject {
    static let shared = RecordingController()

    enum Phase: Equatable {
        case idle, preparing, countdown, recording, finishing
    }

    @Published private(set) var phase: Phase = .idle {
        didSet {
            MenuBarIcon.recording = phase == .recording
            StatusItem.shared.refreshIcon()
        }
    }
    @Published private(set) var paused = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var countdown: Int?

    var isActive: Bool { phase != .idle }

    /// Everything of the recording in progress.
    @MainActor
    private final class Session {
        let folder: RecordingFolder
        let plan: CapturePlan
        let clock = RecordingClock()
        let writer: MovieWriter
        let screen: ScreenCapture
        let devices: CameraMic
        let cursor: CursorTracker
        var windows: [NSWindow] = []
        var bubble: CameraBubble?

        init(folder: RecordingFolder, plan: CapturePlan, devices: CameraMic) throws {
            self.folder = folder
            self.plan = plan
            self.devices = devices
            let audio: [Int] = (devices.hasMicrophone ? [1] : []) + (plan.configuration.capturesAudio ? [2] : [])
            writer = try MovieWriter(url: folder.screenURL, video: .init(width: plan.width, height: plan.height, fps: plan.fps),
                                     audioChannels: audio, clock: clock)
            screen = ScreenCapture(writer: writer, systemTrack: devices.hasMicrophone ? 1 : 0)
            cursor = CursorTracker(clock: clock, area: plan.area)
        }
    }

    private var session: Session?
    private var ticker: Timer?

    // MARK: Starting

    func start(_ mode: Preferences.Mode? = nil) {
        guard phase == .idle else { return }
        StatusItem.shared.hidePanel()
        Task { await begin(mode ?? Preferences.mode) }
    }

    /// The shortcut starts a recording, stops the one in progress, or calls off the countdown.
    func toggleFromShortcut() {
        switch phase {
        case .idle: start()
        case .recording: stop()
        case .countdown, .preparing: cancel()
        case .finishing: break
        }
    }

    private func begin(_ mode: Preferences.Mode) async {
        guard await Permission.screen.request() else {
            SoundEffects.play(.failure)
            StatusItem.shared.showPanel()
            return
        }
        phase = .preparing
        do {
            // Off-screen windows too: then the app itself is in the list even with its panel closed, and its windows
            // (the bubble, the countdown, the bar) can be left out of the picture.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard phase == .preparing, let choice = await chooseTarget(mode, content: content) else {
                if phase == .preparing { phase = .idle }
                return
            }
            let (target, screen) = choice
            let camera = Preferences.camera ? await Permission.camera.request() : false
            let microphone = Preferences.microphone ? await Permission.microphone.request() : false
            guard phase == .preparing else { return }
            let plan = CapturePlan(target: target, content: content, systemAudio: Preferences.systemAudio)
            try FileManager.default.createDirectory(at: Preferences.folder, withIntermediateDirectories: true)
            // The session is set up and the camera's layer made on the session's own queue, and the session starts only
            // after both (see CameraMic): a layer made while the session starts takes the app down.
            let devices = CameraMic()
            await devices.configure(camera: camera, microphone: microphone)
            let preview = devices.hasCamera ? await devices.makePreview() : nil
            // The recording may have been called off while the devices were being set up; nothing has started yet.
            guard phase == .preparing else { return }
            let session = try Session(folder: try RecordingFolder.create(in: Preferences.folder), plan: plan, devices: devices)
            self.session = session
            // The stream can stop on its own (a display unplugged, the permission taken away): what was recorded is kept.
            session.screen.onStop = { [weak self] error in
                guard let self else { return }
                if phase == .recording { stop() } else { fail(error) }
            }
            if let preview {
                let bubble = CameraBubble(picture: preview, area: screen.visibleFrame, corner: Preferences.bubbleCorner)
                bubble.orderFrontRegardless()
                session.bubble = bubble
                session.windows.append(bubble)
            }
            devices.start(cameraURL: devices.hasCamera ? session.folder.cameraURL : nil,
                          micWriter: devices.hasMicrophone ? session.writer : nil, clock: session.clock)
            try await session.screen.start(plan)
            guard self.session === session else {
                await session.screen.stop()
                return
            }

            // The countdown: the devices are already running, the recording's clock starts after «1».
            phase = .countdown
            let counter = FloatingPanel(size: NSSize(width: 170, height: 170), content: CountdownView(controller: self))
            counter.ignoresMouseEvents = true
            counter.setFrameOrigin(NSPoint(x: screen.frame.midX - 85, y: screen.frame.midY - 85))
            session.windows.append(counter)
            counter.orderFrontRegardless()
            for n in [3, 2, 1] {
                countdown = n
                try await Task.sleep(nanoseconds: 1_000_000_000)
                guard self.session === session else { return }
            }
            countdown = nil
            counter.orderOut(nil)

            session.clock.start(at: RecordingClock.hostNow)
            session.cursor.start()
            let bar = FloatingPanel(size: NSSize(width: 256, height: 64), content: RecordingBarView(controller: self))
            bar.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 128, y: screen.visibleFrame.minY + 16))
            bar.orderFrontRegardless()
            session.windows.append(bar)
            paused = false
            elapsed = 0
            phase = .recording
            SoundEffects.play(.start)
            ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let session = self.session else { return }
                    self.elapsed = session.clock.elapsed(at: RecordingClock.hostNow)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            fail(error)
        }
    }

    /// The display under the pointer, the window from the menu or the area dragged out, and the screen it is on.
    private func chooseTarget(_ mode: Preferences.Mode, content: SCShareableContent) async -> (CapturePlan.Target, NSScreen)? {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen, let display = content.displays.first(where: { $0.displayID == screen.displayID })
            ?? content.displays.first else { return nil }
        switch mode {
        case .display:
            return (.display(display), screen)
        case .window:
            guard let window = WindowPicker.pick(from: content) else { return nil }
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            let center = NSPoint(x: window.frame.midX, y: top - window.frame.midY)
            return (.window(window), NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) } ?? screen)
        case .area:
            guard let rect = await AreaSelector.select(on: screen) else { return nil }
            return (.area(display, rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)), screen)
        }
    }

    // MARK: During the recording

    func togglePause() {
        guard phase == .recording, let session else { return }
        let now = RecordingClock.hostNow
        if paused { session.clock.resume(at: now) } else { session.clock.pause(at: now) }
        paused.toggle()
        elapsed = session.clock.elapsed(at: now)
    }

    /// Stops and opens the editor. During the countdown there is nothing to keep yet: the same as cancelling.
    func stop() {
        guard phase == .recording, let session else {
            if phase == .countdown || phase == .preparing { cancel() }
            return
        }
        phase = .finishing
        Task {
            if let folder = await finish(session) {
                SoundEffects.play(.success)
                EditorWindows.show(folder)
            }
        }
    }

    /// Before quitting: the recording in progress is saved, not lost.
    func finishBeforeQuit() async {
        guard let session else { return }
        if phase == .recording || phase == .finishing {
            phase = .finishing
            _ = await finish(session)
        } else {
            cancel()
        }
    }

    private func finish(_ session: Session) async -> RecordingFolder? {
        let end = RecordingClock.hostNow
        session.clock.stop(at: end)
        let duration = session.clock.elapsed(at: end)
        ticker?.invalidate()
        ticker = nil
        let track = session.cursor.stop()
        let corner = session.bubble?.corner ?? Preferences.bubbleCorner
        session.windows.forEach { $0.orderOut(nil) }
        await session.screen.stop()
        let camera = await session.devices.stop()
        do {
            try await session.writer.finish(at: duration)
            var hasCamera = false
            if let camera, camera.videoFrames > 0 {
                try await camera.finish(at: duration)
                hasCamera = true
            }
            try session.folder.save(track)
            var edit = Preferences.lastEdit
            edit.cameraCorner = corner
            try session.folder.save(RecordingProject(duration: duration, source: session.plan.source,
                                                     screenSize: CGSize(width: session.plan.width, height: session.plan.height),
                                                     hasCamera: hasCamera, hasMicrophone: session.devices.hasMicrophone,
                                                     hasSystemAudio: session.plan.configuration.capturesAudio, edit: edit))
            await session.folder.makeThumbnail()
            self.session = nil
            phase = .idle
            RecentStore.shared.reload()
            return session.folder
        } catch {
            fail(error)
            return nil
        }
    }

    /// Stops everything and throws the recording away.
    func cancel() {
        guard let session else {
            phase = .idle
            return
        }
        self.session = nil
        countdown = nil
        ticker?.invalidate()
        ticker = nil
        _ = session.cursor.stop()
        session.windows.forEach { $0.orderOut(nil) }
        phase = .idle
        SoundEffects.play(.delete)
        Task {
            await session.screen.stop()
            _ = await session.devices.stop()?.cancel()
            session.writer.cancel()
            try? FileManager.default.removeItem(at: session.folder.url)
        }
    }

    private func fail(_ error: Error) {
        if let session {
            self.session = nil
            ticker?.invalidate()
            ticker = nil
            _ = session.cursor.stop()
            session.windows.forEach { $0.orderOut(nil) }
            Task {
                await session.screen.stop()
                _ = await session.devices.stop()?.cancel()
                session.writer.cancel()
                try? FileManager.default.removeItem(at: session.folder.url)
            }
        }
        countdown = nil
        phase = .idle
        SoundEffects.play(.failure)
        let alert = NSAlert()
        alert.messageText = L("Запись не получилась")
        alert.informativeText = error.localizedDescription
        NSApp.activate()
        alert.runModal()
    }

    /// The panel and the bar as they look 1 min 23 s into a recording, for the preview pictures.
    func showForPreview() {
        phase = .recording
        elapsed = 83
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
