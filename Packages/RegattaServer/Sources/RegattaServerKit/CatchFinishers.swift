import Foundation

// Catching finishers (#16, #86, G2): while a race is about to close, the queue holds its fleet lock so the finishers can
// queue for the next one. The queued fleet locks `offset` after the running race's expected close, as long as the oldest
// queued player's wait stays within `maxHold`; otherwise the 1-minute rule. 16 humans still lock at once.

/// A race running on this server, and how far it is from its expected close (`Race.expectedCloseTick`).
public struct RunningRace: Sendable, Equatable {
    public let id: UUID
    public let ticksToClose: Int

    public init(id: UUID, ticksToClose: Int) {
        self.id = id
        self.ticksToClose = ticksToClose
    }
}

/// The races the queue can catch finishers from: the lifecycle's in production, a fake in tests.
public protocol RunningRaces: Sendable {
    func runningRaces() async -> [RunningRace]
}

/// G2's setting: `{ target: lock, offset: +15 s, maxHold: 180 s }`. Server config, with dev env overrides
/// (`CATCH_FINISHERS_OFFSET_SECONDS`, `CATCH_FINISHERS_MAX_HOLD_SECONDS`, `CATCH_FINISHERS=off`).
public struct CatchFinishers: Sendable, Equatable {
    /// What the hold moves: the fleet lock (the gun follows it by the briefing and the sequence).
    public enum Target: Sendable, Equatable { case lock }

    public var target = Target.lock
    /// From the running race's expected close to the queued fleet's lock.
    public var offset: TimeInterval = 15
    /// The longest the oldest queued player waits, from her join to the lock, for a hold.
    public var maxHold: TimeInterval = 180

    public init(offset: TimeInterval = 15, maxHold: TimeInterval = 180) {
        self.offset = offset
        self.maxHold = maxHold
    }

    /// A hold on the fleet lock for a running race.
    public struct Hold: Sendable, Equatable {
        /// The race whose finishers it waits for.
        public let race: UUID
        public let lockAt: Date

        public init(race: UUID, lockAt: Date) {
            self.race = race
            self.lockAt = lockAt
        }
    }

    /// The hold now, if any, given the oldest queued player's join, the 1-minute rule (`lockAfter`), each running race's
    /// expected close, and the hold so far (`current`). Pure: called again on every countdown step.
    ///
    /// - A hold only lengthens the wait: it locks at the race's close + `offset`, never before the 1-minute rule, and
    ///   never past the oldest's join + `maxHold` (the cap).
    /// - Without a hold, it catches the race closing first whose lock would be after the 1-minute rule and within the cap
    ///   (Q3: waiting longer costs the oldest player more); none, nil (the 1-minute rule).
    /// - A hold follows its race's close as it moves; a close that slips past the cap after the hold began locks at the
    ///   cap; a race that has closed (gone from `races`) keeps the hold's last lock time.
    public func hold(oldestJoinedAt joined: Date, lockAfter: TimeInterval, races: [(id: UUID, close: Date)], current: Hold?) -> Hold? {
        let minute = joined + lockAfter
        let cap = joined + maxHold
        if let current {
            guard let race = races.first(where: { $0.id == current.race }) else { return current }
            return Hold(race: race.id, lockAt: min(max(minute, race.close + offset), cap))
        }
        let catchable = races.filter { $0.close + offset > minute && $0.close + offset <= cap }
        guard let first = catchable.min(by: { ($0.close, $0.id.uuidString) < ($1.close, $1.id.uuidString) }) else { return nil }
        return Hold(race: first.id, lockAt: first.close + offset)
    }
}
