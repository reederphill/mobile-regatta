import Foundation

/// How fast a live race runs, for UI tests on a slow CI runner (#361): the scene records each frame that steps the
/// race, how many ticks it ran and how long its ticks and its render took, and `summary` says how far the race got,
/// e.g. `pace: 94.2 s wall, 8931 ticks (95/s, slowest 10 s window 23/s), 1402 frames (14.9/s), ticks 6.1 ms/frame,
/// render 1.1 ms/frame`. A UI test attaches it (`PaceProbe`), so a failing run's log tells a slow render from a slow sim.
struct PaceMeter: Equatable {
    /// The wall-clock window the slowest pace is measured over.
    static let window: Duration = .seconds(10)

    private(set) var frames = 0
    private(set) var ticks = 0
    private(set) var tickTime: Duration = .zero
    private(set) var renderTime: Duration = .zero
    /// Ticks per second in the slowest complete window so far; nil until one completes.
    private(set) var slowestWindowRate: Double?
    private var first: ContinuousClock.Instant?
    private var last: ContinuousClock.Instant?
    private var windowStart: ContinuousClock.Instant?
    private var windowTicks = 0

    /// One frame that stepped the race, ending at `now`: `ticks` run in `tickTime`, then drawn in `renderTime`.
    mutating func record(ticks: Int, tickTime: Duration, renderTime: Duration, at now: ContinuousClock.Instant) {
        if first == nil {
            first = now
            windowStart = now
        }
        last = now
        frames += 1
        self.ticks += ticks
        self.tickTime += tickTime
        self.renderTime += renderTime
        windowTicks += ticks
        if let start = windowStart, now - start >= Self.window {
            let rate = Double(windowTicks) / Self.seconds(now - start)
            slowestWindowRate = min(slowestWindowRate ?? rate, rate)
            windowStart = now
            windowTicks = 0
        }
    }

    /// Wall-clock seconds from the first frame recorded to the last.
    var wallSeconds: Double {
        guard let first, let last else { return 0 }
        return Self.seconds(last - first)
    }

    var summary: String {
        let wall = wallSeconds
        func perSecond(_ n: Int) -> Double { wall > 0 ? Double(n) / wall : 0 }
        func msPerFrame(_ d: Duration) -> Double { frames > 0 ? Self.seconds(d) * 1000 / Double(frames) : 0 }
        let slowest = slowestWindowRate.map { String(format: "%.0f/s", $0) } ?? "none yet"
        return String(format: "pace: %.1f s wall, %d ticks (%.0f/s, slowest 10 s window %@), %d frames (%.1f/s), "
                      + "ticks %.1f ms/frame, render %.1f ms/frame",
                      wall, ticks, perSecond(ticks), slowest, frames, perSecond(frames), msPerFrame(tickTime),
                      msPerFrame(renderTime))
    }

    static func seconds(_ d: Duration) -> Double {
        let (s, attoseconds) = d.components
        return Double(s) + Double(attoseconds) * 1e-18
    }
}
