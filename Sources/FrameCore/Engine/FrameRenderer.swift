import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// A layer drawn over the finished frame, above the camera. Subtitles will be one.
public protocol FrameOverlay {
    /// The layer at `time` of the recording in the output's pixels (origin at the bottom left), nil for nothing.
    func image(at time: Double, canvas: CGSize) -> CIImage?
}

/// Where the screen goes in the frame before any zoom, in Core Image coordinates (origin at the bottom left).
public struct FrameLayout {
    public let canvas: CGSize
    /// The screen picture: fitted into the frame inside the margins.
    public let content: CGRect
    public let radius: CGFloat

    public init(canvas: CGSize, source: CGSize, padding: Double, cornerRadius: Double) {
        self.canvas = canvas
        let short = min(canvas.width, canvas.height)
        let box = CGRect(origin: .zero, size: canvas).insetBy(dx: short * padding, dy: short * padding)
        let scale = min(box.width / max(source.width, 1), box.height / max(source.height, 1))
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        content = CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
        radius = short * cornerRadius
    }

    /// A point of the captured area (0…1 from the top left) in the frame.
    public func point(_ p: CGPoint) -> CGPoint {
        CGPoint(x: content.minX + p.x * content.width, y: content.maxY - p.y * content.height)
    }

    /// The unzoomed picture → the output, zoomed `scale` times towards `focus` (a point of the frame). The view moves
    /// from the middle to the focus as the zoom comes in (`amount`) and never leaves the frame; once it fits into the
    /// screen picture it stays inside it, so no background shows at the edges.
    public func zoomTransform(scale: CGFloat, focus: CGPoint, amount: CGFloat) -> CGAffineTransform {
        guard scale > 1.0001 else { return .identity }
        let want = Ease.lerp(CGPoint(x: content.midX, y: content.midY), focus, amount)
        func clamp(_ c: CGFloat, half: CGFloat, low: CGFloat, high: CGFloat, size: CGFloat) -> CGFloat {
            var lo = half, hi = size - half
            if 2 * half <= high - low {
                lo = max(lo, low + half)
                hi = min(hi, high - half)
            }
            return lo > hi ? (lo + hi) / 2 : min(max(c, lo), hi)
        }
        let cx = clamp(want.x, half: canvas.width / scale / 2, low: content.minX, high: content.maxX, size: canvas.width)
        let cy = clamp(want.y, half: canvas.height / scale / 2, low: content.minY, high: content.maxY, size: canvas.height)
        return CGAffineTransform(translationX: -cx, y: -cy)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: canvas.width / 2, y: canvas.height / 2))
    }
}

/// The pointer drawn into the video: the macOS arrow, black with a white edge and a soft shadow.
public enum CursorShape {
    /// The outline with the tip at 0,0, y going down; one unit is about the arrow's height.
    static let outline: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 0.80), CGPoint(x: 0.19, y: 0.63), CGPoint(x: 0.31, y: 0.91),
        CGPoint(x: 0.44, y: 0.86), CGPoint(x: 0.33, y: 0.59), CGPoint(x: 0.58, y: 0.59),
    ]
    /// One unit as a share of the screen picture's height, at the size 1.
    public static let heightShare: CGFloat = 0.042
    /// A point deep in the black of the arrow, in units from the tip (y going down).
    public static let bodyPoint = CGPoint(x: 0.18, y: 0.45)
    /// Pixels per unit in the drawn image.
    static let unit: CGFloat = 200

    /// The image and its tip in Core Image coordinates.
    static let image: (image: CIImage, tip: CGPoint) = {
        let pad = unit * 0.14
        let width = Int(unit * 0.58 + 2 * pad), height = Int(unit * 0.91 + 2 * pad)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (CIImage.empty(), .zero) }
        let tip = CGPoint(x: pad, y: CGFloat(height) - pad)
        let path = CGMutablePath()
        path.addLines(between: outline.map { CGPoint(x: tip.x + $0.x * unit, y: tip.y - $0.y * unit) })
        path.closeSubpath()
        ctx.setLineJoin(.round)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -unit * 0.03), blur: unit * 0.07,
                      color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(unit * 0.09)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        guard let cg = ctx.makeImage() else { return (CIImage.empty(), .zero) }
        return (CIImage(cgImage: cg), tip)
    }()
}

