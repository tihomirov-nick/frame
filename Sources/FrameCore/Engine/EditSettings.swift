import CoreImage
import Foundation

/// The edit of one recording, kept in its project.json. Missing keys of an older file take the defaults.
public struct EditSettings: Codable, Equatable, Sendable {
    public enum Corner: String, Codable, CaseIterable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// The part of the recording that goes into the video, seconds. No end: to the end.
    public var trimStart: Double = 0
    public var trimEnd: Double?
    public var zoom = true
    public var zoomScale: Double = 1.8
    public var smoothCursor = true
    public var cursorSize: Double = 1
    public var background = BackgroundPreset.defaultID
    /// The margin around the screen, a share of the frame's shorter side.
    public var padding: Double = 0.07
    /// The radius of the screen's corners, a share of the frame's shorter side.
    public var cornerRadius: Double = 0.022
    public var shadow = true
    public var cameraVisible = true
    public var cameraCorner: Corner = .bottomLeft
    /// The bubble's diameter, a share of the frame's shorter side.
    public var cameraSize: Double = 0.24

    public init() {}

    /// The trimmed part of a recording `duration` seconds long; at least a tenth of a second.
    public func range(duration: Double) -> ClosedRange<Double> {
        let start = min(max(trimStart, 0), max(duration - 0.1, 0))
        let end = min(max(trimEnd ?? duration, start + 0.1), max(duration, start + 0.1))
        return start...end
    }

    private enum Key: String, CodingKey {
        case trimStart, trimEnd, zoom, zoomScale, smoothCursor, cursorSize, background, padding, cornerRadius, shadow
        case cameraVisible, cameraCorner, cameraSize
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let d = EditSettings()
        trimStart = try c.decodeIfPresent(Double.self, forKey: .trimStart) ?? d.trimStart
        trimEnd = try c.decodeIfPresent(Double.self, forKey: .trimEnd)
        zoom = try c.decodeIfPresent(Bool.self, forKey: .zoom) ?? d.zoom
        zoomScale = try c.decodeIfPresent(Double.self, forKey: .zoomScale) ?? d.zoomScale
        smoothCursor = try c.decodeIfPresent(Bool.self, forKey: .smoothCursor) ?? d.smoothCursor
        cursorSize = try c.decodeIfPresent(Double.self, forKey: .cursorSize) ?? d.cursorSize
        background = try c.decodeIfPresent(String.self, forKey: .background) ?? d.background
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? d.padding
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? d.cornerRadius
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? d.shadow
        cameraVisible = try c.decodeIfPresent(Bool.self, forKey: .cameraVisible) ?? d.cameraVisible
        cameraCorner = try c.decodeIfPresent(Corner.self, forKey: .cameraCorner) ?? d.cameraCorner
        cameraSize = try c.decodeIfPresent(Double.self, forKey: .cameraSize) ?? d.cameraSize
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(trimStart, forKey: .trimStart)
        try c.encodeIfPresent(trimEnd, forKey: .trimEnd)
        try c.encode(zoom, forKey: .zoom)
        try c.encode(zoomScale, forKey: .zoomScale)
        try c.encode(smoothCursor, forKey: .smoothCursor)
        try c.encode(cursorSize, forKey: .cursorSize)
        try c.encode(background, forKey: .background)
        try c.encode(padding, forKey: .padding)
        try c.encode(cornerRadius, forKey: .cornerRadius)
        try c.encode(shadow, forKey: .shadow)
        try c.encode(cameraVisible, forKey: .cameraVisible)
        try c.encode(cameraCorner, forKey: .cameraCorner)
        try c.encode(cameraSize, forKey: .cameraSize)
    }
}

/// The backgrounds under the screen: gradients and solid colours.
public struct BackgroundPreset: Identifiable, Equatable {
    public struct RGB: Equatable {
        public var r, g, b: Double

        init(_ hex: Int) {
            r = Double((hex >> 16) & 0xFF) / 255
            g = Double((hex >> 8) & 0xFF) / 255
            b = Double(hex & 0xFF) / 255
        }

        public var ciColor: CIColor { CIColor(red: r, green: g, blue: b) }
    }

    public let id: String
    /// One colour is a solid background, two make a gradient.
    public let colors: [RGB]
    /// The gradient's direction in degrees: 0 goes from left to right, 90 from the bottom up.
    public let angle: Double

    init(_ id: String, _ colors: [Int], angle: Double = -45) {
        self.id = id
        self.colors = colors.map(RGB.init)
        self.angle = angle
    }

    public static let all: [BackgroundPreset] = [
        BackgroundPreset("ocean", [0x2F80ED, 0x56CCF2]),
        BackgroundPreset("dusk", [0xFF7A59, 0xC2378A]),
        BackgroundPreset("lavender", [0x7F7FD5, 0xE5A6E8]),
        BackgroundPreset("mint", [0x11998E, 0x6FE3A8]),
        BackgroundPreset("peach", [0xF6D365, 0xFDA085]),
        BackgroundPreset("night", [0x141E30, 0x3A4D6B]),
        BackgroundPreset("snow", [0xF2F2F5]),
        BackgroundPreset("graphite", [0x2C2C2E]),
        BackgroundPreset("black", [0x000000]),
        BackgroundPreset("sky", [0x4A90E2]),
    ]

    public static let defaultID = "ocean"

    public static func named(_ id: String) -> BackgroundPreset {
        all.first { $0.id == id } ?? all[0]
    }

    public var isGradient: Bool { colors.count > 1 }

    /// The background filling `rect` (Core Image coordinates).
    public func image(in rect: CGRect) -> CIImage {
        guard colors.count > 1 else { return CIImage(color: colors[0].ciColor).cropped(to: rect) }
        let a = angle * .pi / 180, dx = cos(a), dy = sin(a)
        let half = (abs(dx) * rect.width + abs(dy) * rect.height) / 2
        let gradient = CIFilter(name: "CISmoothLinearGradient", parameters: [
            "inputPoint0": CIVector(x: rect.midX - dx * half, y: rect.midY - dy * half),
            "inputPoint1": CIVector(x: rect.midX + dx * half, y: rect.midY + dy * half),
            "inputColor0": colors[0].ciColor,
            "inputColor1": colors[1].ciColor,
        ])
        return (gradient?.outputImage ?? CIImage(color: colors[0].ciColor)).cropped(to: rect)
    }
}
