// How long the online session waits before it tries the server again (#161): 1, 2, 4, 8 s … up to 30 s, each
// ±20 %, and no more tries after 6 failures in a row until the app comes to the foreground or the player taps
// Race online. A session that opens starts the count over.

public struct Backoff: Equatable, Sendable {
    public var first: Duration
    public var cap: Duration
    /// The share of a delay the jitter moves it by, either way.
    public var jitter: Double
    /// This many failures in a row end the tries.
    public var maxFailures: Int

    public init(first: Duration = .seconds(1), cap: Duration = .seconds(30), jitter: Double = 0.2, maxFailures: Int = 6) {
        self.first = first
        self.cap = cap
        self.jitter = jitter
        self.maxFailures = maxFailures
    }

    /// The wait after the `failures`th failure in a row (1 for the first). `unit` is the caller's jitter draw, −1…1:
    /// this package draws nothing itself.
    public func delay(afterFailures failures: Int, jitter unit: Double) -> Duration {
        var delay = first
        for _ in 1..<max(1, failures) where delay < cap { delay = delay * 2 }
        if delay > cap { delay = cap }
        return delay * (1 + jitter * min(1, max(-1, unit)))
    }

    /// Whether the `failures`th failure in a row is the last try.
    public func stops(afterFailures failures: Int) -> Bool { failures >= maxFailures }
}
