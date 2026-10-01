/// How a seat is scored when the race closes (#86; #24, #30, G6). The raw values are G6's names.
public enum ResultCode: String, Sendable, Hashable, CaseIterable {
    /// Crossed the finish line: placed by her finish, shown as a gap to the winner (#24, "+0:42").
    case finished
    /// Still racing at the close: placed behind every finisher by her ladder distance still to go round her
    /// remaining marks (#8, #267, `Race.ladderDistanceToFinish(of:)`).
    case byDistance
    /// Disqualified, behind every boat placed by ladder distance (#30). Fixed at the call (#24).
    case dsq = "DSQ"
    /// Over the line at the gun and never came back, or never started: behind DSQ and ahead of RET (#30).
    case ocs = "OCS"
    /// Retired: her player was gone when the race closed (#16, G3), and she hadn't finished or been
    /// disqualified. The only code that means the player left (G6).
    case ret = "RET"
}

/// One seat's result.
public struct SeatResult: Sendable, Hashable {
    public var seat: Int
    /// From 1. Seats scored alike share a place, and the next place skips past them ("1, 2, 3, 3, 5"):
    /// every DSQ shares one, every OCS one, and every RET one at a normal close (`RaceResults`).
    public var place: Int
    public var code: ResultCode
    /// The tick she crossed the finish line, for `finished` only.
    public var finishTick: Int?

    public init(seat: Int, place: Int, code: ResultCode, finishTick: Int? = nil) {
        self.seat = seat
        self.place = place
        self.code = code
        self.finishTick = finishTick
    }
}

/// The race's results, fixed as it closes (`Race.results`, the `raceClosed` event).
///
/// Every seat has exactly one row, in display order: finishers by finish, then boats placed by ladder
/// distance, then DSQ, OCS and RET (#30). DSQs, OCSs and, at a normal close, RETs are tied among themselves
/// and shown in seat order (display only). At an all-gone close (`Race.closeAllGone`) the RETs are placed
/// one by one in reverse leave order: the player who left latest ranks highest (#30, G3).
public struct RaceResults: Sendable, Hashable {
    /// In display order.
    public var rows: [SeatResult]
    /// Whether the race counts for ratings: at least 2 humans were at the gun (#30).
    public var rated: Bool

    public init(rows: [SeatResult], rated: Bool) {
        self.rows = rows
        self.rated = rated
    }

    /// No rows, unrated: for a close whose results come from elsewhere.
    public static let empty = RaceResults(rows: [], rated: false)

    /// `seat`'s row, or nil if it has none.
    public func row(of seat: Int) -> SeatResult? { rows.first { $0.seat == seat } }

    /// The seats in display order.
    public var order: [Int] { rows.map(\.seat) }

    /// The winner's finish tick, or nil if nobody finished.
    public var winningTick: Int? { rows.first { $0.code == .finished }?.finishTick }

    /// Ticks from the winner's finish to `seat`'s (#24: the "+0:42" gap), 0 for the winner; nil for a seat
    /// that didn't finish.
    public func gapTicks(of seat: Int) -> Int? {
        guard let row = row(of: seat), row.code == .finished, let tick = row.finishTick, let winner = winningTick else {
            return nil
        }
        return tick - winner
    }
}