/// One frame of the finished video: the background, the screen with its margins, rounded corners and shadow, the
/// drawn pointer, all zoomed together towards a click, then the camera bubble and the overlays on top. Times are the
/// recording's. Core Image coordinates, pixels of the output.
public final class FrameRenderer {
    public let canvas: CGSize
    public let settings: EditSettings
    public let layout: FrameLayout
    public let overlays: [FrameOverlay]
    private let track: CursorTrack
    private let smooth: SmoothCursor?
    private let zoom: ZoomPlan
    private let lock = NSLock()
    private var backdropImage: CIImage?

    /// `smooth`: the smoothed pointer when it is already worked out (the editor redraws with every change).
    public init(canvas: CGSize, source: CGSize, settings: EditSettings, cursor: CursorTrack, smooth: SmoothCursor? = nil,
                overlays: [FrameOverlay] = []) {
        self.canvas = canvas
        self.settings = settings
        self.overlays = overlays
        track = cursor
        layout = FrameLayout(canvas: canvas, source: source, padding: settings.padding, cornerRadius: settings.cornerRadius)
        self.smooth = settings.smoothCursor ? smooth ?? SmoothCursor(track: cursor) : nil
        zoom = ZoomPlan(clicks: settings.zoom ? cursor.clicks : [], scale: settings.zoomScale)
    }

    public func zoomState(at t: Double) -> ZoomState { zoom.state(at: t) }

    /// The unzoomed picture → the output at `t`.
    public func transform(at t: Double) -> CGAffineTransform {
        let state = zoom.state(at: t)
        return layout.zoomTransform(scale: state.scale, focus: layout.point(state.focus), amount: state.amount)
    }

    /// The pointer at `t` in the captured area (0…1 from the top left), smoothed when that is on.
    public func pointer(at t: Double) -> CGPoint? {
        smooth?.position(at: t) ?? track.position(at: t)
    }

    /// The drawn pointer's tip in the output at `t` and the length of one `CursorShape` unit there, in pixels. Nil
    /// while the pointer is outside the captured area.
    public func pointerPlacement(at t: Double) -> (tip: CGPoint, unit: CGFloat)? {
        guard let p = pointer(at: t), (-0.01...1.01).contains(p.x), (-0.01...1.01).contains(p.y) else { return nil }
        let transform = transform(at: t)
        let unit = layout.content.height * CursorShape.heightShare * settings.cursorSize * press(at: t) * transform.a
        return (layout.point(p).applying(transform), unit)
    }

    /// The pointer shrinks a little when it clicks and springs back.
    private func press(at t: Double) -> CGFloat {
        var amount = 0.0
        for click in track.clicks where t > click.t - 0.01 && t < click.t + 0.35 {
            let dt = t - click.t
            amount = max(amount, dt < 0.06 ? Ease.smooth(dt / 0.06) : 1 - Ease.smooth((dt - 0.06) / 0.29))
        }
        return 1 - 0.18 * amount
    }

    /// Where the camera bubble goes: its corner, its size.
    public var bubbleRect: CGRect {
        let short = min(canvas.width, canvas.height)
        let d = (short * settings.cameraSize).rounded(), margin = (short * 0.04).rounded()
        let left = settings.cameraCorner == .topLeft || settings.cameraCorner == .bottomLeft
        let bottom = settings.cameraCorner == .bottomLeft || settings.cameraCorner == .bottomRight
        return CGRect(x: left ? margin : canvas.width - margin - d, y: bottom ? margin : canvas.height - margin - d,
                      width: d, height: d)
    }

