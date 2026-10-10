import AppKit
import AVFoundation
import FrameCore
import XCTest
@testable import Frame

/// The camera bubble with a still picture in the place of the camera. Nothing here starts the camera, asks for a
/// permission or shows a window: the layers are drawn into bitmaps and the views are asked where a click would land.
@MainActor
final class BubbleTests: XCTestCase {
    private let d = BubbleGeometry.diameter
    private let halo = BubbleGeometry.halo
    private let side = BubbleGeometry.side
    private var r: CGFloat { d / 2 }
    private var mid: CGFloat { side / 2 }

    func testTheLayersCutThePictureToACircle() throws {
        let view = BubbleView(picture: Self.stillLayer())
        for layer in [view.discLayer, view.picture] {
            XCTAssertEqual(layer.cornerRadius, r)
            XCTAssertTrue(layer.masksToBounds)
            XCTAssertEqual(layer.bounds.width, d)
            XCTAssertEqual(layer.bounds.height, d)
        }
        let raster = Raster(try XCTUnwrap(view.layer))
        // Solid all over the circle, edge to edge...
        let k = 0.7 * (r - 6)
        let inside: [(CGFloat, CGFloat)] = [(0, 0), (r - 6, 0), (6 - r, 0), (0, r - 6), (0, 6 - r), (k, k), (-k, -k)]
        for (x, y) in inside {
            XCTAssertEqual(raster.rgba(mid + x, mid + y).a, 1, accuracy: 0.01, "inside the circle at \(x), \(y)")
        }
        // ...and nothing in the corners of the circle's square or of the window, shadow included.
        let near = halo + 3, far = side - halo - 3
        let outside: [(CGFloat, CGFloat)] = [(near, near), (far, near), (near, far), (far, far), (1, 1), (side - 1, 1), (1, side - 1),
                                             (side - 1, side - 1)]
        for (x, y) in outside {
            XCTAssertEqual(raster.rgba(x, y).a, 0, accuracy: 0.005, "outside the circle at \(x), \(y)")
        }
    }

    func testTheShadowFollowsTheCircle() throws {
        let raster = Raster(try XCTUnwrap(BubbleView(picture: Self.stillLayer()).layer))
        // A little below the circle and beside it there is shadow, softer at the side than under it...
        let below = raster.rgba(mid, halo - 4).a, beside = raster.rgba(halo - 4, mid).a, above = raster.rgba(mid, side - halo + 4).a
        XCTAssertGreaterThan(below, 0.08)
        XCTAssertGreaterThan(beside, 0.03)
        XCTAssertGreaterThan(below, beside)
        XCTAssertGreaterThan(beside, above)
        // ...it follows the circle round on the diagonal, and the corner of the circle's square, which a square shadow
        // would fill, has none.
        let out = (r + 4) / 2.0.squareRoot()
        XCTAssertGreaterThan(raster.rgba(mid - out, mid - out).a, 0.03)
        XCTAssertEqual(raster.rgba(halo + 3, halo + 3).a, 0, accuracy: 0.005)
    }

    func testThePictureIsMirroredAndFillsTheCircle() throws {
        let raster = Raster(try XCTUnwrap(BubbleView(picture: Self.stillLayer()).layer))
        // Mirrored: the picture's right half is blue and its left half red, so the circle is blue on the left.
        let left = raster.rgba(mid - 0.6 * r, mid), right = raster.rgba(mid + 0.6 * r, mid)
        XCTAssertGreaterThan(left.b, 0.7)
        XCTAssertLessThan(left.r, 0.3)
        XCTAssertGreaterThan(right.r, 0.7)
        XCTAssertLessThan(right.b, 0.3)
        // Scaled up to fill the circle's square, the longer side cropped: the green stripe that begins where the crop
        // begins touches the edge (mirrored, on the right), and no black bars lie above and below the picture.
        let edge = raster.rgba(mid + r - 4, mid)
        XCTAssertGreaterThan(edge.g, 0.6)
        XCTAssertLessThan(edge.r, 0.4)
        let bars: [(CGFloat, CGFloat)] = [(20, r - 6), (-20, 6 - r)]
        for (x, y) in bars {
            let pixel = raster.rgba(mid + x, mid + y)
            XCTAssertGreaterThan(pixel.r + pixel.g + pixel.b, 0.5, "black at \(x), \(y)")
        }
    }

