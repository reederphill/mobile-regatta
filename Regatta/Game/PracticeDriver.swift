import Foundation
import RegattaBots
import RegattaCore

/// Sails an offline practice race on the device (#16): owns the `Race` and its seat controllers, so
/// the bots decide on the device (#19), and keeps the race log (ADR 0002). Pausable.
///
/// Each tick: your latched input and queued taps go in for the next tick, the bots decide, the race
/// steps, and the frame is kept. Everything reaches the race through its input API, so `log` replays
/// with `Replayer` to the same state without running a bot.
final class PracticeDriver: RaceDriver {
    let myBoatIndex: Int
    let course: CourseLayout
    let venue: Venue
    let boatClass: BoatClass
    let isPausable = true
    /// Names and bot marks, kept outside the simulation (#60).
    let roster: FleetRoster
    /// Each seat's livery (#119): yours, and a seeded free starter per bot.
    let liveries: FleetLiveries
    /// The bytes of the tuned copies the race sails (#232), by ref: saved beside its log so it replays.
    let tunedFiles: [FileRef: Data]

    private(set) var previousFrame: TickFrame
    private(set) var currentFrame: TickFrame
    /// Once the race is over the clock stops, and the world is drawn at its last tick.
    var alpha: Double { race.isOver ? 1 : clock.alpha }

    private let race: Race
    /// Who sails each seat. Bots send their inputs through the race's input API before each tick (#60).
    private var seats: SeatControllers
    private var clock: TickClock
    /// The latest input you sent, applied at the next tick if it changed.
    private var latchedInput = BoatInput.neutral
    private var appliedInput = BoatInput.neutral
    private var queuedTaps: [BoatTap] = []
    private var events: [RaceEvent] = []

    /// A practice race from the app's settings, with you in the setup's human seat, sailed on the config's
    /// files: the bundled defaults (`RaceFiles.defaults`), or the tuning panel's, whose tuned copies resolve from
    /// the config's catalog (#232). `timescale` runs it that many times real time (`-timescale`).
    /// Your boat wears `livery` (#136).
    init(config: RaceConfig, timescale: Double = 1, livery: Livery = FleetLiveries.yours) {
        let setup = config.setup
        do {
            race = try Race(setup: setup, files: RaceFiles(resolving: setup, from: config.files.catalog),
                            mode: .authoritative(windSeed: WindSeed(config.windSeed)))
        } catch {
            preconditionFailure("a practice setup names files it can resolve: \(error)")
        }
        tunedFiles = config.files.tunedFiles
        seats = config.seatControllers
        roster = config.roster
        myBoatIndex = setup.seats.firstIndex(of: .human) ?? 0
        liveries = FleetLiveries(setup: setup, mySeat: myBoatIndex, mine: livery)
        course = race.course
        venue = race.files.venue.content
        boatClass = race.boatClass
        clock = TickClock(timescale: timescale)
        currentFrame = TickFrame(race: race, keepClearOf: myBoatIndex)
        previousFrame = currentFrame
    }

    /// Prototype (proto-tiller): your autohelm on or off (the tuning panel's Auto tiller), live.
    var autoTiller: Bool {
        get { race.humanAutohelm }
        set { race.humanAutohelm = newValue }
    }

    /// Whether you sail your own seat: false while a bot does (`-demo`).
    var youSailYourBoat: Bool { seats[myBoatIndex].isHuman }

    /// The race as stored: its keys and every input as applied (ADR 0002).
    var log: RaceLog {
        guard let log = race.log else { preconditionFailure("practice race has no log: Race.log is nil, so it was built keys-only") }
        return log
    }

    /// The race's incident index (#94): the results' Your race card (#132).
    var incidents: IncidentIndex? { race.incidents }

    /// The race's state digest, to compare with a replay of `log`.
    func digest() -> UInt64 { race.digest() }

    @discardableResult
    func tick(_ dt: Double) -> [TickFrame] { tick(dt, within: nil) }

    @discardableResult
    func tick(_ dt: Double, within budget: Duration?) -> [TickFrame] {
        // A finished race stands still: no ticks, and `alpha` holds at the last one.
        guard !race.isOver else { return [] }
        let due = clock.advance(by: dt)
        let deadline = budget.map { ContinuousClock.now + $0 }
        var frames: [TickFrame] = []
        for _ in 0..<due {
            frames.append(step())
            if race.isOver { break }
            // Past the budget the rest of `due` is dropped: at least one tick runs, so the race advances.
            if let deadline, ContinuousClock.now >= deadline { break }
        }
        return frames
    }

    func submit(_ input: BoatInput) {
        guard youSailYourBoat else { return }
        latchedInput = input
    }

    @discardableResult
    func tap(_ tap: BoatTap) -> Bool {
        guard youSailYourBoat, !race.isOver else { return false }
        queuedTaps.append(tap)
        return true
    }

    func drainEvents() -> [RaceEvent] {
        defer { events.removeAll() }
        return events
    }

    /// One fixed tick.
    private func step() -> TickFrame {
        let next = race.tick + 1
        if youSailYourBoat {
            if latchedInput != appliedInput, race.apply(latchedInput, seat: myBoatIndex, atTick: next) != nil {
                appliedInput = latchedInput
            }
            for tap in queuedTaps { race.tap(tap, seat: myBoatIndex, atTick: next) }
        }
        queuedTaps.removeAll()
        Signpost.botBrains.measure { seats.drive(race) }
        Signpost.simStep.measure { race.step() }
        events += race.drainEvents()
        previousFrame = currentFrame
        currentFrame = TickFrame(race: race, keepClearOf: myBoatIndex)
        return currentFrame
    }
}
