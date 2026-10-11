import RegattaCore

/// A finish the cautious bot sailed for a player who was gone (#150, owner 2026-10-11): what the close makes of it.
///
/// A covered boat's finish is in the results as any finish (`Race.score`, the log and the digest know nothing of
/// this). The close reads, per human seat, whether her finish was sailed while she was gone, and for how long she
/// had been gone when the boat crossed the line:
///
/// - gone less than `graceTicks` (60 s by default, `COVERED_FINISH_GRACE_SECONDS`): rated at the place sailed;
/// - gone that long or longer: rated as having dropped, retired (`retiredPlace`), so she loses to everyone still
///   racing, as a player who left after the gun does (#151);
/// - either way it is no completed race towards earned designs, no win in her profile and no winner's line.
///
/// A finish she sailed herself, before dropping or after coming back, is hers in full. Everything here is read from
/// the stored log's seat events and the results row, in race ticks, so a stored race scores the same again. Pure.
public enum CoveredFinish {
    /// How long before the bot's finish a player may have dropped for it still to count for her rating: 60 s.
    public static let defaultGraceTicks = 60 * Race.tickRate

    /// The tick `seat`'s player went at (the host's recorded `.dropped`, or her `.left`) if she was gone when her boat
    /// finished at `finishTick`; nil if she was at her seat then. The tick of the first of her drop or leave since she
    /// last joined or rejoined: a dropped seat that then leaves went at the drop.
    ///
    /// A seat event is recorded after its tick's step. So a drop recorded at the finish tick itself came after a finish
    /// she sailed on her own inputs (hers), and a rejoin recorded at the finish tick came after a finish the bot sailed
    /// (not hers): only events before `finishTick` count.
    public static func goneSince(seat: Int, finishTick: Int, events: [SeatEvent]) -> Int? {
        var since: Int?
        for event in events where event.seat == seat && event.tick < finishTick {
            switch event.kind {
            case .joined, .rejoined: since = nil
            case .dropped, .left: since = since ?? event.tick
            case .leftBeforeGun, .disconnected, .botTookOver: break
            }
        }
        return since
    }

    /// What one seat's finish is to its player.
    public enum Standing: Equatable, Sendable {
        /// She sailed it (or the row is no finish at all): hers in full.
        case own
        /// The bot sailed it and she had been gone less than the grace: it counts for her rating only.
        case covered
        /// The bot sailed it and she had been gone the grace or longer: she is rated as retired.
        case coveredTooLate
    }

    public static func standing(of row: SeatResult, events: [SeatEvent], graceTicks: Int = defaultGraceTicks) -> Standing {
        guard row.code == .finished, let finishTick = row.finishTick,
              let gone = goneSince(seat: row.seat, finishTick: finishTick, events: events) else { return .own }
        return finishTick - gone < graceTicks ? .covered : .coveredTooLate
    }

    /// The human seats whose finish the bot sailed while the player was gone, by standing. Seats with `.own` are left out.
    public static func standings(results: RaceResults, log: RaceLog, graceTicks: Int = defaultGraceTicks) -> [Int: Standing] {
        var standings: [Int: Standing] = [:]
        for row in results.rows where log.header.setup.seats.indices.contains(row.seat) && log.header.setup.seats[row.seat] == .human {
            let standing = standing(of: row, events: log.seatEvents, graceTicks: graceTicks)
            if standing != .own { standings[row.seat] = standing }
        }
        return standings
    }

    /// The place `seat` is rated at when her covered finish doesn't count: a retirement's. Equal places are a draw
    /// (`RatingInput.Participant.place`), and only the order matters to the rating.
    ///
    /// - A normal close ties its RETs on one place, behind every other row: she shares it.
    /// - An all-gone close ranks its RETs by leave order, the later leaver ahead. She is given the place of the RET
    ///   who went next after her (a draw with her nearest neighbour, never ahead of anyone who stayed longer); if
    ///   nobody retired after her, the best RET's place.
    /// - No RET in the race: one place behind the last row.
    public static func retiredPlace(of seat: Int, results: RaceResults, log: RaceLog) -> Int {
        let retired = results.rows.filter { $0.code == .ret }
        guard let best = retired.map(\.place).min() else { return (results.rows.map(\.place).max() ?? 0) + 1 }
        if let order = log.allGoneClose?.leaveOrder, let mine = order.firstIndex(of: seat) {
            let later = Set(order[(mine + 1)...])
            if let next = retired.filter({ later.contains($0.seat) }).map(\.place).max() { return next }
        }
        return best
    }
}