    func testTheCameraLayerFillsAndIsCutToTheCircleToo() async {
        let preview = await CameraMic().makePreview()
        XCTAssertEqual(preview.videoGravity, .resizeAspectFill)
        let view = BubbleView(picture: preview)
        XCTAssertTrue(preview.superlayer === view.mirrorLayer)
        XCTAssertTrue(view.mirrorLayer.superlayer === view.discLayer)
        XCTAssertEqual(preview.cornerRadius, r)
        XCTAssertTrue(preview.masksToBounds)
        XCTAssertEqual(preview.bounds.size, CGSize(width: d, height: d))
        // The mirror is the layer's turn about its middle; the camera's own mirroring is left off in `CameraMic.makePreview`.
        let turn = view.mirrorLayer.affineTransform()
        XCTAssertEqual(turn.a, -1)
        XCTAssertEqual(turn.d, 1)
        XCTAssertEqual(view.mirrorLayer.position, CGPoint(x: r, y: r))
        // In a window (never shown) the camera's layer has no connection yet, as the session has no input: nothing breaks.
        let bubble = CameraBubble(picture: await CameraMic().makePreview(),
                                  area: NSRect(x: 0, y: 0, width: 800, height: 600), corner: .bottomLeft)
        XCTAssertTrue(bubble.contentView is BubbleView)
    }

    func testOnlyTheCircleTakesClicks() {
        let view = BubbleView(picture: Self.stillLayer())
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.frame.origin = NSPoint(x: 90, y: 40)
        holder.addSubview(view)
        // Offsets from the circle's middle, points; the point is given in the superview's coordinates, as AppKit does.
        func lands(_ dx: CGFloat, _ dy: CGFloat) -> Bool {
            view.hitTest(NSPoint(x: view.frame.midX + dx, y: view.frame.midY + dy)) === view
        }
        let k = 0.7071 * r
        let inside: [(CGFloat, CGFloat)] = [(0, 0), (r - 1, 0), (1 - r, 0), (0, r - 1), (0, 1 - r), (k - 1, k - 1), (1 - k, 1 - k),
                                            (k - 1, 1 - k)]
        for (dx, dy) in inside {
            XCTAssertTrue(lands(dx, dy), "inside the circle at \(dx), \(dy)")
        }
        // Outside the circle, in the shadow's room, in the corner of its square or of the window, a click goes through.
        let outside: [(CGFloat, CGFloat)] = [(r + 2, 0), (-r - 2, 0), (0, r + 2), (0, -r - 2), (k + 2, k + 2), (-k - 2, -k - 2),
                                             (r - 3, r - 3), (mid - 1, mid - 1), (1 - mid, 1 - mid), (mid - 1, 1 - mid)]
        for (dx, dy) in outside {
            XCTAssertFalse(lands(dx, dy), "outside the circle at \(dx), \(dy)")
        }
        // On its own, without a superview, the point is the view's own.
        let alone = BubbleView(picture: Self.stillLayer())
        XCTAssertTrue(alone.hitTest(NSPoint(x: mid, y: mid)) === alone)
        XCTAssertNil(alone.hitTest(NSPoint(x: 2, y: 2)))
    }

    func testTheWindowIsBorderlessTransparentAndClicksThroughTheCornersReachOnlyTheCircle() throws {
        let area = NSRect(x: 100, y: 50, width: 1440, height: 800)
        let bubble = CameraBubble(picture: Self.stillLayer(), area: area, corner: .bottomLeft)
        XCTAssertTrue(bubble.styleMask.contains(.borderless))
        XCTAssertFalse(bubble.isOpaque)
        XCTAssertEqual(bubble.backgroundColor.alphaComponent, 0)
        XCTAssertFalse(bubble.hasShadow, "the shadow is the circle's own, a window's could be a square")
        XCTAssertEqual(bubble.frame.size, NSSize(width: side, height: side))
        // Through the window's own views, as a click would travel: the middle lands on the picture, a corner does not.
        let content = try XCTUnwrap(bubble.contentView)
        let frameView = try XCTUnwrap(content.superview)
        XCTAssertTrue(frameView.hitTest(NSPoint(x: mid, y: mid)) === content)
        XCTAssertFalse(frameView.hitTest(NSPoint(x: 3, y: 3)) === content)
        XCTAssertFalse(frameView.hitTest(NSPoint(x: halo + 3, y: halo + 3)) === content)
        XCTAssertFalse(frameView.hitTest(NSPoint(x: side - halo - 3, y: halo + 3)) === content)
    }

