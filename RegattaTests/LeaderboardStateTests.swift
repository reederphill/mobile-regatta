import CoreGraphics
import Foundation
import Testing
import RegattaCore
@testable import Regatta

/// #268 acceptance: the live leaderboard's rows (leader, ahead, you, behind, with a separator where places skip), its
/// gap words and rounding, and that it shows only from the gun to the close. Plus the board's place on the HUD.
@MainActor @Suite struct LeaderboardStateTests {
    /// An eight-boat race's fleet, every boat racing unless `statuses` says otherwise.
    static let fleet: [Boat] = {
        let config = RaceConfig(opponents: 7, prestartSeconds: 60, seed: 1, windSeed: RaceConfig.windSeed(pinnedTo: 1))
        return Race(setup: config.setup, windSeed: WindSeed(7)).boats
    }()

    /// A frame at `tick` with `standings`, each seat's status from `statuses` (racing if absent) and gap from `gaps`.
    static func frame(tick: Int = 600, standings: [Int] = Array(0..<8), statuses: [Int: BoatStatus] = [:],
                      gaps: [Int: Double] = [:], isOver: Bool = false) -> TickFrame {
        let boats = fleet.indices.map { seat in
            var boat = fleet[seat]
            boat.status = statuses[seat] ?? .racing
            return boat
        }
        let race = Race(setup: RaceDriverTests.config.setup, windSeed: WindSeed(7))
        return TickFrame(tick: tick, boats: boats, standings: standings, wind: race.wind, isOver: isOver,
                         gaps: boats.indices.map { gaps[$0] })
    }

    /// The seats of the rows, and "⋯" for each separator.
    static func lines(_ state: LeaderboardState, expanded: Bool = false) -> [String] {
        state.entries(expanded: expanded).map { entry in
            switch entry {
            case .row(let row): String(row.seat)
            case .separator: "⋯"
            }
        }
    }

    @Test func compactRowsAreLeaderAheadMeBehind() {
        // Standings 3, 5, 0, 7, 1, 2, 6, 4.
        let standings = [3, 5, 0, 7, 1, 2, 6, 4]
        func board(me: Int) -> LeaderboardState { LeaderboardState(frame: Self.frame(standings: standings), me: me) }

        // Me first: the leader is me; the one behind; no one ahead.
        #expect(Self.lines(board(me: 3)) == ["3", "5"])
        // Me second: the leader is also the boat ahead, merged.
        #expect(Self.lines(board(me: 5)) == ["3", "5", "0"])
        // Me third: leader, ahead, me, behind; all adjacent, no separator.
        #expect(Self.lines(board(me: 0)) == ["3", "5", "0", "7"])
        // Me in the middle: a gap in the ranks between the leader and the boat ahead.
        #expect(Self.lines(board(me: 1)) == ["3", "⋯", "7", "1", "2"])
        // Me last: no one behind.
        #expect(Self.lines(board(me: 4)) == ["3", "⋯", "6", "4"])

        // Places and "you" ride on the rows; expanded is the whole fleet in order, no separators.
        let middle = board(me: 1)
        let rows = middle.entries(expanded: false).compactMap { if case .row(let row) = $0 { row } else { nil } }
        #expect(rows.map(\.place) == [1, 4, 5, 6])
        #expect(rows.map(\.isMe) == [false, false, true, false])
        #expect(rows.map(\.colorIndex) == [3, 7, 1, 2].map { Self.fleet[$0].colorIndex })
        #expect(Self.lines(middle, expanded: true) == standings.map(String.init))
        #expect(middle.accessibilityLabel.hasPrefix("Leaderboard, 5th, "))
    }

