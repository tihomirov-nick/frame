import CoreGraphics
import XCTest
@testable import FrameCore

/// A frame's pixels, read in Core Image coordinates (origin at the bottom left), sRGB.
struct Pixels {
    let width: Int
    let height: Int
    private let data: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.data = data
    }

    func rgb(_ p: CGPoint) -> RGB8 {
        let x = min(max(Int(p.x), 0), width - 1), y = min(max(height - 1 - Int(p.y), 0), height - 1)
        let i = (y * width + x) * 4
        return RGB8(r: Int(data[i]), g: Int(data[i + 1]), b: Int(data[i + 2]))
    }

    /// The orange pixels of the made-up button: how many and their middle.
    func orange() -> (count: Int, center: CGPoint) {
        var count = 0, sx = 0.0, sy = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let r = data[i], g = data[i + 1], b = data[i + 2]
                if r > 200, g > 80, g < 160, b < 50 {
                    count += 1
                    sx += Double(x) + 0.5
                    sy += Double(height - y) - 0.5
                }
            }
        }
        return (count, count > 0 ? CGPoint(x: sx / Double(count), y: sy / Double(count)) : .zero)
    }
}

struct RGB8: CustomStringConvertible {
    let r, g, b: Int

    var dark: Bool { r < 80 && g < 80 && b < 80 }
    var description: String { "(\(r), \(g), \(b))" }

    func near(_ red: Double, _ green: Double, _ blue: Double, _ tolerance: Int) -> Bool {
        abs(r - Int(red * 255)) <= tolerance && abs(g - Int(green * 255)) <= tolerance && abs(b - Int(blue * 255)) <= tolerance
    }
}

/// The checks of two frames of the made-up recording, one before the zoom and one at its height: the same for a frame
/// drawn by the renderer and a frame of the exported video.
func checkFrames(before: Pixels, zoomed: Pixels, renderer: FrameRenderer, times: (before: Double, zoomed: Double),
                 tolerance: Int, file: StaticString = #filePath, line: UInt = #line) {
    let spec = SyntheticRecording.Spec()
    let bg = BackgroundPreset.named(renderer.settings.background).colors[0]
    let corner = CGPoint(x: 4, y: CGFloat(before.height) - 4)
    func body(_ placement: (tip: CGPoint, unit: CGFloat)) -> CGPoint {
        CGPoint(x: placement.tip.x + CursorShape.bodyPoint.x * placement.unit,
                y: placement.tip.y - CursorShape.bodyPoint.y * placement.unit)
    }

    // Before the click: no zoom, the background in the corner, the pointer drawn where it rests.
    XCTAssertEqual(renderer.zoomState(at: times.before).scale, 1, file: file, line: line)
    XCTAssertTrue(before.rgb(corner).near(bg.r, bg.g, bg.b, tolerance), "background: \(before.rgb(corner))", file: file, line: line)
    guard let rest = renderer.pointerPlacement(at: times.before) else { return XCTFail("no pointer", file: file, line: line) }
    let restPoint = renderer.layout.point(spec.rest)
    XCTAssertEqual(rest.tip.x, restPoint.x, accuracy: 0.5, file: file, line: line)
    XCTAssertEqual(rest.tip.y, restPoint.y, accuracy: 0.5, file: file, line: line)
    XCTAssertTrue(before.rgb(body(rest)).dark, "pointer before the zoom: \(before.rgb(body(rest)))", file: file, line: line)

    // At the zoom: the screen fills the frame, the button is scale² larger and where the zoom puts it, the pointer on it.
    let scale = renderer.zoomState(at: times.zoomed).scale
    XCTAssertEqual(scale, renderer.settings.zoomScale, accuracy: 0.001, file: file, line: line)
    XCTAssertFalse(zoomed.rgb(corner).near(bg.r, bg.g, bg.b, tolerance), "background in the zoom: \(zoomed.rgb(corner))",
                   file: file, line: line)
    let small = before.orange(), large = zoomed.orange()
    XCTAssertGreaterThan(small.count, 100, file: file, line: line)
    XCTAssertEqual(Double(large.count) / Double(small.count), scale * scale, accuracy: scale * scale * 0.15, file: file, line: line)
    let expected = renderer.layout.point(spec.target).applying(renderer.transform(at: times.zoomed))
    XCTAssertEqual(large.center.x, expected.x, accuracy: 5, file: file, line: line)
    XCTAssertEqual(large.center.y, expected.y, accuracy: 5, file: file, line: line)
    guard let onButton = renderer.pointerPlacement(at: times.zoomed) else { return XCTFail("no pointer", file: file, line: line) }
    XCTAssertEqual(onButton.tip.x, expected.x, accuracy: 1, file: file, line: line)
    XCTAssertEqual(onButton.tip.y, expected.y, accuracy: 1, file: file, line: line)
    XCTAssertTrue(zoomed.rgb(body(onButton)).dark, "pointer in the zoom: \(zoomed.rgb(body(onButton)))", file: file, line: line)

    // The camera bubble in its corner, outside the zoom.
    let bubble = renderer.bubbleRect
    let wall = zoomed.rgb(CGPoint(x: bubble.midX - bubble.width * 0.38, y: bubble.midY))
    let c = SyntheticRecording.cameraColor
    XCTAssertTrue(wall.near(c.r, c.g, c.b, tolerance), "camera: \(wall)", file: file, line: line)
}
