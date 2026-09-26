public enum ReplayError: Error, Equatable, Sendable {
    /// The log was made by another simulation version, so this build can't reproduce it (ADR 0002).
    case simulationVersion(log: String, build: String)
    /// A record the race wouldn't accept (unknown seat, bad protest target), at its index in the log.
    case rejectedInput(index: Int)
    case rejectedSeatEvent(index: Int)
    /// Records out of tick order, before the race starts, or after `finalTick`.
    case outOfOrderInput(index: Int)
    case outOfOrderSeatEvent(index: Int)
    case finalTickBeforeStart(Int)
    /// The race ended before the log's final tick.
    case raceOverEarly(atTick: Int)
    /// The race drew another tide state at the gun than the log records (ADR 0003).
    case tideStateAtGun(log: Double?, race: Double?)
}

/// Re-simulates a race from its log (ADR 0002): builds the authoritative race from the header's setup,
/// the data files it names and its wind seed, feeds every input and seat event at its tick, and steps to
/// the log's final tick. It never runs a bot brain: bots' inputs are in the log like everyone else's.
public enum Replayer {
    /// The replayed race at the log's final tick.
    ///
    /// With `requireMatchingVersion` (the default) a log from another simulation version is refused.
    /// Turning it off replays anyway, for tools and for fixed test logs that outlive a revision; the
    /// result is then only this build's reading of the inputs, not the race as it was sailed.
    ///
    /// The files resolve from `catalog`, then this build's bundle (`RaceFiles(resolving:from:)`), and
    /// throw as that does, before anything is simulated.
    public static func replay(
        _ log: RaceLog, requireMatchingVersion: Bool = true, catalog: RaceFileCatalog = RaceFileCatalog()
    ) throws -> Race {
        if requireMatchingVersion && log.header.simulationVersion != simulationVersion {
            throw ReplayError.simulationVersion(log: log.header.simulationVersion, build: simulationVersion)
        }
        let setup = log.header.setup
        let race = try Race(setup: setup, files: RaceFiles(resolving: setup, from: catalog),
                            mode: .authoritative(windSeed: log.header.windSeed))
        guard race.tideStateAtGun == log.header.tideStateAtGun else {
            throw ReplayError.tideStateAtGun(log: log.header.tideStateAtGun, race: race.tideStateAtGun)
        }
        guard log.finalTick >= race.tick else { throw ReplayError.finalTickBeforeStart(log.finalTick) }

        var nextInput = 0
        var nextSeatEvent = 0

        func recordSeatEvents() throws {
            while nextSeatEvent < log.seatEvents.count {
                let event = log.seatEvents[nextSeatEvent]
                guard event.tick <= race.tick else { return }
                guard event.tick == race.tick else { throw ReplayError.outOfOrderSeatEvent(index: nextSeatEvent) }
                guard race.record(event.kind, seat: event.seat) != nil else {
                    throw ReplayError.rejectedSeatEvent(index: nextSeatEvent)
                }
                nextSeatEvent += 1
            }
        }

        try recordSeatEvents()
        while race.tick < log.finalTick {
            let next = race.tick + 1
            while nextInput < log.inputs.count {
                let record = log.inputs[nextInput]
                guard record.tick <= next else { break }
                guard record.tick == next else { throw ReplayError.outOfOrderInput(index: nextInput) }
                let applied: Int?
                switch record.kind {
                case .held(let input): applied = race.apply(input, seat: record.seat, atTick: next)
                case .tap(let tap): applied = race.tap(tap, seat: record.seat, atTick: next)
                }
                guard applied == next else { throw ReplayError.rejectedInput(index: nextInput) }
                nextInput += 1
            }
            race.step()
            guard race.tick == next else { throw ReplayError.raceOverEarly(atTick: race.tick) }
            try recordSeatEvents()
        }
        if nextInput < log.inputs.count { throw ReplayError.outOfOrderInput(index: nextInput) }
        if nextSeatEvent < log.seatEvents.count { throw ReplayError.outOfOrderSeatEvent(index: nextSeatEvent) }
        return race
    }

    /// The replayed race's final digest.
    public static func digest(
        of log: RaceLog, requireMatchingVersion: Bool = true, catalog: RaceFileCatalog = RaceFileCatalog()
    ) throws -> UInt64 {
        try replay(log, requireMatchingVersion: requireMatchingVersion, catalog: catalog).digest()
    }
}
