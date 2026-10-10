import AppKit
import FrameCore
import SwiftUI

/// `--render-previews <folder>`: the menu bar icon, the panel under it (also during a recording), the recording bar,
/// the editor with a made-up recording and Settings drawn into one picture, <folder>/preview.png, through hosting views
/// in windows that are never shown. Nothing starts: no status item, no updater, no login item, no capture; the
/// made-up recordings live in a temporary folder and go away.
@MainActor
enum PreviewRenderer {
    static func run(into folder: URL) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Made-up recordings in a temporary folder: the panel lists them, the editor opens the newest, already exported.
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("FramePreview-\(UUID().uuidString)")
        let recordings = temporary.appendingPathComponent(AppName.value, isDirectory: true)
        Preferences.folderOverride = recordings
        defer { try? FileManager.default.removeItem(at: temporary) }
        let made = wait { () async -> RecordingFolder? in
            var spec = SyntheticRecording.Spec()
            spec.audio = false
            spec.duration = 5
            _ = try? await SyntheticRecording.make(in: recordings, spec: spec)
            spec.duration = 12
            _ = try? await SyntheticRecording.make(in: recordings, spec: spec)
            spec.duration = 3
            guard let folder = try? await SyntheticRecording.make(in: recordings, spec: spec),
                  var project = try? folder.loadProject() else { return nil }
            try? await Exporter().export(folder: folder, settings: project.edit, duration: project.duration,
                                         options: ExportOptions(fps: 30), to: folder.exportURL)
            project.lastExport = folder.exportURL.lastPathComponent
            try? folder.save(project)
            return folder
        }
        RecentStore.shared.reload()
        guard let made, let model = try? EditorModel(folder: made) else {
            print("failed to make the recordings")
            return
        }
        wait { await model.load() }
        model.seek(to: 1.6)
        model.poster = wait { await model.frame(at: 1.6) }

        guard let panel = snapshot(PanelView()), let settings = snapshot(SettingsWindow.makeWindow()),
              let editor = snapshot(EditorWindows.makeWindow(model)) else {
            print("failed to draw the views")
            return
        }
        RecordingController.shared.showForPreview()
        guard let recordingPanel = snapshot(PanelView()), let bar = snapshot(RecordingBarView(controller: .shared)) else {
            print("failed to draw the views")
            return
        }

        let margin: CGFloat = 24, strip: CGFloat = 24, zoom: CGFloat = 4
        let left = max(panel.size.width, bar.size.width, 160)
        let leftHeight = strip + 6 + panel.size.height + margin + recordingPanel.size.height + margin + bar.size.height + margin
            + MenuBarIcon.canvas.height * zoom
        let width = margin + left + margin + editor.size.width + margin + settings.size.width + margin
        let height = margin + max(leftHeight, editor.size.height, settings.size.height) + margin
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.17, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let ctx = NSGraphicsContext.current?.cgContext

        // Left: a strip of menu bar with the icon, the panel under it, the panel during a recording, the bar at the
        // bottom of the screen, and the icon four times larger (with the dot of an update, then while recording).
        let top = height - margin
        let stripRect = NSRect(x: margin, y: top - strip, width: left, height: strip)
        NSColor(white: 0.08, alpha: 1).setFill()
        NSBezierPath(roundedRect: stripRect, xRadius: 6, yRadius: 6).fill()
        MenuBarIcon.recording = false
        white(MenuBarIcon.image()).draw(in: NSRect(x: stripRect.midX - MenuBarIcon.canvas.width / 2,
                                                   y: stripRect.midY - MenuBarIcon.canvas.height / 2,
                                                   width: MenuBarIcon.canvas.width, height: MenuBarIcon.canvas.height))
        var y = stripRect.minY - 6
        for picture in [panel, recordingPanel, bar] {
            y -= picture.size.height
            ctx?.draw(picture.image, in: NSRect(x: stripRect.midX - picture.size.width / 2, y: y, width: picture.size.width,
                                                height: picture.size.height))
            y -= margin
        }
        let large = NSSize(width: MenuBarIcon.canvas.width * zoom, height: MenuBarIcon.canvas.height * zoom)
        white(MenuBarIcon.image(badge: true)).draw(in: NSRect(x: stripRect.midX - large.width - 8, y: y - large.height,
                                                              width: large.width, height: large.height))
        MenuBarIcon.recording = true
        white(MenuBarIcon.image()).draw(in: NSRect(x: stripRect.midX + 8, y: y - large.height, width: large.width,
                                                   height: large.height))
        MenuBarIcon.recording = false

        // The editor in the middle, Settings on the right.
        let editorRect = NSRect(x: margin + left + margin, y: top - editor.size.height, width: editor.size.width,
                                height: editor.size.height)
        ctx?.draw(editor.image, in: editorRect)
        ctx?.draw(settings.image, in: NSRect(x: editorRect.maxX + margin, y: top - settings.size.height,
                                             width: settings.size.width, height: settings.size.height))
        NSGraphicsContext.restoreGraphicsState()

        let url = folder.appendingPathComponent("preview.png")
        if let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil {
            print("wrote \(url.path)")
        } else {
            print("failed to write \(url.path)")
        }
    }

    /// Runs async work to the end while the main run loop keeps turning (the work may need the main actor).
    private static func wait<T>(_ work: @escaping () async -> T) -> T {
        let box = ResultBox<T>()
        Task {
            box.value = await work()
            box.done = true
        }
        while !box.done { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return box.value!
    }

    /// The view as drawn by a real hosting view, at its own size.
    private static func snapshot<V: View>(_ view: V) -> (image: CGImage, size: NSSize)? {
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep.cgImage.map { ($0, size) }
    }

    /// A window with its title bar, never ordered on screen.
    private static func snapshot(_ window: NSWindow) -> (image: CGImage, size: NSSize)? {
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let frame = window.contentView?.superview else { return nil }
        frame.layoutSubtreeIfNeeded()
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return nil }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        return rep.cgImage.map { ($0, frame.bounds.size) }
    }

    /// A template image in white, as the dark menu bar shows it.
    private static func white(_ image: NSImage) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
    var done = false
}
