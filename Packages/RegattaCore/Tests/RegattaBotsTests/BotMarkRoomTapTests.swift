import Foundation
import Testing
import RegattaCore
@testable import RegattaBots

/// #525 H3: the gybe past a boat that owes her mark-room. It keeps clear of her (rule 18.2), so the tap may pass it
/// `BotBrain.tapClearanceOwing` hull lengths off, not `tapClearance`; any other boat is weighed as ever.
@Suite struct BotMarkRoomTapTests {
    /// Seat 0 entitled to mark-room from seat 1 at the windward mark, as the umpire records it: the mark-room encounter
    /// (`BotConductTests.markRoom`), sailed until the notice stands. Nothing but the notice is kept of it: the boats are
    /// moved by `geometry`.
    static func noticed() throws -> Race {
        try BotConductTests.$waterClass.withValue(BotHelmTests.autohelmOn().ref) {
            let encounter = BotConductTests.markRoom(seed: 19, abeam: 1.2, ahead: 0)
            let race = try encounter.race()
            var pilots = [0, 1].map { BotConductTests.Pilot(seat: $0, plannedTack: .starboard, race: race) }
            for _ in 0..<(40 * Race.tickRate) where !race.isOver {
                for i in pilots.indices { _ = pilots[i].drive(race) }
                race.step()
                let notices = race.seatView(for: 0).own.markRoom
                if notices.contains(where: { $0.entitled == 0 && $0.owing == 1 }) { return race }
            }
            throw Missing.notice
        }
    }

    enum Missing: Error { case notice }

    /// The scene at `race`'s notice with seat 1 moved to pass seat 0's tap `lengths` hull lengths off: standing still
    /// beside the track her tap sails (the mirror of her heading, at half her speed), 1.5 s along it.
    static func geometry(_ race: Race, lengths: Double) throws -> Race {
        var snapshot = race.exportSnapshot()
        let view = race.seatView(for: 0)
        let b = view.own
        let heading = 2 * b.windDirection - b.heading
        let forward = Vec2.heading(heading)
        let along = b.position + forward * (b.speed * BotBrain.tapSpeedShare * 1.5)
        snapshot.seats[1].boat.position = along + forward.rightPerp * (view.boatClass.hull.length * lengths)
        snapshot.seats[1].boat.speed = 0
        try race.importSnapshot(snapshot)
        return race
    }

    /// The same boats, the same places, and no notice: a bot's view of boats that owe her nothing.
    static func unnoticed(like race: Race) throws -> Race {
        try BotConductTests.$waterClass.withValue(BotHelmTests.autohelmOn().ref) {
            let water = BotConductTests.Water(seed: 19)
            return try BotConductTests.place(water, race.boats.map {
                .init(position: $0.position, heading: $0.heading, speed: $0.speed, legIndex: $0.legIndex)
            })
        }
    }

    /// #525 H3 acceptance: against a boat that owes her mark-room a tap is clear at a pass of 0.6 to 1.3 hull lengths
    /// and not inside 0.6; the same geometry with no notice is not clear inside 1.3.
    @Test func gybePastABoatThatOwesHerRoom() throws {
        let passes = [0.45, 0.55, 0.65, 1.0, 1.25, 1.35, 1.6]
        for lengths in passes {
            let race = try Self.geometry(try Self.noticed(), lengths: lengths)
            let view = race.seatView(for: 0)
            try #require(view.own.markRoom.contains { $0.entitled == 0 && $0.owing == 1 }, "\(lengths): no notice")
            let brain = BotBrain(style: BotConductTests.skill1)
            try Self.requirePass(view, lengths)
            #expect(brain.tapIsClear(view.own, view) == (lengths >= BotBrain.tapClearanceOwing), "owing, \(lengths) lengths")

            // The wind has gone on since: the pass is laid out anew in the same places.
            let plain = try Self.geometry(try Self.unnoticed(like: race), lengths: lengths)
            let plainView = plain.seatView(for: 0)
            try #require(plainView.own.markRoom.isEmpty)
            try Self.requirePass(plainView, lengths)
            #expect(brain.tapIsClear(plainView.own, plainView) == (lengths >= BotBrain.tapClearance), "no notice, \(lengths) lengths")
        }
    }

    /// Fails unless the other boat passes her tap `lengths` hull lengths off.
    static func requirePass(_ view: SeatView, _ lengths: Double) throws {
        let other = try #require(view.others.first)
        let hull = view.boatClass.hull.length
        let approach = BotBrain.closestApproach(of: other, to: view.own, heading: 2 * view.own.windDirection - view.own.heading,
                                                speed: view.own.speed * BotBrain.tapSpeedShare, lookahead: BotBrain.tapLookahead)
        try #require(abs(approach - hull * lengths) < 0.05, "\(lengths): the pass is \(approach / hull) lengths")
    }

    /// #525 H3: the notice must name her entitled and the other boat owing: a notice the other way round (she owes) is
    /// 1.3 as ever, and a cautious bot scales the owing pass by her clearance factor.
    @Test func onlyABoatThatOwesHerRoomAndTheCautiousScale() throws {
        let race = try Self.geometry(try Self.noticed(), lengths: 1.0)
        let view0 = race.seatView(for: 0), view1 = race.seatView(for: 1)
        try #require(view1.own.markRoom.contains { $0.entitled == 0 && $0.owing == 1 })
        let brain = BotBrain(style: BotConductTests.skill1)
        let owing = try #require(view0.others.first), entitled = try #require(view1.others.first)
        #expect(brain.tapClearanceLengths(for: owing, view0.own, view0) == BotBrain.tapClearanceOwing)
        #expect(brain.tapClearanceLengths(for: entitled, view1.own, view1) == BotBrain.tapClearance, "she owes it: 1.3")
        let cautious = BotBrain(style: BotConductTests.skill1, caution: .standard)
        let factor = try #require(cautious.caution?.clearanceFactor)
        #expect(cautious.tapClearanceLengths(for: owing, view0.own, view0) == BotBrain.tapClearanceOwing * factor)
        #expect(cautious.tapClearanceLengths(for: entitled, view1.own, view1) == BotBrain.tapClearance * factor)
    }
}
