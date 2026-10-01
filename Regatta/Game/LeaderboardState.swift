import Foundation
import RegattaCore

/// The live leaderboard on the race HUD (#268, amending #15): the fleet in standings order, each boat's place, livery
/// colour and gap to the leader in ladder metres. Compact, it is the leader, the boat directly ahead of you, you and
/// the boat directly behind you; expanded (a tap), the whole fleet. Never names (#15). Pure, over one `TickFrame`, so
/// the board never re-sorts inside a tick and the tests read exactly what the view draws. The gaps are the race's
/// (`TickFrame.gaps`, `Race.gapsToLeader()`), never worked out here.
struct LeaderboardState: Equatable {
    /// What a row shows in place of the gap.
    enum Gap: Equatable {
        /// The boat racing in first place: "Leader".
        case leader
        /// Metres behind the leader, rounded for the board (`rounded(metres:)`): "+38 m".
        case metres(Int)
        /// "Fin".
        case finished
        case dsq
        case ocs
        /// No gap: a late starter after the gun, or a boat whose player has gone (replays only): "—".
        case none

        var text: String {
            switch self {
            case .leader: "Leader"
            case .metres(let metres): "+\(metres) m"
            case .finished: "Fin"
            case .dsq: "DSQ"
            case .ocs: "OCS"
            case .none: "—"
            }
        }

        /// How VoiceOver reads it after the place.
        var spoken: String {
            switch self {
            case .leader: "leading"
            case .metres(let metres): "\(metres) m behind the leader"
            case .finished: "finished"
            case .dsq: "DSQ"
            case .ocs: "OCS"
            case .none: "no gap"
            }
        }
    }

    struct Row: Equatable, Identifiable {
        let seat: Int
        /// From 1, the standings' order.
        let place: Int
        let colorIndex: Int
        let isMe: Bool
        let gap: Gap

        var id: Int { seat }
    }

    /// A line of the board: a boat, or the thin "⋯" between two rows whose places aren't adjacent.
    enum Entry: Equatable, Identifiable {
        case row(Row)
        /// Before the row of the boat in `before`.
        case separator(before: Int)

        var id: String {
            switch self {
            case .row(let row): "row-\(row.seat)"
            case .separator(let seat): "gap-\(seat)"
            }
        }
    }

    /// From the gun until the close: hidden in the start sequence, and the results take over at the close.
    var isVisible = false
    /// The whole fleet in standings order.
    var rows: [Row] = []

    init() {}

    /// The board for `frame`, from seat `me`.
    init(frame: TickFrame, me: Int) {
        isVisible = frame.time >= 0 && !frame.isOver
        rows = frame.standings.enumerated().map { rank, seat in
            let boat = frame.boats[seat]
            let metres = frame.gaps.indices.contains(seat) ? frame.gaps[seat] : nil
            return Row(seat: seat, place: rank + 1, colorIndex: boat.colorIndex, isMe: seat == me,
                       gap: Self.gap(status: boat.status, rank: rank, metres: metres))
        }
    }

    /// Your row, if you're in the standings.
    var me: Row? { rows.first(where: \.isMe) }

    /// The board's lines. Compact: the leader, the boat directly ahead of you, you and the boat directly behind you,
    /// in standings order with duplicates merged, and a separator where the places skip. Expanded: every row.
    func entries(expanded: Bool) -> [Entry] {
        guard !expanded else { return rows.map(Entry.row) }
        guard let mine = rows.firstIndex(where: \.isMe) else { return rows.prefix(1).map(Entry.row) }
        let ranks = Set([0, mine - 1, mine, mine + 1]).filter(rows.indices.contains).sorted()
        var entries: [Entry] = []
        var last: Int?
        for rank in ranks {
            if let last, rank > last + 1 { entries.append(.separator(before: rows[rank].seat)) }
            entries.append(.row(rows[rank]))
            last = rank
        }
        return entries
    }

    /// What a row shows for a boat of `status` at `rank` in the standings (from 0) with the race's gap `metres`.
    /// Finished boats show "Fin" (the finished leader too), DSQ and OCS their code, the boat racing first "Leader",
    /// any other boat racing her gap; a boat with no gap "—".
    static func gap(status: BoatStatus, rank: Int, metres: Double?) -> Gap {
        switch status {
        case .finished: return .finished
        case .dsq: return .dsq
        case .ocs: return .ocs
        case .prestart: return .none
        case .racing:
            if rank == 0 { return .leader }
            return metres.map { .metres(rounded(metres: $0)) } ?? .none
        }
    }

    /// The board's metres: to the nearest metre below 100 m, to the nearest 5 m from there; never below 0.
    static func rounded(metres: Double) -> Int {
        guard metres.isFinite, metres > 0 else { return 0 }
        if metres < 100 { return Int(metres.rounded()) }
        return Int((metres / 5).rounded()) * 5
    }

    /// VoiceOver's reading of the board: your place and gap.
    var accessibilityLabel: String {
        guard let me else { return "Leaderboard" }
        return "Leaderboard, \(ordinal(me.place)), \(me.gap.spoken)"
    }
}
