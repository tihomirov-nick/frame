import CoreGraphics

/// The pointer as the video shows it with «Плавный курсор» on. A critically damped spring pulls a point towards the
/// recorded position: jerks and the shake of the hand become glides, and nothing overshoots. On a steady move a spring
/// lags 2/ω behind what it follows, so it follows the position that much ahead of time and still lands on the button
/// when the click comes. The path is worked out once, 120 points a second, with straight lines between them.
public struct SmoothCursor {
    public static let rate = 120.0
    private let start: Double
    private let points: [CGPoint]

    public init(track: CursorTrack, omega: Double = 10) {
        guard let first = track.samples.first, let last = track.samples.last else {
            start = 0
            points = []
            return
        }
        start = first.t
        let lead = 2 / omega, substeps = 4
        let dt = 1 / (Self.rate * Double(substeps))
        let count = Int(((last.t - first.t + 2 * lead) * Self.rate).rounded(.up)) + 1
        var x = first.x, y = first.y, vx = 0.0, vy = 0.0, t = first.t
        var points: [CGPoint] = []
        points.reserveCapacity(count)
        for _ in 0..<count {
            points.append(CGPoint(x: x, y: y))
            for _ in 0..<substeps {
                let target = track.position(at: t + lead) ?? first.point
                vx += (omega * omega * (target.x - x) - 2 * omega * vx) * dt
                vy += (omega * omega * (target.y - y) - 2 * omega * vy) * dt
                x += vx * dt
                y += vy * dt
                t += dt
            }
        }
        self.points = points
    }

    public func position(at t: Double) -> CGPoint? {
        guard let first = points.first, let last = points.last else { return nil }
        let f = (t - start) * Self.rate
        if f <= 0 { return first }
        let i = Int(f)
        if i >= points.count - 1 { return last }
        return Ease.lerp(points[i], points[i + 1], f - Double(i))
    }
}