    func testTheBubbleStartsInTheLowerLeftAndSettlesIntoTheNearestCorner() {
        UserDefaults.standard.removeObject(forKey: Preferences.bubbleCornerKey)
        XCTAssertEqual(Preferences.bubbleCorner, .bottomLeft)

        let area = NSRect(x: 100, y: 50, width: 1440, height: 800)
        let margin = BubbleGeometry.margin
        let circles: [EditSettings.Corner: NSPoint] = [
            .bottomLeft: NSPoint(x: 100 + margin, y: 50 + margin),
            .bottomRight: NSPoint(x: 1540 - margin - d, y: 50 + margin),
            .topLeft: NSPoint(x: 100 + margin, y: 850 - margin - d),
            .topRight: NSPoint(x: 1540 - margin - d, y: 850 - margin - d),
        ]
        for corner in EditSettings.Corner.allCases {
            XCTAssertEqual(BubbleGeometry.circleOrigin(in: corner, of: area), circles[corner], "\(corner)")
            let bubble = CameraBubble(picture: Self.stillLayer(), area: area, corner: corner)
            let circle = bubble.frame.insetBy(dx: halo, dy: halo)
            XCTAssertEqual(circle.origin, circles[corner], "the window of \(corner)")
            XCTAssertEqual(circle.size, CGSize(width: d, height: d))
            XCTAssertEqual(bubble.corner, corner)
        }
        // Dropped anywhere, it takes the corner of the quarter it is in.
        XCTAssertEqual(BubbleGeometry.corner(nearest: NSPoint(x: 300, y: 200), in: area), .bottomLeft)
        XCTAssertEqual(BubbleGeometry.corner(nearest: NSPoint(x: 1400, y: 300), in: area), .bottomRight)
        XCTAssertEqual(BubbleGeometry.corner(nearest: NSPoint(x: 400, y: 700), in: area), .topLeft)
        XCTAssertEqual(BubbleGeometry.corner(nearest: NSPoint(x: 1000, y: 800), in: area), .topRight)
    }

    // MARK: The sheet

