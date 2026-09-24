import RegattaBots
import RegattaCore
import RegattaProtocol

extension SeatControllers {
    /// A bot in every seat of `race` but `humanSeat`, whatever its setup calls the seats.
    init(race: Race, humanSeat: Int) {
        self.init(race.boats.indices.map { seat in
            seat == humanSeat ? .human : .bot(BotDriver(seat: seat, raceSeed: race.setup.raceSeed))
        })
    }
}

/// The roster a host sends in its `RaceStart`: bots by their sailing names (#60), players as "Helm n".
func roster(of race: Race) -> [RosterEntry] {
    let names = FleetRoster(setup: race.setup)
    return race.boats.map { RosterEntry(name: names[$0.id].sailingName ?? "Helm \($0.id + 1)", colorIndex: $0.colorIndex) }
}

/// An authoritative race whose seats but `humanSeat` are sailed by RegattaBots' seat controllers through
/// the input API (#60), as a race host sails its bots: `step()` lets the bots decide, then steps the race.
/// Reads the race's properties through to it.
@dynamicMemberLookup
final class BotSailedRace {
    let race: Race
    private var seats: SeatControllers

    init(_ race: Race, humanSeat: Int) {
        self.race = race
        seats = SeatControllers(race: race, humanSeat: humanSeat)
    }

    subscript<T>(dynamicMember keyPath: KeyPath<Race, T>) -> T { race[keyPath: keyPath] }

    func step() {
        seats.drive(race)
        race.step()
    }

    @discardableResult
    func apply(_ input: BoatInput, seat: Int, atTick stamp: Int) -> Int? { race.apply(input, seat: seat, atTick: stamp) }

    func exportSnapshot() -> WorldSnapshot { race.exportSnapshot() }
}
