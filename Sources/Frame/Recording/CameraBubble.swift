import AppKit
import FrameCore

/// The camera bubble's measures and the arithmetic with them: where the circle goes, which corner takes it after a
/// drag, whether a point is inside it. It needs neither a screen nor a camera, so the tests run it as it is.
enum BubbleGeometry {
    /// The circle's diameter, in points.
    static let diameter: CGFloat = 168
    /// The gap between the circle and the edge of the screen's usable area.
    static let margin: CGFloat = 24
    /// The window is a little larger than the circle: this much room on every side holds the circle's shadow.
    static let halo: CGFloat = 16
    /// The window is a square of this side with the circle in its middle.
    static var side: CGFloat { diameter + 2 * halo }

    /// The circle's lower left corner when the bubble sits in `corner` of `area`, the usable part of the screen.
    static func circleOrigin(in corner: EditSettings.Corner, of area: NSRect) -> NSPoint {
        let left = corner == .topLeft || corner == .bottomLeft, bottom = corner == .bottomLeft || corner == .bottomRight
        return NSPoint(x: left ? area.minX + margin : area.maxX - margin - diameter,
                       y: bottom ? area.minY + margin : area.maxY - margin - diameter)
    }

    /// The window's lower left corner that puts the circle in `corner` of `area`.
    static func windowOrigin(in corner: EditSettings.Corner, of area: NSRect) -> NSPoint {
        let circle = circleOrigin(in: corner, of: area)
        return NSPoint(x: circle.x - halo, y: circle.y - halo)
    }

    /// The corner of `area` nearest to `point`: where a dropped bubble settles.
    static func corner(nearest point: NSPoint, in area: NSRect) -> EditSettings.Corner {
        let left = point.x < area.midX, bottom = point.y < area.midY
        return left ? (bottom ? .bottomLeft : .topLeft) : (bottom ? .bottomRight : .topRight)
    }

    /// Whether `point`, in the window's coordinates, lies in the circle (its edge counts).
    static func circleContains(_ point: NSPoint) -> Bool {
        let middle = side / 2, dx = point.x - middle, dy = point.y - middle, radius = diameter / 2
        return dx * dx + dy * dy <= radius * radius
    }
}

/// The camera bubble: a round window above everything with the camera's picture, mirrored like a mirror. It can be
/// dragged and settles into the nearest corner of the screen, the lower left one to begin with; the edit starts with
/// the bubble in that corner. The screen recording leaves it out (the app's own windows are excluded), the edit draws
/// the camera in its place, in a circle again.
///
/// The window is round where it counts. It has no frame and no background, only the circle (with its shadow and a thin
/// ring) is drawn in it, so everything else in the square is transparent and the Window Server passes clicks through
/// there. The shadow is drawn with the circle, not by the window: a window shadow follows whatever the window has drawn
/// by then and may come out square. The picture is cut to the circle by the layers themselves, the camera's included.
@MainActor
final class CameraBubble: NSPanel {
    private let area: NSRect
    private(set) var corner: EditSettings.Corner

    /// `picture` is what shows in the circle: the camera's layer, or any other layer (the tests use a still image).
    init(picture: CALayer, area: NSRect, corner: EditSettings.Corner) {
        self.area = area
        self.corner = corner
        let side = BubbleGeometry.side
        super.init(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = BubbleView(picture: picture)
        view.dropped = { [weak self] in self?.settle() }
        contentView = view
        setFrameOrigin(BubbleGeometry.windowOrigin(in: corner, of: area))
    }

    /// Into the corner nearest to where it was dropped.
    private func settle() {
        corner = BubbleGeometry.corner(nearest: NSPoint(x: frame.midX, y: frame.midY), in: area)
        Preferences.bubbleCorner = corner
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            animator().setFrameOrigin(BubbleGeometry.windowOrigin(in: corner, of: area))
        }
    }
}

/// What the bubble's window shows, from the bottom up: the shadow, the disc with the picture in it, the white ring.
/// The view hosts its layers itself (the layer is set before `wantsLayer`, as AppKit asks), so AppKit leaves them alone.
@MainActor
final class BubbleView: NSView {
    /// Called when the bubble is let go after a drag.
    var dropped: (() -> Void)?
    /// A black disc whose shadow is the bubble's. It is a layer of its own: a layer that cuts its content to a circle
    /// would cut its shadow off too.
    let shadowLayer = CALayer()
    /// The circle: whatever lies in it is cut to a disc (`cornerRadius` is half the width, `masksToBounds` is on).
    let discLayer = CALayer()
    /// Turns the picture around its middle, as a mirror does.
    let mirrorLayer = CALayer()
    /// The camera's layer (made by `CameraMic.makePreview`) or a still image, filling the circle to the edge and cut to it
    /// on its own as well. The view only hosts it: whatever the layer needs from the capture session is done by then.
    let picture: CALayer
    let ringLayer = CALayer()
    private var grab = NSPoint.zero

    init(picture: CALayer) {
        self.picture = picture
        super.init(frame: NSRect(x: 0, y: 0, width: BubbleGeometry.side, height: BubbleGeometry.side))
        let root = CALayer()
        root.frame = bounds
        layer = root
        wantsLayer = true

        let d = BubbleGeometry.diameter, halo = BubbleGeometry.halo
        let circle = CGRect(x: halo, y: halo, width: d, height: d), local = CGRect(origin: .zero, size: circle.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowLayer.frame = circle
        shadowLayer.cornerRadius = d / 2
        shadowLayer.backgroundColor = NSColor.black.cgColor
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.4
        shadowLayer.shadowRadius = 8
        shadowLayer.shadowOffset = CGSize(width: 0, height: -3)
        shadowLayer.shadowPath = CGPath(ellipseIn: local, transform: nil)
        root.addSublayer(shadowLayer)

        discLayer.frame = circle
        discLayer.cornerRadius = d / 2
        discLayer.masksToBounds = true
        discLayer.backgroundColor = NSColor.black.cgColor
        root.addSublayer(discLayer)

        mirrorLayer.bounds = local
        mirrorLayer.position = CGPoint(x: d / 2, y: d / 2)
        mirrorLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        discLayer.addSublayer(mirrorLayer)

        picture.frame = local
        picture.cornerRadius = d / 2
        picture.masksToBounds = true
        mirrorLayer.addSublayer(picture)

        ringLayer.frame = circle
        ringLayer.cornerRadius = d / 2
        ringLayer.borderWidth = 2
        ringLayer.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        root.addSublayer(ringLayer)
        CATransaction.commit()
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }

    /// Only the circle takes clicks. `point` is in the superview's coordinates, as AppKit passes it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        return BubbleGeometry.circleContains(local) ? self : nil
    }

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
