import RegattaCore

/// Who is sailing a seat right now (#60). Swappable at any tick: a bot takes over a seat given
/// away before the gun, or a dropped player's boat, and hands it back when they rejoin (#19).
/// The race never knows: every controller reaches it through the same input API.
public enum SeatController: Sendable {
    /// A player sends the inputs (a device, or the server's input queue); nothing to drive here.
    case human
    /// A bot fills the seat.
    case bot(BotDriver)
    /// A bot sails a dropped player's boat until they rejoin (#19): the cautious bot (#104, `BotDriver.cautious`).
    case dropped(BotDriver)

    /// The driver sailing the seat, if a bot is.
    public var driver: BotDriver? {
        switch self {
        case .human: nil
        case .bot(let driver), .dropped(let driver): driver
        }
    }

    public var isHuman: Bool { driver == nil }
}

/// One controller per seat of a race: bots for the setup's bot seats, humans for the rest.
/// Call `drive(_:)` once per tick, before `race.step()`.
public struct SeatControllers: Sendable {
    public private(set) var seats: [SeatController]

    /// `.bot` for each bot seat of `setup`, `.human` for each human seat.
    public init(setup: RaceSetup) {
        seats = setup.seats.indices.map { seat in
            setup.seats[seat] == .bot ? .bot(BotDriver(seat: seat, raceSeed: setup.raceSeed)) : .human
        }
    }

    public init(_ seats: [SeatController]) {
        self.seats = seats
    }

    /// A bot takes `seat` over from wherever the boat is (#19, #104), at any tick: between steps, after `drive(_:)` and
    /// `race.step()` or before them. `cautious`, the cautious bot sails a dropped player's boat (`.dropped`);
    /// otherwise a bot at the fleet's normal draw takes a seat given away before the gun (`.bot`, #16, #35). Either
    /// rebuilds her plan from the seat's view on her first decision (`BotDriver.takingOver()`). Sends nothing: the
    /// player's last held input holds until her first decision applies, on the tick after it.
    public mutating func takeOver(seat: Int, raceSeed: RaceSeed, cautious: Bool) {
        seats[seat] = cautious
            ? .dropped(.cautious(seat: seat, raceSeed: raceSeed))
            : .bot(BotDriver(seat: seat, raceSeed: raceSeed).takingOver())
    }

    /// Hands `seat` back to its player (#19, #104), between steps: no bot input is pending then (a bot's decision on a
    /// tick applies on the next, which `race.step()` has stepped), so the player's inputs apply from the next tick. The
    /// boat keeps everything the race holds for her: her penalty turn's progress, her autohelm's target. Sends nothing.
    public mutating func handBack(seat: Int) {
        seats[seat] = .human
    }

    public subscript(seat: Int) -> SeatController {
        get { seats[seat] }
        set { seats[seat] = newValue }
    }

    /// Lets every bot-sailed seat decide, if this is its decision tick, in seat order. The deciding seats'
    /// views are built together (`Race.seatViews(for:)`), sharing what they see alike: each is the view its
    /// seat alone would get, since a decision is sent for the next tick and changes nothing any view shows.
    public mutating func drive(_ race: Race) {
        guard !race.isOver else { return }
        let deciding = seats.indices.filter { seats[$0].driver?.decides(atTick: race.tick) ?? false }
        for (seat, view) in zip(deciding, race.seatViews(for: deciding)) {
            switch seats[seat] {
            case .human:
                continue
            case .bot(var driver):
                driver.drive(race, seeing: view)
                seats[seat] = .bot(driver)
            case .dropped(var driver):
                driver.drive(race, seeing: view)
                seats[seat] = .dropped(driver)
            }
        }
    }
}
