import CoreGraphics
import Foundation

/// Where the pointer was during a recording. The system cursor stays out of the picture, so its positions and clicks
/// are written apart. Times are seconds of the recording (pauses taken out). Positions are shares of the captured area
/// from its top left corner, 0…1, whatever the resolution; the pointer can leave the area (below 0 or above 1).
public struct CursorTrack: Codable, Equatable, Sendable {
    public struct Sample: Codable, Equatable, Sendable {
        public var t: Double
        public var x: Double
        public var y: Double

        public init(t: Double, x: Double, y: Double) {
            self.t = t
            self.x = x
            self.y = y
        }

        public var point: CGPoint { CGPoint(x: x, y: y) }
    }

    public typealias Click = Sample

    public var samples: [Sample]
    public var clicks: [Click]

    public init(samples: [Sample] = [], clicks: [Click] = []) {
        self.samples = samples
        self.clicks = clicks
    }

    /// The recorded position at `t`: straight lines between samples, the first and the last one held.
    public func position(at t: Double) -> CGPoint? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if t <= first.t { return first.point }
        if t >= last.t { return last.point }
        var lo = 0, hi = samples.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if samples[mid].t <= t { lo = mid } else { hi = mid }
        }
        let a = samples[lo], b = samples[hi]
        let k = b.t > a.t ? (t - a.t) / (b.t - a.t) : 1
        return CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
    }
}

/// Builds a track from positions polled many times a second and keeps only the changes. A resting pointer costs two
/// samples, where it stopped and the last moment it was still there, so the straight lines between samples stay true.
public struct CursorTrackBuilder {
    private var track = CursorTrack()
    private var resting: CursorTrack.Sample?

    public init() {}

    public mutating func move(t: Double, x: Double, y: Double) {
        guard t > (resting?.t ?? track.samples.last?.t ?? -.infinity) else { return }
        if let last = track.samples.last, last.x == x, last.y == y {
            resting = .init(t: t, x: x, y: y)
            return
        }
        if let resting { track.samples.append(resting) }
        resting = nil
        track.samples.append(.init(t: t, x: x, y: y))
    }

    public mutating func click(t: Double, x: Double, y: Double) {
        track.clicks.append(.init(t: t, x: x, y: y))
    }

    public var finished: CursorTrack {
        var result = track
        if let resting { result.samples.append(resting) }
        return result
    }
}