    public func render(screen: CIImage?, camera: CIImage?, at t: Double, context: CIContext) -> CIImage {
        let bounds = CGRect(origin: .zero, size: canvas)
        let transform = transform(at: t)
        var frame = backdrop(context).transformed(by: transform)
        if let screen {
            let e = screen.extent
            let place = CGAffineTransform(translationX: -e.minX, y: -e.minY)
                .concatenating(CGAffineTransform(scaleX: layout.content.width / e.width, y: layout.content.height / e.height))
                .concatenating(CGAffineTransform(translationX: layout.content.minX, y: layout.content.minY))
                .concatenating(transform)
            let mask = roundedRect(layout.content.applying(transform), radius: layout.radius * transform.a, color: .white)
            frame = screen.transformed(by: place, highQualityDownsample: true)
                .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: mask])
                .composited(over: frame)
        }
        if let placement = pointerPlacement(at: t) {
            let shape = CursorShape.image, k = placement.unit / CursorShape.unit
            let move = CGAffineTransform(translationX: -shape.tip.x, y: -shape.tip.y)
                .concatenating(CGAffineTransform(scaleX: k, y: k))
                .concatenating(CGAffineTransform(translationX: placement.tip.x, y: placement.tip.y))
            frame = shape.image.transformed(by: move, highQualityDownsample: true).composited(over: frame)
        }
        frame = frame.cropped(to: bounds)
        if settings.cameraVisible, let camera {
            frame = bubble(camera).composited(over: frame)
        }
        for overlay in overlays {
            if let image = overlay.image(at: t, canvas: canvas) { frame = image.composited(over: frame) }
        }
        return frame.cropped(to: bounds)
    }

    /// The background with the screen's shadow: the same in every frame, so it is drawn once.
    private func backdrop(_ context: CIContext) -> CIImage {
        lock.lock()
        defer { lock.unlock() }
        if let backdropImage { return backdropImage }
        let bounds = CGRect(origin: .zero, size: canvas)
        var image = BackgroundPreset.named(settings.background).image(in: bounds)
        if settings.shadow {
            let short = min(canvas.width, canvas.height)
            let shadow = roundedRect(layout.content.offsetBy(dx: 0, dy: -short * 0.012), radius: layout.radius,
                                     color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.5))
                .applyingGaussianBlur(sigma: short * 0.022)
            image = shadow.composited(over: image)
        }
        image = image.cropped(to: bounds)
        let drawn = context.createCGImage(image, from: bounds).map { CIImage(cgImage: $0) } ?? image
        backdropImage = drawn
        return drawn
    }

    /// The camera in a circle, mirrored as the bubble shows it on screen, with a soft shadow.
    private func bubble(_ camera: CIImage) -> CIImage {
        let rect = bubbleRect
        let mirrored = camera.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
        let e = mirrored.extent, k = rect.width / max(min(e.width, e.height), 1)
        let face = mirrored.transformed(by: CGAffineTransform(translationX: -e.midX, y: -e.midY)
            .concatenating(CGAffineTransform(scaleX: k, y: k))
            .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY)), highQualityDownsample: true)
        let center = CIVector(x: rect.midX, y: rect.midY)
        let circle = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": center, "inputRadius0": rect.width / 2 - 1, "inputRadius1": rect.width / 2,
            "inputColor0": CIColor.white, "inputColor1": CIColor.clear,
        ])?.outputImage?.cropped(to: rect) ?? CIImage.empty()
        let shadow = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: rect.midX, y: rect.midY - rect.width * 0.03), "inputRadius0": rect.width * 0.42,
            "inputRadius1": rect.width * 0.56, "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 0.35),
            "inputColor1": CIColor.clear,
        ])?.outputImage?.cropped(to: rect.insetBy(dx: -rect.width * 0.1, dy: -rect.width * 0.1)) ?? CIImage.empty()
        return face.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: circle])
            .composited(over: shadow)
    }

    private func roundedRect(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        let generator = CIFilter.roundedRectangleGenerator()
        generator.extent = rect
        generator.radius = Float(radius)
        generator.color = color
        return generator.outputImage ?? CIImage.empty()
    }
}
