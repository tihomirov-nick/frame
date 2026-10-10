import AppKit
import AVFoundation
import FrameCore
import ScreenCaptureKit
import SwiftUI

/// The camera bubble: a round window above everything with the camera's picture, mirrored like a mirror. It can be
/// dragged and settles into the nearest corner of the screen; the edit starts with the bubble in that corner. The
/// screen recording leaves it out (the app's own windows are excluded), the edit draws the camera in its place.
@MainActor
final class CameraBubble: NSPanel {
    static let diameter: CGFloat = 168
    private let area: NSRect
    private(set) var corner: EditSettings.Corner

    init(session: AVCaptureSession, screen: NSScreen, corner: EditSettings.Corner) {
        area = screen.visibleFrame
        self.corner = corner
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = BubbleView(session: session, size: Self.diameter)
        view.dropped = { [weak self] in self?.settle() }
        contentView = view
        setFrameOrigin(origin(for: corner))
    }

    private func origin(for corner: EditSettings.Corner) -> NSPoint {
        let margin: CGFloat = 24, d = Self.diameter
        let left = corner == .topLeft || corner == .bottomLeft, bottom = corner == .bottomLeft || corner == .bottomRight
        return NSPoint(x: left ? area.minX + margin : area.maxX - margin - d, y: bottom ? area.minY + margin : area.maxY - margin - d)
    }

    /// Into the corner nearest to where it was dropped.
    private func settle() {
        let mid = NSPoint(x: frame.midX, y: frame.midY)
        let left = mid.x < area.midX, bottom = mid.y < area.midY
        corner = left ? (bottom ? .bottomLeft : .topLeft) : (bottom ? .bottomRight : .topRight)
        Preferences.bubbleCorner = corner
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            animator().setFrameOrigin(origin(for: corner))
        }
    }
}

private final class BubbleView: NSView {
    var dropped: (() -> Void)?
    private var grab = NSPoint.zero

    init(session: AVCaptureSession, size: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        let root = CALayer()
        root.cornerRadius = size / 2
        root.masksToBounds = true
        root.borderWidth = 2
        root.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        root.backgroundColor = NSColor.black.cgColor
        layer = root
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = bounds
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        root.addSublayer(preview)
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        grab = NSPoint(x: mouse.x - window.frame.minX, y: mouse.y - window.frame.minY)
    }

    override func mouseDragged(with event: NSEvent) {
        let mouse = NSEvent.mouseLocation
        window?.setFrameOrigin(NSPoint(x: mouse.x - grab.x, y: mouse.y - grab.y))
    }

    override func mouseUp(with event: NSEvent) {
        dropped?()
    }
}

/// A small panel of the app above all windows, never taking focus.
@MainActor
class FloatingPanel: NSPanel {
    init<Content: View>(size: NSSize, content: Content) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = NSHostingView(rootView: content.environment(\.colorScheme, .dark))
    }
}

/// The controls while recording: the time, «Пауза», «Стоп» and «Отменить», at the bottom of the screen.
struct RecordingBarView: View {
    @ObservedObject var controller: RecordingController

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(controller.paused ? Palette.secondary : Color.red)
                .frame(width: 9, height: 9)
            Text(formatTime(controller.elapsed))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .frame(width: 52, alignment: .leading)
            Spacer(minLength: 0)
            BarButton(symbol: controller.paused ? "play.fill" : "pause.fill",
                      help: controller.paused ? L("Продолжить запись") : L("Поставить запись на паузу")) {
                controller.togglePause()
            }
            BarButton(symbol: "stop.fill", help: L("Остановить запись и открыть монтаж")) { controller.stop() }
            BarButton(symbol: "xmark", help: L("Отменить запись: файл не сохранится")) { controller.cancel() }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(width: 236, height: 44)
        .background(Color.black.opacity(0.94), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .foregroundStyle(.white)
        .padding(10)
    }
}

