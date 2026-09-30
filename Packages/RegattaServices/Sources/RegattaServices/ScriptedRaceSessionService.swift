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

    public init(
        handOff: HandOff? = nil, rejoin: RejoinOffer? = nil, results: [RaceUpdate] = [],
        ratingChanges: [RatingChange] = [], lastRace: LastRace? = nil
    ) {
        self.handOff = handOff
        self.rejoin = rejoin
        self.results = results
        self.ratingChanges = ratingChanges
        self.lastRace = lastRace
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

    public func results() -> AsyncStream<RaceUpdate> { Self.stream(of: scenario.results) }

    public func ratingChanges() -> AsyncStream<RatingChange> { Self.stream(of: scenario.ratingChanges) }

    public func lastRace() -> LastRace? { scenario.lastRace }

    private static func stream<Element: Sendable>(of items: [Element]) -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self)
        for item in items { continuation.yield(item) }
        continuation.finish()
        return stream
    }
}
