import CoreMedia
import Foundation

/// The recording's own time: seconds since the countdown ended, pauses taken out. The screen, the camera, the
/// microphone and the pointer deliver samples with host times on queues of their own; each sample asks the clock where
/// it belongs and is left out before the start, during a pause and after the stop.
public final class RecordingClock {
    private let lock = NSLock()
    private var start: Double?
    private var stop: Double?
    private var pauses: [(from: Double, to: Double?)] = []

    public init() {}

    /// Seconds of the host clock, the clock of ScreenCaptureKit's samples.
    public static var hostNow: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    public func start(at host: Double) {
        lock.withLock {
            start = host
            stop = nil
            pauses = []
        }
    }

    public func pause(at host: Double) {
        lock.withLock {
            guard start != nil, stop == nil, pauses.last.map({ $0.to != nil }) ?? true else { return }
            pauses.append((host, nil))
        }
    }

    public func resume(at host: Double) {
        lock.withLock {
            guard let last = pauses.last, last.to == nil else { return }
            pauses[pauses.count - 1].to = max(host, last.from)
        }
    }

    public func stop(at host: Double) {
        lock.withLock {
            if let last = pauses.last, last.to == nil { pauses[pauses.count - 1].to = host }
            stop = host
        }
    }

    public var isPaused: Bool { lock.withLock { pauses.last.map { $0.to == nil } ?? false } }

    /// Where a sample captured at `host` goes on the recording's timeline; nil when it is left out.
    public func time(forHost host: Double) -> Double? {
        lock.withLock {
            guard let start, host >= start else { return nil }
            if let stop, host > stop { return nil }
            var paused = 0.0
            for pause in pauses {
                if host < pause.from { break }
                guard let to = pause.to, host >= to else { return nil }
                paused += to - pause.from
            }
            return host - start - paused
        }
    }

    /// How much has been recorded by `host`, for the timer on screen: it stands still during a pause.
    public func elapsed(at host: Double) -> Double {
        lock.withLock {
            guard let start else { return 0 }
            let end = min(host, stop ?? host)
            var paused = 0.0
            for pause in pauses where pause.from < end {
                paused += min(pause.to ?? end, end) - pause.from
            }
            return max(0, end - start - paused)
        }
    }
}
