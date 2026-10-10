import AppKit
import XCTest
@testable import Frame

/// How the glyph fills its room: the 22 pt menu bar canvas and the tile of the app icon. Both come from the glyph's
/// `bounds`, the rectangle its ink covers in the glyph's box, so that rectangle must be what the drawing really covers.
final class GlyphTests: XCTestCase {
    /// The ink of `draw` in box units, from a bitmap of 8 pixels per unit.
    private func ink(_ draw: (CGContext) -> Void) throws -> CGRect {
        let ppu: CGFloat = 8, origin: CGFloat = 20, side = Int(140 * ppu)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.translateBy(x: 0, y: CGFloat(side))
        ctx.scaleBy(x: ppu, y: -ppu)
        ctx.translateBy(x: origin, y: origin)
        ctx.setFillColor(.black)
        ctx.setStrokeColor(.black)
        Glyph.prepare(ctx)
        draw(ctx)
        let data = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
        var minX = side, minY = side, maxX = -1, maxY = -1
        for y in 0..<side {
            for x in 0..<side where data[y * ctx.bytesPerRow + x * 4 + 3] >= 8 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return CGRect(x: CGFloat(minX) / ppu - origin, y: CGFloat(minY) / ppu - origin,
                      width: CGFloat(maxX + 1 - minX) / ppu, height: CGFloat(maxY + 1 - minY) / ppu)
    }

    private func assertSame(_ a: CGRect, _ b: CGRect, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        for (x, y) in [(a.minX, b.minX), (a.minY, b.minY), (a.maxX, b.maxX), (a.maxY, b.maxY)] {
            XCTAssertEqual(x, y, accuracy: 0.3, message, file: file, line: line)
        }
    }

    /// The icon drawn four times larger.
    private func render(_ image: NSImage) throws -> NSBitmapImageRep {
        let width = Int(image.size.width * 4), height = Int(image.size.height * 4)
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// The alpha at a point of the glyph's box (100 units square), found through the same placement the icon draws with.
    private func alpha(_ rep: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) -> CGFloat {
        let point = CGPoint(x: x, y: y).applying(Glyph.menuPlacement(bounds: Frame.bounds, scale: 4))
        return rep.colorAt(x: Int(point.x * 4), y: Int(point.y * 4))?.alphaComponent ?? -1
    }

    /// The icon is drawn with the thinner line, so its ink is the bounds. The menu bar's line is thicker and reaches half
    /// the difference further out, into the margin of the canvas; the stop square lies inside the bubble's opening.
    func testTheBoundsAreTheInkOfTheIconAndTheMenuBarStaysNearThem() throws {
        assertSame(try ink { Frame.draw($0, line: Glyph.iconLine, gap: Glyph.iconGap) }, Frame.bounds,
                   "bounds of the glyph in Frame.swift are out of date")
        let reach = (Glyph.menuLine - Glyph.iconLine) / 2 + 0.3
        let menu = try ink { Frame.draw($0, line: Glyph.menuLine, gap: Glyph.menuGap) }
        XCTAssertTrue(Frame.bounds.insetBy(dx: -reach, dy: -reach).contains(menu), "\(menu)")
        XCTAssertTrue(menu.insetBy(dx: -0.3, dy: -0.3).contains(Frame.bounds), "\(menu)")
        let stop = try ink { Frame.draw($0, recording: true, line: Glyph.menuLine, gap: Glyph.menuGap) }
        XCTAssertTrue(menu.insetBy(dx: -0.3, dy: -0.3).contains(stop), "\(stop)")
    }

    func testTheCanvasIs22PointsTallAndTheGlyphIsAsBigAsTheSystemIcons() throws {
        XCTAssertEqual(MenuBarIcon.canvas.height, 22)
        XCTAssertEqual(MenuBarIcon.canvas.width, Glyph.menuCanvas(for: Frame.bounds).width)
        // The size of Wi-Fi and Control Center: 16 pt tall, or 20 pt wide where the proportions would make it wider.
        let expected = Glyph.menuInk(for: Frame.bounds)
        XCTAssertLessThanOrEqual(expected.height, 16.001)
        XCTAssertLessThanOrEqual(expected.width, 20.001)
        XCTAssertTrue(abs(expected.height - 16) < 0.001 || abs(expected.width - 20) < 0.001, "\(expected)")
        defer { MenuBarIcon.recording = false }
        for recording in [false, true] {
            MenuBarIcon.recording = recording
            for badge in [false, true] {
                let rep = try render(MenuBarIcon.image(badge: badge))
                let width = rep.pixelsWide, height = rep.pixelsHigh
                var rows = (min: height, max: -1), columns = (min: width, max: -1)
                for y in 0..<height {
                    for x in 0..<width where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                        rows = (min(rows.min, y), max(rows.max, y)); columns = (min(columns.min, x), max(columns.max, x))
                    }
                }
                let name = "recording: \(recording), badge: \(badge)"
                // Nearly 1 pt (4 px) of room above and below, and the margin at the sides: nothing reaches an edge of the canvas.
                XCTAssertGreaterThanOrEqual(rows.min, badge ? 0 : 3, name)
                XCTAssertGreaterThanOrEqual(columns.min, 3, name)
                XCTAssertLessThanOrEqual(columns.max, width - (badge ? 1 : 3), name)   // the dot is 0.5 pt from the edge
                XCTAssertLessThanOrEqual(rows.max, height - 4, name)
                if !badge && !recording {
                    XCTAssertEqual(CGFloat(rows.max - rows.min + 1) / 4, expected.height, accuracy: 0.6, "the glyph is \(expected.height) pt tall: \(name)")
                    XCTAssertEqual(CGFloat(columns.max - columns.min + 1) / 4, expected.width, accuracy: 0.6, "the glyph is \(expected.width) pt wide: \(name)")
                    XCTAssertEqual(CGFloat(rows.min), CGFloat(height - 1 - rows.max), accuracy: 1.01, "the glyph is centred in the canvas: \(name)")
                }
            }
        }
    }

    /// The rule of the family's menu bar icons, whatever the mark: 16 pt tall, but never wider than 20 pt, on a canvas
    /// 22 pt tall with the ink in the middle; the lines and gaps are counted in box units and shrink with the mark.
    func testTheMenuBarSizeRule() {
        func ink(_ width: CGFloat, _ height: CGFloat) -> CGSize { Glyph.menuInk(for: CGRect(x: 3, y: 5, width: width, height: height)) }
        XCTAssertEqual(ink(80, 80).width, 16, accuracy: 0.001)
        XCTAssertEqual(ink(80, 80).height, 16, accuracy: 0.001)
        XCTAssertEqual(ink(40, 100).width, 6.4, accuracy: 0.001, "a tall mark is 16 pt tall")
        XCTAssertEqual(ink(40, 100).height, 16, accuracy: 0.001)
        XCTAssertEqual(ink(100, 60).width, 20, accuracy: 0.001, "16 pt tall would make this one 26.7 pt wide, so it is 20 wide")
        XCTAssertEqual(ink(100, 60).height, 12, accuracy: 0.001)
        let bounds = CGRect(x: 3, y: 5, width: 100, height: 60)
        XCTAssertEqual(Glyph.menuCanvasHeight, 22)
        XCTAssertEqual(Glyph.menuCanvas(for: bounds), CGSize(width: 22, height: 22))
        XCTAssertEqual(Glyph.menuBox(for: bounds), CGRect(x: 1, y: 5, width: 20, height: 12))
        // The ink's rectangle lands in the middle of the canvas, its top left corner at the box's.
        let corner = CGPoint(x: bounds.minX, y: bounds.minY).applying(Glyph.menuPlacement(bounds: bounds, scale: 2))
        XCTAssertEqual(corner.x, 1, accuracy: 0.001)
        XCTAssertEqual(corner.y, 5, accuracy: 0.001)
        // A line of Glyph.menuLine units is the same share of the mark at every size.
        XCTAssertEqual(Glyph.menuLine * Glyph.menuScale(for: bounds) / ink(100, 60).width, Glyph.menuLine / 100, accuracy: 0.0001)
    }

    /// The bubble is the record dot: a disc at rest, the square of a stop button in the same opening while recording,
    /// and the only difference between the two.
    func testWhileRecordingTheBubbleBecomesAStopSquare() throws {
        defer { MenuBarIcon.recording = false }
        MenuBarIcon.recording = false
        let resting = try render(MenuBarIcon.image())
        MenuBarIcon.recording = true
        let recording = try render(MenuBarIcon.image())
        for (name, glyph) in [("resting", resting), ("recording", recording)] {
            XCTAssertEqual(alpha(glyph, 5, 40), 1, accuracy: 0.01, "\(name): the frame's left side is solid")
            XCTAssertEqual(alpha(glyph, 50, 40), 0, accuracy: 0.01, "\(name): the frame is open inside")
            XCTAssertEqual(alpha(glyph, 29, 72), 1, accuracy: 0.01, "\(name): the bubble or the square is solid")
            XCTAssertEqual(alpha(glyph, 29 + 24, 72), 0, accuracy: 0.01, "\(name): black gap between it and the frame")
            XCTAssertEqual(alpha(glyph, 29 + 30, 72), 1, accuracy: 0.01, "\(name): the frame's bottom side goes on past the gap")
        }
        XCTAssertEqual(alpha(resting, 29 + 20, 72), 1, accuracy: 0.01, "the bubble is a disc of radius 22")
        XCTAssertEqual(alpha(recording, 29 + 20, 72), 0, accuracy: 0.01, "the square is narrower than the disc")
        XCTAssertEqual(alpha(recording, 29 + 14, 72 + 14), 1, accuracy: 0.01, "the square is solid up to its corner")
    }

    func testTheGlyphTakesEightyPercentOfTheTileAndStaysClearOfItsCorners() {
        let long = max(Frame.bounds.width, Frame.bounds.height)
        XCTAssertEqual(Glyph.iconScale(for: Frame.bounds) * long, 0.8 * 824, accuracy: 0.001)
        // The corners of the ink's rectangle lie well inside the tile's rounded corners (the squircle of exponent 5).
        let half = 824 / 2 as CGFloat
        let w = Glyph.iconScale(for: Frame.bounds) * Frame.bounds.width / 2
        let h = Glyph.iconScale(for: Frame.bounds) * Frame.bounds.height / 2
        XCTAssertLessThan(pow(w / half, 5) + pow(h / half, 5), 0.7)
    }
}