    @Test func gapFormattingRoundsAndCodes() {
        typealias Gap = LeaderboardState.Gap
        // Metres: to 1 m below 100 m, to 5 m from 100 m.
        #expect(LeaderboardState.rounded(metres: 0) == 0)
        #expect(LeaderboardState.rounded(metres: -0.3) == 0)
        #expect(LeaderboardState.rounded(metres: 37.6) == 38)
        #expect(LeaderboardState.rounded(metres: 99.4) == 99)
        #expect(LeaderboardState.rounded(metres: 100) == 100)
        #expect(LeaderboardState.rounded(metres: 102.4) == 100)
        #expect(LeaderboardState.rounded(metres: 102.5) == 105)
        #expect(LeaderboardState.rounded(metres: 1238) == 1240)
        #expect(Gap.metres(38).text == "+38 m")
        #expect(Gap.metres(1240).text == "+1240 m")

        // The words: Leader, Fin, DSQ, OCS, and "—" where the race gives no gap.
        #expect(Gap.leader.text == "Leader" && Gap.finished.text == "Fin")
        #expect(Gap.dsq.text == "DSQ" && Gap.ocs.text == "OCS" && Gap.none.text == "—")

        // From a frame: the leader racing; a finished leader shows Fin, and the boats racing after a finish their
        // metres still to go (#267); DSQ, OCS, a late starter and a boat with no gap (gone) show their codes.
        let racing = LeaderboardState(frame: Self.frame(gaps: [0: 0, 1: 37.6, 2: 212.4, 3: 0.2]), me: 1)
        #expect(racing.rows.prefix(4).map(\.gap) == [.leader, .metres(38), .metres(210), .metres(1)])
        let later = LeaderboardState(
            frame: Self.frame(statuses: [0: .finished, 1: .finished, 5: .dsq, 6: .ocs, 7: .prestart],
                              gaps: [0: 0, 1: 0, 2: 150.2, 3: 0.4]),
            me: 2)
        #expect(later.rows.map(\.gap) == [.finished, .finished, .metres(150), .metres(1), .none, .dsq, .ocs, .none])
        #expect(later.accessibilityLabel == "Leaderboard, 3rd, 150 m behind the leader")
    }

    @Test func hiddenBeforeTheGun() {
        #expect(!LeaderboardState(frame: Self.frame(tick: -300, statuses: Dictionary(uniqueKeysWithValues: (0..<8).map { ($0, .prestart) })), me: 0).isVisible)
        #expect(!LeaderboardState(frame: Self.frame(tick: -1), me: 0).isVisible)
        #expect(LeaderboardState(frame: Self.frame(tick: 0), me: 0).isVisible, "from the gun")
        #expect(LeaderboardState(frame: Self.frame(tick: 9000), me: 0).isVisible)
        #expect(!LeaderboardState(frame: Self.frame(tick: 9000, isOver: true), me: 0).isVisible,
                "after the close the results take over")
        #expect(!LeaderboardState().isVisible)

        // The HUD reads it from the driver's latest frame: a practice race starts in its sequence.
        let driver = PracticeDriver(config: RaceDriverTests.config)
        #expect(driver.renderWorld.frame.time < 0)
        #expect(!HUDState(world: driver.renderWorld).leaderboard.isVisible)
    }

    /// The gaps come from the race once per tick: `TickFrame(race:)` carries `Race.gapsToLeader()`.
    @Test func frameCarriesTheRacesGaps() {
        let race = Race(setup: RaceDriverTests.config.setup, windSeed: WindSeed(7))
        let frame = TickFrame(race: race)
        #expect(frame.gaps == race.gapsToLeader())
        #expect(frame.extrapolatedBackOneTick().gaps == frame.gaps)
    }

    /// The board sits under the clock, place and wind, clear of the minimap at an SE's 375 pt, and with it on the
    /// notice line starts below the compact board at its tallest; with it off the notice keeps #114's place.
    @Test func boardFitsTheHUD() {
        #expect(HUDView.noticeTop(showsLeaderboard: false) == 4 + HUDView.minimapSize.height + 8,
                "the HUD fixtures before #268 keep their references")
        #expect(HUDLayout.boardBottomCompact + 8 <= HUDView.noticeTop(showsLeaderboard: true))
        #expect(HUDLayout.boardTop >= HUDLayout.placeTop + HUDLayout.lineHeight(size: HUDLayout.placeSize))
        #expect(HUDLayout.boardTop >= HUDLayout.windBottom)
        let right = HUDLayout.edge + HUDLayout.pauseClearance + HUDLayout.boardWidth
        #expect(right <= 375 - HUDLayout.edge - HUDView.minimapSize.width - HUDLayout.spacing)
        for gap in HUDLayout.widestGaps {
            #expect(HUDLayout.width(of: gap, size: HUDLayout.boardSize, weight: .heavy) <= HUDLayout.boardGapWidth)
        }
    }
}
