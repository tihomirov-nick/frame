import CoreGraphics

/// The zoom at one moment: how much, towards which point of the captured area (0…1 from the top left), and how far
/// along the way in and out it is (0…1).
public struct ZoomState: Equatable {
    public var scale: CGFloat
    public var focus: CGPoint
    public var amount: CGFloat

    public static let none = ZoomState(scale: 1, focus: CGPoint(x: 0.5, y: 0.5), amount: 0)
}

/// Where the video zooms with «Приближать к щелчкам» on. Clicks close in time make one zoom: the picture starts moving
/// in a little before the first click (the edit knows what comes next), glides from one click to the next and moves
/// out a while after the last one.
public struct ZoomPlan {
    /// The zoom starts this long before the first click and takes `easeIn` to come in fully.
    public static let leadIn = 0.5
    public static let easeIn = 0.65
    /// It stays this long after the last click, then takes `easeOut` to go back.
    public static let hold = 1.3
    public static let easeOut = 0.8
    /// Gliding to the next click takes this long and ends just after that click.
    public static let pan = 0.6

    public let scale: Double
    public let segments: [[CursorTrack.Click]]

    public init(clicks: [CursorTrack.Click], scale: Double) {
        self.scale = scale
        var segments: [[CursorTrack.Click]] = []
        let inside = clicks.filter { (0...1).contains($0.x) && (0...1).contains($0.y) }.sorted { $0.t < $1.t }
        for click in inside {
            // A click that would start zooming in before the previous zoom is over joins it.
            if let last = segments.last?.last, click.t - Self.leadIn <= last.t + Self.hold + Self.easeOut + 0.2 {
                segments[segments.count - 1].append(click)
            } else {
                segments.append([click])
            }
        }
        self.segments = scale > 1.001 ? segments : []
    }

    public func state(at t: Double) -> ZoomState {
        for clicks in segments {
            let first = clicks[0].t - Self.leadIn, last = clicks[clicks.count - 1].t
            guard t > first, t < last + Self.hold + Self.easeOut else { continue }
            var amount = 1.0
            if t < first + Self.easeIn { amount = Ease.smoother((t - first) / Self.easeIn) }
            if t > last + Self.hold { amount = min(amount, 1 - Ease.smoother((t - last - Self.hold) / Self.easeOut)) }
            var focus = clicks[0].point
            for click in clicks.dropFirst() {
                focus = Ease.lerp(focus, click.point, Ease.smooth((t - (click.t + 0.15 - Self.pan)) / Self.pan))
            }
            return ZoomState(scale: 1 + (scale - 1) * amount, focus: focus, amount: amount)
        }
        return .none
    }
}
