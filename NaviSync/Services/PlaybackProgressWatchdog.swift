import Foundation

/// Measures actual playhead progress using a monotonic clock, independent of AVPlayer's state labels.
struct PlaybackProgressWatchdog {
    private var lastAdvance: TimeInterval
    private var lastPosition: Double
    private(set) var advancedSeconds: Double = 0

    init(now: TimeInterval, position: Double) {
        lastAdvance = now
        lastPosition = position.isFinite ? position : 0
    }

    mutating func check(now: TimeInterval, position: Double, active: Bool, positioned: Bool) -> Bool {
        guard active else {
            lastAdvance = now
            lastPosition = position.isFinite ? position : 0
            advancedSeconds = 0
            return false
        }
        if positioned, position.isFinite, position < lastPosition {
            // A completed backwards seek establishes a new clock origin.
            lastPosition = position
            lastAdvance = now
            advancedSeconds = 0
        }
        if positioned, position.isFinite, position > lastPosition + 0.05 {
            advancedSeconds += position - lastPosition
            lastPosition = position
            lastAdvance = now
        }
        // Each new stall gets a bounded retry budget, even after a healthy playback period.
        if now - lastAdvance >= 1 { advancedSeconds = 0 }
        return now - lastAdvance >= 8
    }
}
