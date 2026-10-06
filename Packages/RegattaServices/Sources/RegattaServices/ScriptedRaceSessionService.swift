/// What a `ScriptedRaceSessionService` plays. Everything is fixed up front; a nil answer is `noRace`.
public struct RaceSessionScenario: Sendable {
    /// The seat in the fleet that has locked.
    public var handOff: HandOff?
    /// The race in progress the player can rejoin.
    public var rejoin: RejoinOffer?
    /// The results stream, in order. A stream ends after its last item.
    public var results: [RaceUpdate]
    /// The rating changes pushed, in order.
    public var ratingChanges: [RatingChange]
    public var lastRace: LastRace?
    /// Nil gives every item at once. Set, the results stream gives one item every `pacing.interval`, the first
    /// after one interval, and the rating changes follow one interval after the last result: a race filling in
    /// live, then closing, then the rating pushed (#133's UI test and preview).
    public var pacing: RaceSessionPacing?

    public init(
        handOff: HandOff? = nil, rejoin: RejoinOffer? = nil, results: [RaceUpdate] = [],
        ratingChanges: [RatingChange] = [], lastRace: LastRace? = nil, pacing: RaceSessionPacing? = nil
    ) {
        self.handOff = handOff
        self.rejoin = rejoin
        self.results = results
        self.ratingChanges = ratingChanges
        self.lastRace = lastRace
        self.pacing = pacing
    }
}

/// How far apart a paced `RaceSessionScenario`'s items come, and how to wait that long. The package keeps no clock
/// (`SourceTests`), so the waiting is the caller's: the app passes a sleep.
public struct RaceSessionPacing: Sendable {
    public var interval: Duration
    /// Waits the given time; may return early when the stream's task is cancelled.
    public var wait: @Sendable (Duration) async -> Void

    public init(interval: Duration, wait: @escaping @Sendable (Duration) async -> Void) {
        self.interval = interval
        self.wait = wait
    }
}

/// A `RaceSessionService` that plays its scenario. Every stream starts from the top of its script and
/// finishes at the end of it (a real one stays open).
public struct ScriptedRaceSessionService: RaceSessionService {
    private let scenario: RaceSessionScenario

    public init(_ scenario: RaceSessionScenario) { self.scenario = scenario }

    public func handOff() throws -> HandOff {
        guard let handOff = scenario.handOff else { throw RaceSessionError.noRace }
        return handOff
    }

    public func rejoin() throws -> RejoinOffer {
        guard let offer = scenario.rejoin else { throw RaceSessionError.noRace }
        return offer
    }

    public func results() -> AsyncStream<RaceUpdate> { Self.stream(of: scenario.results, pacing: scenario.pacing, lead: 0) }

    public func ratingChanges() -> AsyncStream<RatingChange> {
        Self.stream(of: scenario.ratingChanges, pacing: scenario.pacing, lead: scenario.results.count)
    }

    public func lastRace() -> LastRace? { scenario.lastRace }

    /// `items` at once, or with `pacing` one every interval after `lead` intervals' wait.
    private static func stream<Element: Sendable>(of items: [Element], pacing: RaceSessionPacing?, lead: Int) -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self)
        guard let pacing else {
            for item in items { continuation.yield(item) }
            continuation.finish()
            return stream
        }
        let task = Task {
            if lead > 0 { await pacing.wait(pacing.interval * lead) }
            for item in items {
                await pacing.wait(pacing.interval)
                if Task.isCancelled { break }
                continuation.yield(item)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
