import Foundation
import Testing
@testable import RegattaCore

/// #94 acceptance: one tap protests any boat, a ghost or a bot included (#9); the protest is linked to the
/// pair's incident of the protest window before it (15 s, inclusive, from its last contact), or to none; only
/// the protester is told; and a protest never changes a result.
@Suite struct ProtestTests {
    typealias F = IncidentFixture

    /// The protest window in ticks: fleet-rules' `protestWindowSeconds`, 15 s.
    static func window(_ race: Race) -> Int { RulesConfig.ticks(race.rules.raceFormat.protestWindow) }

    struct Told: Equatable {
        let tick: Int, seat: Int, target: Int, matched: Int?
    }

    /// The `protestRecorded` events among `events`, with the tick each was told on.
    static func protests(_ events: [RaceEvent]) -> [Told] {
        events.compactMap {
            if case .protestRecorded(let seat, let target, let matched) = $0.kind {
                Told(tick: $0.tick, seat: seat, target: target, matched: matched)
            } else { nil }
        }
    }

    /// Steps `race` until it has applied tick `tick`, and returns every event on the way.
    static func step(_ race: Race, through tick: Int) -> [RaceEvent] {
        var events: [RaceEvent] = []
        while race.tick < tick {
            race.step()
            events += race.drainEvents()
        }
        return events
    }

    /// The boats touch and the umpire calls it, then they part by 3 hull lengths, so the call's contact is the
    /// incident's last. Returns the call.
    static func calledThenParted(_ race: Race) throws -> RuleCall {
        try F.touching(race, tick: 300)
        race.step()
        let call = try #require(F.calls(race.drainEvents()).first)
        try F.apart(race, tick: race.tick, at: race.boats[0].position, gap: 3 * race.boatClass.hull.length)
        return call
    }

