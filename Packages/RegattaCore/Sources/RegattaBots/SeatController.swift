import RegattaCore

/// Who is sailing a seat right now (#60). Swappable at any tick: a bot takes over a seat given
/// away before the gun, or a dropped player's boat, and hands it back when they rejoin (#19).
/// The race never knows: every controller reaches it through the same input API.
public enum SeatController: Sendable {
    /// A player sends the inputs (a device, or the server's input queue); nothing to drive here.
    case human
    /// A bot fills the seat.
    case bot(BotDriver)
    /// A bot sails a dropped player's boat until they rejoin (#19; the cautious mode comes with #104).
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

    public subscript(seat: Int) -> SeatController {
        get { seats[seat] }
        set { seats[seat] = newValue }
    }

    /// Lets every bot-sailed seat decide, if this is its decision tick.
    public mutating func drive(_ race: Race) {
        for seat in seats.indices {
            switch seats[seat] {
            case .human:
                continue
            case .bot(var driver):
                driver.drive(race)
                seats[seat] = .bot(driver)
            case .dropped(var driver):
                driver.drive(race)
                seats[seat] = .dropped(driver)
            }
        }
    }
}
