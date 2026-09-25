import RaceHost
import RegattaBots
import RegattaCore
import RegattaProtocol

/// One race stepped as `RaceHost` steps it each tick (#65), without the actor, clock or seat plumbing:
/// the bots decide (#19, 10 Hz), the race steps, its events are encoded, and every `snapshotEvery` ticks
/// the fleet snapshot is built and encoded once per seat, as for a race where every seat is attached.
/// The encoded bytes go to a sink that only counts them.
final class BenchRace {
    let race: Race
    private var controllers: SeatControllers
    private let snapshotEvery = RaceHostOptions().snapshotEvery
    private var seq: [UInt32]
    /// Bytes encoded so far. Reported, so the encoding is never optimised away.
    private(set) var bytesSent = 0

    init(_ scenario: Scenario, index: Int) throws {
        race = try scenario.race(index: index)
        controllers = SeatControllers(setup: race.setup)
        seq = Array(repeating: 0, count: race.boats.count)
    }

    var isOver: Bool { race.isOver }

    func step() {
        controllers.drive(race)
        race.step()
        for event in race.drainEvents() {
            for seat in seq.indices { send(Frame(seq: seq[seat], event: event), to: seat) }
        }
        if race.tick % snapshotEvery == 0, let fleet = try? Snapshot(world: race.exportSnapshot()) {
            for seat in seq.indices { send(Frame(seq: seq[seat], tick: race.tick, message: .snapshot(fleet)), to: seat) }
        }
    }

    private func send(_ frame: Frame, to seat: Int) {
        guard let bytes = try? frame.encoded() else { return }
        seq[seat] &+= 1
        bytesSent &+= bytes.count
    }
}
