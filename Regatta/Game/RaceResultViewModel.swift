import Foundation
import RegattaCore

/// One race's results as the results sheet shows them (#24, #30, #132): a row per boat in display order, and the
/// "Your race" card. Built from the core's `RaceResults` once the race has closed, and from the live frame before
/// that, while boats still sail behind the sheet. A value: the home screen's Last race keeps the last one
/// (`LastRaceStore`), so it is `Codable`.
struct RaceResultViewModel: Equatable, Codable {
    /// One boat's row.
    struct Row: Equatable, Codable, Identifiable {
        var seat: Int
        /// The place column: a number, shared by boats scored alike once the race has closed (`SeatResult.place`).
        var place: Int
        /// "You", a bot's sailing name, or another helm's name. Its alias once online racing names players (#133).
        var name: String
        var isBot: Bool
        var isPlayer: Bool
        var livery: Livery
        var result: Result
        /// ⚑: the rules called at least one foul against this boat (#24).
        var flagged: Bool

        var id: Int { seat }
    }

    /// The result column (#24, #30).
    enum Result: Equatable, Codable {
        /// The winner: her race time from the gun.
        case raceTime(ticks: Int)
        /// A finisher behind the winner: the gap to the winner's finish ("+0:42").
        case gap(ticks: Int)
        /// Placed by her ladder distance still to go when the race closed.
        case byDistance
        case dsq
        case ocs
        case ret
        /// Still racing: the race hasn't closed. Fills in live as she finishes (#24).
        case sailing
        /// After the gun, not yet started (OCS or late), before the close.
        case notStarted

        // TODO-COPY (#171)
        var text: String {
            switch self {
            case .raceTime(let ticks): formatClock(Double(ticks) / Double(Race.tickRate))
            case .gap(let ticks): RaceResultViewModel.gapText(ticks: ticks)
            case .byDistance: "By distance"
            case .dsq: "DSQ"
            case .ocs: "OCS"
            case .ret: "RET"
            case .sailing: "Sailing"
            case .notStarted: "Not started"
            }
        }
    }

    /// What the sheet knows of each seat, by seat: kept outside the simulation (#60, #119).
    struct Entrant: Equatable {
        var name: String
        var isBot: Bool
        var livery: Livery
    }

    /// One boat as the live frame stands, before the close, in `TickFrame.standings` order.
    struct LiveStanding: Equatable {
        var seat: Int
        var status: BoatStatus
        /// Her finish place, once she has finished.
        var place: Int?
        /// The tick she finished on, once she has.
        var finishTick: Int?
    }

    var rows: [Row]
    /// The "Your race" card: nil when nothing involved you, or where the race has no incident index on the device
    /// (online, a render fixture).
    var card: YourRaceCard?
    /// The rows are final: the race closed, or you left it (`leftBeforeClose`). False while boats still sail.
    var isFinal: Bool
    var mySeat: Int

    /// Your row.
    var myRow: Row? { rows.first { $0.isPlayer } }

    /// Home's Last race keeps these results (#132): not a race you retired from, which is no result of yours.
    var keepsAsLastRace: Bool { myRow.map { $0.result != .ret } ?? false }

    /// The home screen's Last race summary: "3 of 8", or your code.
    // TODO-COPY (#171)
    var summary: String {
        guard let row = myRow else { return "" }
        switch row.result {
        case .dsq, .ocs, .ret: return row.result.text
        default: return "\(row.place) of \(rows.count)"
        }
    }