private struct BarButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.2 : 0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// 3, 2, 1 in the middle of the screen before the recording starts.
struct CountdownView: View {
    @ObservedObject var controller: RecordingController

    var body: some View {
        Text(controller.countdown.map(String.init) ?? "")
            .font(.system(size: 72, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .frame(width: 150, height: 150)
            .background(Circle().fill(Color.black.opacity(0.8)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: controller.countdown)
            .padding(10)
    }
}

/// "1:05" or "1:05:02".
func formatTime(_ seconds: Double, tenths: Bool = false) -> String {
    let t = max(seconds, 0)
    let whole = Int(t), h = whole / 3600, m = (whole / 60) % 60, s = whole % 60
    var text = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    if tenths { text += String(format: ".%d", Int((t - Double(whole)) * 10)) }
    return text
}

/// The area to record: the screen dims and a rectangle is dragged out on it. Esc gives up.
@MainActor
final class AreaSelector: NSWindow {
    private var finish: ((CGRect?) -> Void)?

    /// The chosen area of `screen` in global points with the origin at the top left, as ScreenCaptureKit counts.
    static func select(on screen: NSScreen) async -> CGRect? {
        let window = AreaSelector(screen: screen)
        return await withCheckedContinuation { continuation in
            window.finish = { rect in
                window.orderOut(nil)
                continuation.resume(returning: rect)
            }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    private init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.done = { [weak self] rect in
            guard let self else { return }
            let global = rect.map {
                CGRect(x: $0.minX + screen.frame.minX, y: top - ($0.maxY + screen.frame.minY), width: $0.width, height: $0.height)
            }
            finish?(global)
            finish = nil
        }
        contentView = view
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    var done: ((NSRect?) -> Void)?
    private var start: NSPoint?
    private var current: NSPoint?

    private var selection: NSRect? {
        guard let start, let current else { return nil }
        return NSRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x),
                      height: abs(current.y - start.y))
    }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.4).setFill()
        bounds.fill()
        guard let rect = selection else {
            let hint = L("Выделите область для записи. Esc отменяет выбор") as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium),
                                                             .foregroundColor: NSColor.white]
            let size = hint.size(withAttributes: attributes)
            hint.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
            return
        }
        NSColor.clear.setFill()
        rect.fill(using: .copy)
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.setLineDash([6, 4], count: 2, phase: 0)
        border.stroke()
        let label = "\(Int(rect.width)) × \(Int(rect.height))" as NSString
        label.draw(at: NSPoint(x: rect.minX, y: max(rect.minY - 20, 4)),
                   withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white])
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let rect = selection, rect.width >= 40, rect.height >= 40 else {
            start = nil
            current = nil
            needsDisplay = true
            return
        }
        done?(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { done?(nil) } else { super.keyDown(with: event) }
    }
}

/// The window to record, picked from a menu of the open windows at the pointer.
@MainActor
enum WindowPicker {
    static func pick(from content: SCShareableContent) -> SCWindow? {
        let own = ProcessInfo.processInfo.processIdentifier
        let windows = content.windows.filter {
            $0.windowLayer == 0 && $0.isOnScreen && $0.frame.width >= 120 && $0.frame.height >= 80
                && $0.owningApplication.map { $0.processID != own && !$0.applicationName.isEmpty } == true
        }
        let menu = NSMenu()
        let header = NSMenuItem(title: windows.isEmpty ? L("Нет открытых окон") : L("Какое окно записать?"), action: nil,
                                keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        var picked: SCWindow?
        for window in windows {
            guard let app = window.owningApplication else { continue }
            let title = (window.title ?? "").isEmpty ? app.applicationName : "\(app.applicationName) — \(window.title ?? "")"
            let item = ClosureMenuItem(String(title.prefix(80))) { picked = window }
            if let icon = NSRunningApplication(processIdentifier: app.processID)?.icon {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            menu.addItem(item)
        }
        NSApp.activate()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return picked
    }
}
