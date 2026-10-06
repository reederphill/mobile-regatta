import Foundation
import RegattaCore
import RegattaServices

// The online results (#133, #24): rows from the server's results stream, your rating cell, the earned-design line, and
// who can be reported. The server decides every row and call (ADR 0005); nothing here predicts.

extension RaceResultViewModel {
    /// What only an online race's results have. Decoded if present (`LastRaceStore`), so a Last race kept before it
    /// still loads.
    struct Online: Equatable, Codable {
        /// The server's race, for a report (`LobbyService.report(race:seat:reason:)`).
        var raceID: String
        /// Your row's caption.
        var rating: RatingCell
        /// The design this race unlocked, if any, and drawn.
        var earned: EarnedLine?
    }

    /// The rating caption under your row (#24): pending until the server pushes the change, then "+12 → 1532" with
    /// the provisional tag, or why the race was unrated. No graph, no forecast.
    enum RatingCell: Equatable, Codable {
        case pending
        case rated(change: Int, after: Int, isProvisional: Bool)
        case unrated(UnratedReason)

        init(_ outcome: RatingOutcome) {
            switch outcome {
            case .rated(let before, let after):
                self = .rated(change: after.value - before.value, after: after.value, isProvisional: after.isProvisional)
            case .unrated:
                self = .unrated(.noOtherHumans)
            }
        }

        // TODO-COPY (#171)
        var text: String {
            switch self {
            case .pending: "Rating pending"
            case .rated(let change, let after, _): "\(Self.signed(change)) → \(after)"
            case .unrated(let reason): reason.text
            }
        }

        /// The provisional tag beside a rated change.
        var isProvisional: Bool {
            if case .rated(_, _, let provisional) = self { provisional } else { false }
        }

        /// "+12", "+0", "−7" (a true minus).
        static func signed(_ change: Int) -> String { change < 0 ? "\u{2212}\(-change)" : "+\(change)" }
    }

    /// Why a race moved no rating (#24, CONTEXT **Rated race**).
    enum UnratedReason: String, Equatable, Codable {
        /// A practice race. Defined for the words; the practice sheet doesn't draw it (its buttons already say
        /// practice, and its references stay put).
        case practice
        /// Fewer than two humans at the gun.
        case noOtherHumans

        // TODO-COPY (#171)
        var text: String {
            switch self {
            case .practice: "Practice, unrated"
            case .noOtherHumans: "No other humans at the gun, unrated"
            }
        }
    }

    /// One line when this race unlocked an earned design (#24): a small render in your colours and Try it, which
    /// opens My boat with it on. Never a paid design.
    struct EarnedLine: Equatable, Codable {
        var design: DesignID
        /// Its name as My boat shows it.
        var name: String
        /// The design in your colours and number, for the small render.
        var livery: Livery

        // TODO-COPY (#171)
        var text: String { "New design: \(name)" }
    }