    /// The fouled boat protests 5 s after the call: the protest links the call's incident, is recorded with it,
    /// and is told to her alone. The window is inclusive: 15 s after still links it, a tick later doesn't.
    @Test func protestAfterACallLinksItsIncident() throws {
        let race = try F.race()
        let call = try Self.calledThenParted(race)
        let window = Self.window(race)
        #expect(window == 15 * Race.tickRate)
        #expect(race.incidents.lastContactTick(inIncident: call.incidentId) == call.tick)

        let fiveSeconds = call.tick + 5 * Race.tickRate
        #expect(race.tap(.protest(target: call.offender), seat: call.victim, atTick: fiveSeconds) == fiveSeconds)
        race.tap(.protest(target: call.victim), seat: call.offender, atTick: call.tick + window)
        race.tap(.protest(target: call.offender), seat: call.victim, atTick: call.tick + window + 1)
        let events = Self.step(race, through: call.tick + window + 1)

        #expect(Self.protests(events) == [
            Told(tick: fiveSeconds, seat: call.victim, target: call.offender, matched: call.incidentId),
            Told(tick: call.tick + window, seat: call.offender, target: call.victim, matched: call.incidentId),
            Told(tick: call.tick + window + 1, seat: call.victim, target: call.offender, matched: nil),
        ])
        #expect(race.incidents.protests == [
            Protest(tick: fiveSeconds, leg: 0, protester: call.victim, protested: call.offender, matchedIncidentId: call.incidentId),
            Protest(tick: call.tick + window, leg: 0, protester: call.offender, protested: call.victim,
                    matchedIncidentId: call.incidentId),
            Protest(tick: call.tick + window + 1, leg: 0, protester: call.victim, protested: call.offender, matchedIncidentId: nil),
        ])
        #expect(race.incidents.protests(by: call.victim).map(\.tick) == [fiveSeconds, call.tick + window + 1])
        #expect(race.incidents.count == 1, "a protest is no incident")
    }

    /// A protest on the very tick the incident opens links it (the window is [t − 15 s, t]): the race matches
    /// protests after the tick's calls.
    @Test func protestOnTheIncidentsTickLinksIt() throws {
        let race = try F.race()
        try F.touching(race, tick: 300)
        race.tap(.protest(target: 1), seat: 0, atTick: 301)
        race.step()
        let events = race.drainEvents()
        let call = try #require(F.calls(events).first)
        #expect(call.tick == 301)
        #expect(Self.protests(events).map(\.matched) == [call.incidentId])
    }

    /// With no incident between the pair, or none within the window, a protest is still recorded and told,
    /// linked to none: "no call".
    @Test func protestWithNoIncidentRecordsNilLink() throws {
        let race = try F.race()
        try F.apart(race, tick: 300, at: F.midBeat(race), gap: 3 * race.boatClass.hull.length)
        race.tap(.protest(target: 1), seat: 0, atTick: 310)
        #expect(Self.protests(Self.step(race, through: 310)) == [Told(tick: 310, seat: 0, target: 1, matched: nil)])
        #expect(race.incidents.protests == [Protest(tick: 310, leg: 0, protester: 0, protested: 1, matchedIncidentId: nil)])
        #expect(race.incidents.count == 0)

        // An incident whose last contact is more than the window before the protest is too old to link.
        let late = try F.race()
        let call = try Self.calledThenParted(late)
        let at = call.tick + Self.window(late) + 1
        late.tap(.protest(target: call.offender), seat: call.victim, atTick: at)
        #expect(Self.protests(Self.step(late, through: at)).map(\.matched) == [nil])
        #expect(late.incidents.protests.map(\.matchedIncidentId) == [nil])
    }

    /// Protests are records only: a race whose boats protest each other again and again, in an incident and
    /// out of one, sails, penalises and scores exactly as its twin that never protests.
    @Test func protestsNeverChangeResults() throws {
        let protested = try F.race(), quiet = try F.race()
        let call = try Self.calledThenParted(protested)
        #expect(try Self.calledThenParted(quiet) == call)
        let start = protested.tick
        for k in 0..<12 {
            protested.tap(.protest(target: k % 2), seat: 1 - k % 2, atTick: start + 1 + k * 60)
        }
        let end = start + 12 * 60 + 30
        let told = Self.protests(Self.step(protested, through: end))
        _ = Self.step(quiet, through: end)
        #expect(told.count == 12)
        #expect(told.contains { $0.matched == call.incidentId } && told.contains { $0.matched == nil })

        #expect(protested.digest() == quiet.digest())
        for seat in 0..<2 {
            #expect(protested.boats[seat].penaltyTurnsOwed == quiet.boats[seat].penaltyTurnsOwed)
            #expect(protested.boats[seat].status == quiet.boats[seat].status)
        }
        #expect(protested.incidents.incidents == quiet.incidents.incidents)
        #expect(protested.incidents.contacts == quiet.incidents.contacts)
        #expect(protested.incidents.protests.count == 12 && quiet.incidents.protests.isEmpty)

        #expect(protested.closeAllGone(atTick: end, leaveOrder: [0, 1]))
        #expect(quiet.closeAllGone(atTick: end, leaveOrder: [0, 1]))
        let results = try #require(protested.results)
        #expect(results == quiet.results)
    }

    /// A ghost (finished or DSQ) may protest and be protested (#9: any boat): both are recorded, and linked to
    /// the pair's incident within the window, though she sails through everything now.
    @Test func ghostProtestsAndProtestsAgainstGhostsAreRecorded() throws {
        for status in [BoatStatus.finished, .dsq] {
            let race = try F.race()
            let call = try Self.calledThenParted(race)
            let ghost = call.offender, other = call.victim
            let now = race.tick
            try jump(race, to: now) { snapshot in
                snapshot.seats[ghost].boat.status = status
                if status == .finished {
                    snapshot.seats[ghost].boat.place = 1
                    snapshot.seats[ghost].boat.finishTime = 5
                    snapshot.firstFinishTime = 5
                }
            }
            #expect(race.isGhost(seat: ghost), "\(status)")

            let byGhost = call.tick + 5 * Race.tickRate, againstGhost = call.tick + 10 * Race.tickRate
            #expect(race.tap(.protest(target: other), seat: ghost, atTick: byGhost) == byGhost, "\(status)")
            #expect(race.tap(.protest(target: ghost), seat: other, atTick: againstGhost) == againstGhost, "\(status)")
            #expect(Self.protests(Self.step(race, through: againstGhost)) == [
                Told(tick: byGhost, seat: ghost, target: other, matched: call.incidentId),
                Told(tick: againstGhost, seat: other, target: ghost, matched: call.incidentId),
            ], "\(status)")
            #expect(race.incidents.protests.map(\.matchedIncidentId) == [call.incidentId, call.incidentId], "\(status)")
            #expect(race.incidents.protests.map(\.protester) == [ghost, other], "\(status)")
        }
    }

    /// A prediction has no umpire: it records no protest or boat contact, and tells no one (ADR 0005: the
    /// server's acknowledgement is the one shown).
    @Test func predictionRecordsNoProtest() throws {
        let race = try F.race()
        try F.touching(race, tick: 300)
        let prediction = try F.prediction(of: race)
        prediction.tap(.protest(target: 1), seat: 0, atTick: 301)
        let events = Self.step(prediction, through: 302)
        #expect(Self.protests(events).isEmpty)
        #expect(prediction.incidents.protests.isEmpty)
        #expect(prediction.incidents.contacts.isEmpty)
    }

    /// Every contact is recorded in the index with the incident it is part of: the first opens and links the
    /// call's incident, a touch again inside it links the same one.
    @Test func boatContactsLinkTheirIncident() throws {
        let race = try F.race()
        try F.touching(race, tick: 300)
        race.step()
        let call = try #require(F.calls(race.drainEvents()).first)
        try F.apart(race, tick: race.tick, at: race.boats[0].position, gap: race.boatClass.hull.length)
        race.step()
        try F.touching(race, tick: race.tick, at: race.boats[0].position)
        race.step()
        let contacts = race.incidents.contacts
        #expect(contacts.map(\.incidentId) == [call.incidentId, call.incidentId])
        #expect(contacts.map(\.parties) == [SeatPair(0, 1), SeatPair(0, 1)])
        #expect(contacts.first?.tick == call.tick && contacts.last?.tick == race.tick)
        #expect(race.incidents[call.incidentId]?.trigger == .contact)
        #expect(race.incidents.lastContactTick(inIncident: call.incidentId) == race.tick)
    }
}