    /// `FRAME_BUBBLE_SHEET=/tmp/frame-bubble.png swift test --filter BubbleTests/testDrawsTheSheet` draws the bubble with
    /// the still picture instead of the camera into a small picture, off screen: the picture, the bubble over a
    /// checkerboard (so that the transparent corners and the round shadow show) and where a click would land.
    func testDrawsTheSheet() throws {
        guard let path = ProcessInfo.processInfo.environment["FRAME_BUBBLE_SHEET"] else { return }
        let picture = Self.stillPicture()
        let view = BubbleView(picture: Self.stillLayer())
        let root = try XCTUnwrap(view.layer)
        let scale: CGFloat = 2, panel: CGFloat = 232, gap: CGFloat = 16, caption: CGFloat = 30
        let width = gap + 3 * (panel + gap), height = gap + panel + caption + gap
        let ctx = try XCTUnwrap(CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(gray: 0.93, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        func rect(_ i: Int) -> CGRect { CGRect(x: gap + CGFloat(i) * (panel + gap), y: gap + caption, width: panel, height: panel) }
        func place(_ i: Int, draw: () -> Void) {
            ctx.saveGState()
            ctx.clip(to: rect(i))
            draw()
            ctx.restoreGState()
        }
        func centered(_ i: Int, _ size: CGFloat, draw: () -> Void) {
            place(i) {
                ctx.translateBy(x: rect(i).midX - size / 2, y: rect(i).midY - size / 2)
                draw()
            }
        }

        // 1. The picture that stands in for the camera, as it is.
        place(0) {
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(rect(0))
            ctx.draw(picture, in: CGRect(x: rect(0).midX - 112, y: rect(0).midY - 84, width: 224, height: 168))
        }
        // 2. The bubble over a checkerboard: the corners show through, the shadow lies round the circle only.
        place(1) {
            let cell: CGFloat = 8
            for row in 0..<Int(panel / cell) {
                for col in 0..<Int(panel / cell) {
                    ctx.setFillColor(gray: (row + col) % 2 == 0 ? 1 : 0.82, alpha: 1)
                    ctx.fill(CGRect(x: rect(1).minX + CGFloat(col) * cell, y: rect(1).minY + CGFloat(row) * cell, width: cell, height: cell))
                }
            }
        }
        centered(1, side) { root.render(in: ctx) }
        // 3. Where a click lands: green is the bubble's, grey goes through to the window below.
        centered(2, side) {
            let step: CGFloat = 2
            for y in stride(from: CGFloat(0), to: side, by: step) {
                for x in stride(from: CGFloat(0), to: side, by: step) {
                    let hit = BubbleGeometry.circleContains(NSPoint(x: x + step / 2, y: y + step / 2))
                    XCTAssertEqual(hit, view.hitTest(NSPoint(x: x + step / 2, y: y + step / 2)) === view)
                    ctx.setFillColor(hit ? CGColor(red: 0.22, green: 0.72, blue: 0.4, alpha: 1) : CGColor(gray: 0.8, alpha: 1))
                    ctx.fill(CGRect(x: x, y: y, width: step, height: step))
                }
            }
        }
        // Captions.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                         .foregroundColor: NSColor(white: 0.2, alpha: 1)]
        for (i, text) in ["Картинка вместо камеры", "Пузырь на шахматке", "Куда попадает щелчок"].enumerated() {
            let string = text as NSString, size = string.size(withAttributes: attributes)
            string.draw(at: NSPoint(x: rect(i).midX - size.width / 2, y: gap + (caption - size.height) / 2), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()

        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(ctx.makeImage()))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    // MARK: Helpers

    /// Stands in for the camera: 640 × 480, the left half red and the right half blue, a green stripe from x = 80 (where
    /// the circle's square begins when the picture is scaled up to fill it) and a white F in the middle, which
    /// reads the other way round when the picture is mirrored.
    static func stillPicture() -> CGImage {
        let ctx = CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func fill(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) {
            ctx.setFillColor(red: red, green: green, blue: blue, alpha: 1)
            ctx.fill(CGRect(x: x, y: y, width: w, height: h))
        }
        fill(0, 0, 320, 480, 0.9, 0.1, 0.1)
        fill(320, 0, 320, 480, 0.1, 0.2, 0.9)
        fill(80, 0, 20, 480, 0.1, 0.8, 0.2)
        fill(270, 130, 36, 220, 1, 1, 1)
        fill(270, 314, 110, 36, 1, 1, 1)
        fill(270, 220, 80, 36, 1, 1, 1)
        return ctx.makeImage()!
    }

    /// The still picture as a layer, scaled up to fill as the camera's layer does.
    static func stillLayer() -> CALayer {
        let layer = CALayer()
        layer.contents = stillPicture()
        layer.contentsGravity = .resizeAspectFill
        return layer
    }
}

/// A layer drawn into a bitmap, two pixels to the point. Pixels are read by points from the lower left, like the layer's own.
private struct Raster {
    static let scale = 2
    let width: Int
    let height: Int
    private let data: [UInt8]

    @MainActor
    init(_ layer: CALayer) {
        let w = Int(layer.bounds.width) * Self.scale, h = Int(layer.bounds.height) * Self.scale
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let ctx = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.scaleBy(x: CGFloat(Self.scale), y: CGFloat(Self.scale))
            layer.render(in: ctx!)
        }
        width = w
        height = h
        data = pixels
    }

    func rgba(_ x: CGFloat, _ y: CGFloat) -> (r: Double, g: Double, b: Double, a: Double) {
        let px = min(max(Int(x * CGFloat(Self.scale)), 0), width - 1)
        let py = min(max(height - 1 - Int(y * CGFloat(Self.scale)), 0), height - 1)
        let i = (py * width + px) * 4
        return (Double(data[i]) / 255, Double(data[i + 1]) / 255, Double(data[i + 2]) / 255, Double(data[i + 3]) / 255)
    }
}