    /// The online results from the stream's latest report (#133): the scored rows in the server's order, then the
    /// boats still sailing, with no place yet (`Row.place` 0, drawn blank: the stream's sailing seats are unordered).
    /// Names, bot flags and liveries from `entrants` (the race transport's roster); rows, ⚑ and the Your race card
    /// from the report, so a rejoin or a missed event still shows every call. Final once the race has closed.
    init(report: RaceReport, entrants: [Entrant], rating: RatingCell, earned: EarnedLine?) {
        let mySeat = report.seat
        let mine = report.incidents.first { $0.seat == mySeat }
        let myCalls = YourRaceCard.calls(in: mine?.incidents ?? [])
        let flagged = Set(report.flaggedSeats).union(myCalls.map(\.offender))
        func entrant(_ seat: Int) -> Entrant {
            if entrants.indices.contains(seat) { return entrants[seat] }
            let name = report.roster.indices.contains(seat) ? report.roster[seat].name : ""
            return Entrant(name: name, isBot: false, livery: FleetLiveries.yours)
        }
        func row(_ seat: Int, place: Int, result: Result) -> Row {
            let entrant = entrant(seat)
            return Row(seat: seat, place: place, name: entrant.name, isBot: entrant.isBot, isPlayer: seat == mySeat,
                       livery: entrant.livery, result: result, flagged: flagged.contains(seat))
        }
        let winner = report.results.winningTick
        var rows = report.results.rows.map { seat in
            row(seat.seat, place: seat.place, result: Self.result(of: seat, winner: winner))
        }
        if !report.isClosed {
            rows += report.sailing.map { row($0, place: 0, result: .sailing) }
        }
        let codes = Dictionary(report.results.rows.map { ($0.seat, $0.code) }, uniquingKeysWith: { a, _ in a })
        let card = YourRaceCard(
            calls: myCalls, touches: mine?.markTouches ?? [], protests: mine?.protests ?? [], mySeat: mySeat,
            label: { seat in
                let entrant = entrant(seat)
                return entrant.isBot && seat != mySeat ? "\(BotGlyph.text) \(entrant.name)" : entrant.name
            },
            served: [mySeat: mine?.turnsServed ?? 0], codes: codes, isFinal: report.isClosed)
        self.init(rows: rows, card: card.isEmpty ? nil : card, isFinal: report.isClosed, mySeat: mySeat,
                  online: Online(raceID: report.raceID.rawValue, rating: rating, earned: earned))
    }

    /// A scored seat's result column.
    static func result(of seat: SeatResult, winner: Int?) -> Result {
        switch seat.code {
        case .finished:
            let tick = seat.finishTick ?? 0
            let gap = winner.map { tick - $0 } ?? 0
            return gap == 0 ? .raceTime(ticks: tick) : .gap(ticks: gap)
        case .byDistance: return .byDistance
        case .dsq: return .dsq
        case .ocs: return .ocs
        case .ret: return .ret
        }
    }

    /// Whether `row` offers Report (#26, #24): another human's row in an online race. Never a bot (bots can't be
    /// reported), never your own, never practice. The reopened Last race doesn't offer it either (`ResultsView`).
    func canReport(_ row: Row) -> Bool {
        online != nil && !row.isBot && !row.isPlayer
    }
}

/// The earned design a race unlocks (#21, #24, G6).
enum EarnedUnlock {
    /// Whether a closed race with your `code` counts as completed (G6): any result but RET. A cancelled race has no
    /// code and never counts.
    static func counts(_ code: ResultCode) -> Bool { code != .ret }

    /// The earned design whose milestone this race reaches: the one needing exactly `completedBefore + 1` completed
    /// races, when `code` counts. Nil otherwise, or when the catalogue has none for the class.
    static func design(completedBefore: Int, resultCode: ResultCode, catalogue: LiveryCatalogue,
                       boatClass: String) -> LiveryDesign? {
        guard counts(resultCode) else { return nil }
        return catalogue.designs(for: boatClass).first { design in
            if case .earned(let needed) = design.acquisition { needed == completedBefore + 1 } else { false }
        }
    }

    /// The results' earned line for that design in your colours, or nil: nothing unlocked, or the design isn't drawn
    /// yet (owner 2026-10-05: hidden until #169 draws it; `MyBoatModel.select` ignores an undrawn design anyway).
    @MainActor
    static func line(completedBefore: Int, resultCode: ResultCode, livery: Livery, catalogue: LiveryCatalogue = .bundled,
                     boatClass: String = RaceFiles.defaults.boatClass.ref.id,
                     isDrawn: @MainActor (LiveryDesign) -> Bool = MyBoatModel.hasArt) -> RaceResultViewModel.EarnedLine? {
        guard let design = Self.design(completedBefore: completedBefore, resultCode: resultCode, catalogue: catalogue,
                                       boatClass: boatClass), isDrawn(design) else { return nil }
        let filled = MyBoatModel.colours(of: livery, catalogue: catalogue)
        let colours = design.slots.compactMap { filled[$0] }
        return RaceResultViewModel.EarnedLine(
            design: design.id, name: MyBoatModel.name(of: design),
            livery: Livery(design: design.id, colours: colours, sailNumber: livery.sailNumber))
    }
}
