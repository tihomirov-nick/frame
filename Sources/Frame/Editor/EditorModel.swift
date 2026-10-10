import AppKit
import AVFoundation
import FrameCore
import SwiftUI

/// The edit of one recording: the player of the preview, the trim, the look, the export. Every change is drawn by the
/// same compositor as the export and saved to the recording's project.json.
@MainActor
final class EditorModel: ObservableObject {
    enum ExportState: Equatable {
        case idle
        case running(Double)
        case done(URL)
        case failed(String)
    }

    let folder: RecordingFolder
    let player = AVPlayer()
    let clickTimes: [Double]
    @Published private(set) var project: RecordingProject
    @Published var edit: EditSettings {
        didSet { if edit != oldValue { editChanged(from: oldValue) } }
    }
    @Published var options: ExportOptions {
        didSet {
            Preferences.exportOptions = options
            if options != oldValue { redraw() }
        }
    }
    @Published private(set) var time: Double = 0
    @Published private(set) var playing = false
    @Published private(set) var exportState: ExportState = .idle
    /// A still frame in place of the player, for the preview pictures.
    @Published var poster: CGImage?
    private var studio: StudioComposition?
    private var exporter: Exporter?
    private var saving: Task<Void, Never>?
    private var observer: Any?

    var duration: Double { project.duration }
    var range: ClosedRange<Double> { edit.range(duration: duration) }
    var canvas: CGSize { options.canvas(for: studio?.source ?? project.screenSize) }
    var isExporting: Bool {
        if case .running = exportState { return true }
        return false
    }

    init(folder: RecordingFolder) throws {
        self.folder = folder
        let project = try folder.loadProject()
        self.project = project
        edit = project.edit
        options = Preferences.exportOptions
        clickTimes = folder.loadCursor().clicks.map(\.t)
        if let name = project.lastExport, FileManager.default.fileExists(atPath: folder.url.appendingPathComponent(name).path) {
            exportState = .done(folder.url.appendingPathComponent(name))
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
    }

    /// Puts the recording into the player.
    func load() async {
        do {
            let studio = try await StudioComposition.build(folder: folder, settings: edit, canvas: options.canvas(for: project.screenSize),
                                                           fps: 30, keepCamera: true)
            self.studio = studio
            let item = AVPlayerItem(asset: studio.asset)
            item.videoComposition = studio.videoComposition
            player.replaceCurrentItem(with: item)
            seek(to: range.lowerBound)
        } catch {
            exportState = .failed(error.localizedDescription)
        }
    }

    /// The frame of the preview at `time` as the export draws it.
    func frame(at time: Double) async -> CGImage? {
        guard let studio else { return nil }
        return try? await studio.frame(at: time)
    }

    private func editChanged(from old: EditSettings) {
        var look = edit, oldLook = old
        look.trimStart = 0
        look.trimEnd = nil
        oldLook.trimStart = 0
        oldLook.trimEnd = nil
        if look != oldLook { redraw() }
        saving?.cancel()
        saving = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            project.edit = edit
            try? folder.save(project)
            Preferences.lastEdit = edit
        }
    }

    /// A new edit for the same tracks: the player keeps its place, a paused frame is drawn again.
    private func redraw() {
        guard let studio, let item = player.currentItem else { return }
        let updated = studio.with(edit, canvas: options.canvas(for: studio.source))
        self.studio = updated
        item.videoComposition = updated.videoComposition
        if !playing { seek(to: time) }
    }

    // MARK: Playing and trimming

    func togglePlay() {
        if playing {
            player.pause()
            playing = false
            return
        }
        if time < range.lowerBound || time >= range.upperBound - 0.05 { seek(to: range.lowerBound) }
        player.play()
        playing = true
    }

    func seek(to t: Double) {
        time = min(max(t, 0), duration)
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func tick(_ t: Double) {
        guard playing else { return }
        time = t
        if t >= range.upperBound {
            player.pause()
            playing = false
            seek(to: range.upperBound)
        }
    }

    /// The trim from the handles of the timeline: at least half a second stays.
    func setTrim(start: Double? = nil, end: Double? = nil) {
        var next = edit
        if let start { next.trimStart = min(max(0, start), (next.trimEnd ?? duration) - 0.5) }
        if let end {
            let value = max(min(duration, end), next.trimStart + 0.5)
            next.trimEnd = value >= duration - 0.01 ? nil : value
        }
        edit = next
        seek(to: start != nil ? next.trimStart : (next.trimEnd ?? duration))
    }

    // MARK: Export

    func export() {
        guard !isExporting else { return }
        player.pause()
        playing = false
        let exporter = Exporter()
        self.exporter = exporter
        exportState = .running(0)
        let url = folder.exportURL, edit = edit, options = options, duration = duration, folder = folder
        Task {
            do {
                try await exporter.export(folder: folder, settings: edit, duration: duration, options: options, to: url) { progress in
                    Task { @MainActor in
                        if case .running = self.exportState { self.exportState = .running(progress) }
                    }
                }
                project.lastExport = url.lastPathComponent
                project.edit = self.edit
                try? folder.save(project)
                exportState = .done(url)
                SoundEffects.play(.success)
                RecentStore.shared.reload()
            } catch Exporter.Failure.cancelled {
                exportState = .idle
            } catch {
                exportState = .failed(error.localizedDescription)
                SoundEffects.play(.failure)
            }
            self.exporter = nil
        }
    }

    func cancelExport() {
        exporter?.cancel()
    }

    func revealExport() {
        guard case .done(let url) = exportState else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// The file itself on the clipboard: it pastes into Finder, Mail or a chat.
    func copyExport() {
        guard case .done(let url) = exportState else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        SoundEffects.play(.mark)
    }
}

/// The open editor windows, one per recording.
@MainActor
enum EditorWindows {
    private static var open: [URL: (window: NSWindow, model: EditorModel)] = [:]
    private static var observers: [URL: NSObjectProtocol] = [:]

    static var isExporting: Bool { open.values.contains { $0.model.isExporting } }

    static func cancelExports() {
        open.values.forEach { $0.model.cancelExport() }
    }

    static func show(_ folder: RecordingFolder) {
        NSApp.activate()
        if let existing = open[folder.url] {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        guard let model = try? EditorModel(folder: folder) else {
            SoundEffects.play(.failure)
            return
        }
        let window = makeWindow(model)
        open[folder.url] = (window, model)
        observers[folder.url] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                                       queue: .main) { _ in
            MainActor.assumeIsolated {
                model.player.pause()
                model.cancelExport()
                open[folder.url] = nil
                observers.removeValue(forKey: folder.url).map(NotificationCenter.default.removeObserver)
            }
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        Task { await model.load() }
    }

    static func makeWindow(_ model: EditorModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = L("Монтаж: %@", model.folder.name)
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.minSize = NSSize(width: 960, height: 640)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorView(model: model))
        return window
    }
}
