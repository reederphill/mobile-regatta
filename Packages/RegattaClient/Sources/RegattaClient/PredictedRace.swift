import RegattaCore
import RegattaProtocol

public enum PredictedRaceError: Error, Equatable, Sendable {
    /// A `Resync` for a race with another race seed than the `RaceStart`'s.
    case otherRace(RaceSeed)
}

/// The whole fleet, predicted ahead of the server to the client's tick (#18, ADR 0005).
///
/// It sails a keys-only `Race` (`Race(setup:revealedWindKeys:)`): no wind seed, only the keys the server
/// has revealed (ADR 0001). Each `Snapshot` puts the race back to the server's world at the snapshot's
/// tick, merged into the race's own world for what the wire leaves out, with the server's event state
/// (`Snapshot.applied(to:tick:events:)`); then the race is sailed forward again to where it was. Every
/// other boat, bots included, keeps the held input the snapshot gave her. The client's own boat gets
/// the inputs the client has sent that the server hadn't applied by the snapshot (`InputAck`), each at
/// its stamp, or the tick after the snapshot if the server will apply it late.
///
/// A tick whose wind needs a key the race doesn't hold is never sailed: the race stops before it and
/// `missingWindKey` names the key, for the client to fetch with a `Resync` (#64). It sails on as soon as
/// the key comes, by a `WindKey` event or the resync.
///
/// The race's own events are drained and dropped: online, rule calls, finishes and penalties are shown
/// only from the server's reliable events (#18, #68); #96 stops the prediction making them at all. The
/// app (#68) reads finishes, places and whether the race is over from `events`, the server's event
/// state, which a `Resync` can restore without replaying the events that built it; the events
/// `RaceClient.drainServerEvents()` hands out are for showing calls as they happen.
public final class PredictedRace {
    public let start: RaceStart
    /// The keys-only race, at the client's predicted tick (or before it, while a key is missing).
    public let race: Race
    /// The server's event state: from `RaceStart` (empty) or the last `Resync`, and the reliable events since.
    public private(set) var events: EventState
    /// The tick of the last server world imported, from a snapshot or a resync.
    public private(set) var serverTick: Int?
    /// The client's last input the server has applied, by input sequence number.
    public private(set) var ackedSeq: UInt32 = 0
    /// The key the next tick needs and the race doesn't hold, while it waits for it.
    public private(set) var missingWindKey: Int?
    /// Snapshots imported, and those skipped because a newer one was already in.
    public private(set) var snapshotsImported = 0
    public private(set) var staleSnapshots = 0

    /// Inputs sent and not yet known applied, in the order sent (so by tick).
    private var unacked: [StampedInput] = []
    /// How many of `unacked` the race has queued since it last imported.
    private var queued = 0
    private var highestSent: UInt32 = 0

    public var seat: Int { start.yourSeat }
    public var tick: Int { race.tick }

    public init(start: RaceStart) {
        self.start = start
        race = Race(setup: start.setup, revealedWindKeys: start.windKeys)
        events = EventState(nextEventSeq: 1)
        missingWindKey = missingKeyNow()
    }

    /// An input the client just sent. It applies at its tick as the race reaches it.
    public func sent(_ input: StampedInput) {
        unacked.append(input)
        highestSent = max(highestSent, input.seq)
    }

    /// A reliable event, in order; `seq` is its reliable-stream number.
    public func record(_ event: RaceEvent, seq: UInt32) {
        events.record(event)
        events.nextEventSeq = seq &+ 1
    }

    /// A revealed wind key, in order; `seq` is its reliable-stream number.
    public func reveal(_ key: WindKey, seq: UInt32) {
        race.addRevealedWindKey(key)
        events.nextEventSeq = seq &+ 1
        missingWindKey = missingKeyNow()
    }

    /// Imports the server's world at `tick` from `snapshot` and sails back to where the race was.
    /// Returns false for a snapshot no newer than the last one, which is skipped. Throws, leaving the
    /// race where it was, for one the race can't import (`WorldSnapshotError`): the caller resyncs.
    @discardableResult
    public func apply(_ snapshot: Snapshot, tick: Int) throws -> Bool {
        if let last = serverTick, tick <= last {
            staleSnapshots += 1
            return false
        }
        let resumeAt = race.tick
        let world = try snapshot.applied(to: race.exportSnapshot(), tick: tick, events: events)
        try race.importSnapshot(world)
        serverTick = tick
        snapshotsImported += 1
        if let ack = snapshot.ack { acknowledge(through: ack.seq, snapshotTick: tick) }
        repredict(to: resumeAt)
        return true
    }

    /// Rebuilds the race from a `Resync` at `tick`: the server's world, every key revealed so far and
    /// the event state (#18), then sails on to where the race was. The inputs stamped after `tick` are
    /// kept; the server has the ones before it, or has lost them. Throws `PredictedRaceError.otherRace`
    /// for a resync of another race, and what the import throws; either way the race is unchanged.
    public func apply(_ resync: Resync, tick: Int) throws {
        guard resync.raceSeed == start.setup.raceSeed else { throw PredictedRaceError.otherRace(resync.raceSeed) }
        let resumeAt = race.tick
        let world = try resync.world(base: race.exportSnapshot(), tick: tick)
        try race.importSnapshot(world)
        events = resync.eventState
        serverTick = tick
        unacked.removeAll { $0.tick <= tick }
        repredict(to: resumeAt)
    }

    /// Sails the race on to `tick`, stopping before any tick whose wind needs a key it doesn't hold.
    public func advance(to tick: Int) {
        while race.tick < tick && !race.isOver {
            let next = race.tick + 1
            // Queue the inputs due by `next`. If the step can't go, they stay queued in the race until it can.
            while queued < unacked.count && unacked[queued].tick <= next {
                let input = unacked[queued]
                switch input.kind {
                case .held(let held): race.apply(held, seat: seat, atTick: next)
                case .tap(let tap): race.tap(tap, seat: seat, atTick: next)
                }
                queued += 1
            }
            do {
                try race.tryStep()
            } catch {
                switch error {
                case .missingKey(let window):
                    missingWindKey = window
                    return
                case .beforeOrigin:
                    // Never: the window grid starts a whole window before the sequence, and the race
                    // never goes back past its start (`WindWindows(startSequenceTicks:)`, `importSnapshot`).
                    preconditionFailure("predicted race at tick \(race.tick) is before its wind's origin")
                }
            }
            _ = race.drainEvents()
        }
        missingWindKey = missingKeyNow()
    }

    /// The key the wind at the race's own tick needs and the race doesn't hold, if any: only before the
    /// race has stepped or imported, when `RaceStart` held too few keys to draw it.
    private func missingKeyNow() -> Int? {
        do {
            for boat in race.boats { _ = try race.wind.sample(boat.position, tick: race.tick) }
            return nil
        } catch {
            if case .missingKey(let window) = error { return window }
            return nil
        }
    }

    /// Drops the inputs up to `seq` stamped at or before `snapshotTick`: the server applied them, or a
    /// later one, by the snapshot (the `InputAck` contract). One stamped after the snapshot stays, to be
    /// applied at its stamp, even if the host acknowledged it early. An ack past anything sent can't be
    /// right, so it counts only up to the last input sent.
    private func acknowledge(through seq: UInt32, snapshotTick: Int) {
        ackedSeq = max(ackedSeq, min(seq, highestSent))
        unacked.removeAll { $0.seq <= ackedSeq && $0.tick <= snapshotTick }
    }

    /// After an import: queue the unapplied inputs again and sail to `tick`.
    private func repredict(to tick: Int) {
        queued = 0
        advance(to: tick)
    }
}
