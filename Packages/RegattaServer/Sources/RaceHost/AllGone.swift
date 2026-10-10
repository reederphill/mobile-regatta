/// How a human seat stopped counting as there (G3, #66).
public enum GoneKind: Hashable, Sendable, CaseIterable {
    /// Its inputs stopped for longer than the input hold, and it hasn't rejoined.
    case dropped
    /// It left, before or after the gun.
    case left
}

/// When the host calls the race's humans all gone (G3, #66). Server config: the defaults are G3's.
public struct AllGoneConfig: Hashable, Sendable {
    /// Which ways of going count. A human seat gone some other way keeps the race going.
    public var goneKinds: Set<GoneKind> = [.dropped, .left]
    /// Ticks between the last human going and the trigger (G3: 30 s). A rejoin in between cancels it.
    public var graceTicks = 900
    /// At least 2 humans all dropping within this many ticks, and none leaving, is a mass drop (G3: 2 s).
    public var massDropWindowTicks = 60
    /// What a mass drop does when the host ends the race (G3: cancel).
    public var simultaneousLossPolicy = SimultaneousLossPolicy.cancel
    /// Whether the host ends the race itself when the trigger fires (#148): `Race.closeAllGone` at the trigger's tick,
    /// or, for a mass drop under `.cancel`, a cancel. Off (the default), `onAllGone` only hears it.
    public var endsRace = false

    public init() {}

    /// How the host ends the race for `allGone`, when it does.
    public func ending(_ allGone: AllGone) -> AllGoneEnding {
        allGone.isMassDrop && simultaneousLossPolicy == .cancel ? .cancel : .closeAllGone
    }
}

/// What a mass drop (G3: at least 2 humans, all dropped within 2 s, none left, nobody back in the grace) does.
/// Server config (`SIMULTANEOUS_LOSS_POLICY`).
public enum SimultaneousLossPolicy: String, Hashable, Sendable, CaseIterable {
    /// Treated as a server or network fault: the race is cancelled like a crash (#30): no results, no rating.
    case cancel
    /// Ended like any all-gone race: RET in leave order, rated per #30.
    case ret
}

/// How an all-gone race ends (#148).
public enum AllGoneEnding: Hashable, Sendable {
    /// `Race.closeAllGone`: bots placed by distance, the humans RET in reverse leave order (#30, G3).
    case closeAllGone
    /// Cancelled: no results.
    case cancel
}

/// The all-gone trigger (G3): every human seat gone, and the grace over. The host doesn't close the race
/// itself; its `onAllGone` hook does (#148): a normal close, or a cancel for a mass drop.
public struct AllGone: Hashable, Sendable {
    /// The tick the grace ran out: the last simulated tick when the hook fired.
    public var tick: Int
    /// The human seats in the order they went, first gone first (G3: the RET order).
    public var leaveOrder: [Int]
    /// At least 2 humans, all dropped within `massDropWindowTicks` of each other, none left (G3).
    public var isMassDrop: Bool

    public init(tick: Int, leaveOrder: [Int], isMassDrop: Bool) {
        self.tick = tick
        self.leaveOrder = leaveOrder
        self.isMassDrop = isMassDrop
    }
}

/// A human who left her race between fleet lock and the gun (#26, #147): what the queue's briefing-leave count hears.
/// Before the gun the host tells it each such seat once: at the leave for one who left for good, at the gun for one with
/// no connection then (a drop not back in time, the app backgrounded after lock, or never joined). A race cancelled before
/// the gun reports nobody it hadn't already.
public struct BriefingLeave: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// She left for good (`RaceHost.leave`): a fleet bot has the seat.
        case left
        /// Her seat had no connection at the gun: she can still rejoin after it (#66), but the leave counts.
        case absentAtGun
    }

    public let seat: Int
    public let kind: Kind

    public init(seat: Int, kind: Kind) {
        self.seat = seat
        self.kind = kind
    }
}