    /// The results: `results` once the race has closed (a close with no rows, online's today, reads as not closed),
    /// else `live`. `served` is how many penalty turns each seat completed (`penaltyServed` events), for the card's
    /// outcomes; `incidents` nil leaves the card out.
    init(results: RaceResults?, live: [LiveStanding], entrants: [Entrant], mySeat: Int, incidents: IncidentIndex?,
         served: [Int: Int] = [:]) {
        self.mySeat = mySeat
        let flagged = Self.flaggedSeats(incidents)
        func row(_ seat: Int, place: Int, result: Result) -> Row {
            let entrant = entrants[seat]
            return Row(seat: seat, place: place, name: entrant.name, isBot: entrant.isBot, isPlayer: seat == mySeat,
                       livery: entrant.livery, result: result, flagged: flagged.contains(seat))
        }
        let codes: [Int: ResultCode]
        if let results, !results.rows.isEmpty {
            isFinal = true
            // The core's rows are already in display order (#30, #86).
            let winner = results.winningTick
            rows = results.rows.map { seat in
                let result: Result
                switch seat.code {
                case .finished:
                    let tick = seat.finishTick ?? 0
                    let gap = winner.map { tick - $0 } ?? 0
                    result = gap == 0 ? .raceTime(ticks: tick) : .gap(ticks: gap)
                case .byDistance: result = .byDistance
                case .dsq: result = .dsq
                case .ocs: result = .ocs
                case .ret: result = .ret
                }
                return row(seat.seat, place: seat.place, result: result)
            }
            codes = Dictionary(results.rows.map { ($0.seat, $0.code) }, uniquingKeysWith: { a, _ in a })
        } else {
            isFinal = false
            let winner = live.compactMap { $0.status == .finished ? $0.finishTick : nil }.min()
            rows = live.enumerated().map { rank, standing in
                let result: Result
                switch standing.status {
                case .finished:
                    let tick = standing.finishTick ?? 0
                    let gap = winner.map { tick - $0 } ?? 0
                    result = gap == 0 ? .raceTime(ticks: tick) : .gap(ticks: gap)
                case .racing: result = .sailing
                case .dsq: result = .dsq
                case .prestart, .ocs: result = .notStarted
                }
                return row(standing.seat, place: standing.place ?? rank + 1, result: result)
            }
            codes = Dictionary(live.compactMap { $0.status == .dsq ? ($0.seat, ResultCode.dsq) : nil },
                               uniquingKeysWith: { a, _ in a })
        }
        let isFinal = isFinal
        card = incidents.map { index in
            YourRaceCard(incidents: index, mySeat: mySeat, label: { seat in
                let entrant = entrants[seat]
                return entrant.isBot && seat != mySeat ? "\(BotGlyph.text) \(entrant.name)" : entrant.name
            }, served: served, codes: codes, isFinal: isFinal)
        }.flatMap { $0.isEmpty ? nil : $0 }
    }

    init(rows: [Row], card: YourRaceCard?, isFinal: Bool, mySeat: Int) {
        self.rows = rows
        self.card = card
        self.isFinal = isFinal
        self.mySeat = mySeat
    }

    /// This model as kept on leaving the race before it closed (ruling 4, #132): every boat still sailing or not yet
    /// started is placed by distance in her standing order, and turns still owed read as not done. Final from here on.
    func leftBeforeClose() -> RaceResultViewModel {
        guard !isFinal else { return self }
        var snapshot = self
        snapshot.rows = rows.map { row in
            var row = row
            if row.result == .sailing || row.result == .notStarted { row.result = .byDistance }
            return row
        }
        snapshot.card = card.map { card in
            var card = card
            func close(_ calls: [YourRaceCard.Call]) -> [YourRaceCard.Call] {
                calls.map { call in
                    var call = call
                    if call.outcome == .owed { call.outcome = .notDone }
                    return call
                }
            }
            card.against = close(card.against)
            card.inFavour = close(card.inFavour)
            return card
        }
        snapshot.isFinal = true
        return snapshot
    }

    /// Every seat with a foul called against her (#24's ⚑). Rule 31 mark touches aren't calls (ruling 5, #132).
    private static func flaggedSeats(_ incidents: IncidentIndex?) -> Set<Int> {
        guard let incidents else { return [] }
        return Set(incidents.incidents.compactMap { incident in
            if case .called(let call) = incident.outcome { call.offender } else { nil }
        })
    }

    /// A finisher's gap to the winner, "+m:ss" in whole seconds, rounded up: a boat a tick behind reads "+0:01",
    /// never "+0:00" (#24).
    static func gapText(ticks: Int) -> String {
        let seconds = (max(ticks, 0) + Race.tickRate - 1) / Race.tickRate
        return String(format: "+%d:%02d", seconds / 60, seconds % 60)
    }
}

/// The "Your race" card under the results (#24): only incidents involving you, one short phrase each (the owner's
/// sparse off-water screens, 2026-10-02): calls against you with their outcome, calls in your favour, your mark
/// touches (listed against you, ruling 5, #132), and your protests, which never change a result (CONTEXT.md
/// **Protest**).
struct YourRaceCard: Equatable, Codable {
    struct Call: Equatable, Codable {
        var tick: Int
        /// "10", "31".
        var rule: String
        /// The other boat's label, nil for a mark touch.
        var other: String?
        /// The mark touched, for a rule 31 entry.
        var mark: String?
        /// A call against the other boat, in your favour.
        var inFavour: Bool
        var outcome: Outcome

