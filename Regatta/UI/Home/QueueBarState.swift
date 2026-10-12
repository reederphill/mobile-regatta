import Foundation

/// What the queue bar and the chip show (#140, #16, #25), from the Race online tap to fleet lock. A pure value: the
/// controller sets it, and a view reads its words for the moment it draws (`display(at:)`), so the seconds count down
/// on the device between the server's pushes.
nonisolated enum QueueBarState: Equatable {
    /// The tap is in: `join` is on its way.
    case joining
    /// Queued, `players` waiting (her included), the fleet locking at `lockAt`.
    case waiting(players: Int, lockAt: Date)
    /// The fleet has locked and her seat is being fetched.
    case locking
    /// The connection went while she was queued or joining: her place is gone.
    case connectionLost

    /// A wait longer than this is a hold (#16, G2): the lock waits for a running race's finishers, and no seconds show.
    static let countdownSeconds = 60
    /// The lock banner and its haptic come this close to the lock (#25).
    static let lockSoonSeconds = 10

    /// How the bar reads at a moment.
    enum Kind: Equatable {
        case joining, others, alone, hold, lockSoon, locking, connectionLost
    }

    /// The bar's words at a moment.
    struct Display: Equatable {
        var kind: Kind
        var title: String
        /// "3 waiting", "Just you" or "Waiting for finishers".
        var detail: String?
        /// "42 s"; none in a hold, or once the fleet is being set.
        var seconds: String?
        /// The chip's few characters: the count, then the seconds.
        var chip: String
        /// VoiceOver's one label for the bar.
        var spoken: String

        /// The yellow-edged lock banner.
        var isBanner: Bool { kind == .lockSoon }
        /// Leave shows while there is a place to give up.
        var canLeave: Bool { kind == .others || kind == .alone || kind == .hold || kind == .lockSoon }
    }

    /// Whole seconds to the lock at `now`, rounded up; nil when not waiting.
    func secondsToLock(at now: Date) -> Int? {
        guard case .waiting(_, let lockAt) = self else { return nil }
        return Int(lockAt.timeIntervalSince(now).rounded(.up))
    }

    func kind(at now: Date) -> Kind {
        switch self {
        case .joining: return .joining
        case .locking: return .locking
        case .connectionLost: return .connectionLost
        case .waiting(let players, _):
            let seconds = secondsToLock(at: now) ?? 0
            if seconds <= 0 { return .locking }
            if seconds <= Self.lockSoonSeconds { return .lockSoon }
            if seconds > Self.countdownSeconds { return .hold }
            return players <= 1 ? .alone : .others
        }
    }

    // TODO-COPY (#171): every phrase here is placeholder wording.
    func display(at now: Date) -> Display {
        let kind = kind(at: now)
        var players = 1
        if case .waiting(let count, _) = self { players = max(1, count) }
        let seconds = secondsToLock(at: now) ?? 0
        let count = players == 1 ? "Just you" : "\(players) waiting"
        switch kind {
        case .joining:
            return Display(kind: kind, title: "Joining", chip: "Joining", spoken: "Joining the queue")
        case .others, .alone:
            return Display(kind: kind, title: "In the queue", detail: count, seconds: "\(seconds) s", chip: "\(players) · \(seconds) s",
                           spoken: "Queued, \(count.lowercased()), \(seconds) seconds")
        case .hold:
            return Display(kind: kind, title: "In the queue", detail: "Waiting for finishers", chip: "\(players) · waiting",
                           spoken: "Queued, waiting for finishers")
        case .lockSoon:
            return Display(kind: kind, title: "Race in \(seconds)", detail: count, chip: "Race in \(seconds)",
                           spoken: "Race in \(seconds) seconds, \(count.lowercased())")
        case .locking:
            return Display(kind: kind, title: "Setting the fleet", chip: "Setting the fleet", spoken: "Setting the fleet")
        case .connectionLost:
            return Display(kind: kind, title: "Connection lost", chip: "Connection lost", spoken: "Connection lost")
        }
    }
}

/// Home's Race online slot beside the gate's and the server's lines (#138, #161), as the queue leaves it (#140).
nonisolated enum RaceOnlineEntry: Equatable {
    /// The button, as the gate and the restriction line have it.
    case ready
    /// Joining or queued: the bar stands in for the button.
    case queued
    /// Just out of a locked fleet: off, with no words, until the server says where she stands (3 s at most).
    case settling
}