        // TODO-COPY (#171)
        var phrase: String {
            if inFavour { return "\(other ?? "A boat") fouled you (rule \(rule))" }
            if let mark { return "Touched the \(mark), \(outcome.text)" }
            return "Rule \(rule) against you, \(outcome.text)"
        }
    }

    /// What became of the penalty the call owed (#24: "penalty done, or DSQ").
    enum Outcome: String, Equatable, Codable {
        case penaltyDone
        case dsq
        /// The race closed (or you left it) with the turn not done and the boat not disqualified.
        case notDone
        /// The turn is still owed: the race is still running.
        case owed
        /// The call added no turn: a mark touch in the same incident already owed it (44.1(a), #90).
        case noTurn

        // TODO-COPY (#171)
        var text: String {
            switch self {
            case .penaltyDone: "penalty done"
            case .dsq: "DSQ"
            case .notDone: "penalty not done"
            case .owed: "penalty owed"
            case .noTurn: "no penalty"
            }
        }
    }

    struct ProtestEntry: Equatable, Codable {
        var tick: Int
        var protested: String

        // TODO-COPY (#171)
        var phrase: String { "You protested \(protested)" }
    }

    /// Calls against you and your mark touches, oldest first.
    var against: [Call]
    /// Calls against another boat in your favour, oldest first.
    var inFavour: [Call]
    /// Your protests, oldest first.
    var protests: [ProtestEntry]

    var isEmpty: Bool { against.isEmpty && inFavour.isEmpty && protests.isEmpty }

    init(against: [Call], inFavour: [Call], protests: [ProtestEntry]) {
        self.against = against
        self.inFavour = inFavour
        self.protests = protests
    }

    /// The card from the race's incident index. The index holds no served or DSQ fact, so each penalty's outcome is
    /// worked out here (ruling 2, #132): the offender's penalties in tick order (map G4: stacked turns are served one
    /// after another), the first `served[offender]` turns done, the rest DSQ when her code is, else not done once the
    /// race is final, or owed while it runs.
    init(incidents: IncidentIndex, mySeat: Int, label: (Int) -> String, served: [Int: Int], codes: [Int: ResultCode],
         isFinal: Bool) {
        let calls = incidents.incidents.compactMap { incident -> RuleCall? in
            if case .called(let call) = incident.outcome { call } else { nil }
        }
        let touches = Array(incidents.markTouches.enumerated())
        enum Key: Hashable { case call(Int), touch(Int) }
        var outcomes: [Key: Outcome] = [:]
        let offenders = Set(calls.map(\.offender)).union(touches.map(\.element.seat))
        for seat in offenders {
            // Every penalty she owes, oldest first: a call's turns, or a mark touch's one.
            var penalties = calls.filter { $0.offender == seat }.map { (tick: $0.tick, turns: $0.turnsOwed, key: Key.call($0.incidentId)) }
            penalties += touches.filter { $0.element.seat == seat }.map { (tick: $0.element.tick, turns: 1, key: Key.touch($0.offset)) }
            penalties.sort { $0.tick < $1.tick }
            var done = served[seat] ?? 0
            for penalty in penalties {
                if penalty.turns == 0 {
                    outcomes[penalty.key] = .noTurn
                } else if done >= penalty.turns {
                    done -= penalty.turns
                    outcomes[penalty.key] = .penaltyDone
                } else {
                    done = 0
                    outcomes[penalty.key] = codes[seat] == .dsq ? .dsq : isFinal ? .notDone : .owed
                }
            }
        }
        func entry(_ call: RuleCall, other: Int, inFavour: Bool) -> Call {
            Call(tick: call.tick, rule: call.rule.rawValue, other: label(other), mark: nil, inFavour: inFavour,
                 outcome: outcomes[.call(call.incidentId)] ?? .noTurn)
        }
        var against = calls.filter { $0.offender == mySeat }.map { entry($0, other: $0.victim, inFavour: false) }
        against += touches.filter { $0.element.seat == mySeat }.map { index, touch in
            Call(tick: touch.tick, rule: RacingRule.touchingMark.rawValue, other: nil, mark: touch.mark, inFavour: false,
                 outcome: outcomes[.touch(index)] ?? .owed)
        }
        self.against = against.sorted { $0.tick < $1.tick }
        inFavour = calls.filter { $0.victim == mySeat && $0.offender != mySeat }.map {
            entry($0, other: $0.offender, inFavour: true)
        }
        protests = incidents.protests(by: mySeat).map { ProtestEntry(tick: $0.tick, protested: label($0.protested)) }
    }
}
