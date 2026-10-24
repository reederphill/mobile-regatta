import Foundation
import Testing
@testable import RegattaCore

/// #88 acceptance: a near miss triggers a ruling as contact does (#9): sweeping an overlapped right-of-way
/// boat's hull ±10° over 0.5 s would hit (`RulesConfig.NearMissSweep.hits`, fleet-rules@2's values).
@Suite struct NearMissTests {
    typealias F = IncidentFixture

    /// Seat 1, to windward, bears down on seat 0 on a beam reach, 30° lower at the same 3 m/s, with 0.8 m
    /// between the hulls.
    static func bearingDown(_ race: Race, gap: Double) throws {
        let converging = deg2rad(30)
        try F.place(race, tick: 300, at: F.midBeat(race), heading: F.starboard(race, offWind: .pi / 2),
                    abeam: F.abeam(gap: gap, converging: converging, hull: race.boatClass.hull), converging: converging)
    }

    /// The overlapped windward boat 0.8 m off hasn't touched, but the leeward boat's sweep would hit her:
    /// rule 11 is called on her, with no contact.
    @Test func sweepHitWithoutContactIsAFoul() throws {
        let race = try F.race()
        try Self.bearingDown(race, gap: 0.8)
        #expect(abs(F.gap(race) - 0.8) < 0.01)
        #expect(race.isOverlapped(0, 1))
        #expect(race.rightOfWay(0, 1) == RightOfWay(keepClear: 1, rule: .windwardLeeward))
        let before = race.exportSnapshot()

        race.step()
        let events = race.drainEvents()
        #expect(F.gap(race) > 0.5, "no contact")
        #expect(race.exportSnapshot().touchingBoats.isEmpty)
        #expect(F.contacts(events).isEmpty)
        let calls = F.calls(events)
        #expect(calls.count == 1)
        #expect(calls.first?.rule == .windwardLeeward && calls.first?.offender == 1 && calls.first?.victim == 0)
        #expect(race.incidents.count == 1 && race.incidents.latest(between: 0, and: 1)?.id == calls.first?.incidentId)
        #expect(race.boats[1].penaltyTurnsOwed > 0 && race.boats[0].penaltyTurnsOwed == 0)
        #expect(race.umpire?.openIncident(SeatPair(0, 1)) == calls.first?.incidentId)

        // A prediction never sweeps: the server's calls are the only ones a client shows (ADR 0005).
        let prediction = try F.prediction(of: race)
        try prediction.importSnapshot(before)
        try prediction.tryStep()
        #expect(prediction.incidents.count == 0)
        #expect(prediction.boats[1].penaltyTurnsOwed == 0)
        #expect(F.calls(prediction.drainEvents()).isEmpty)
    }

    /// Further off, the same sweep misses: no incident.
    @Test func sweepMissIsNoIncident() throws {
        let race = try F.race()
        try Self.bearingDown(race, gap: 1.5)
        race.step()
        #expect(F.calls(race.drainEvents()).isEmpty)
        #expect(race.incidents.count == 0)
    }

    /// The sweep's geometry directly: the right-of-way boat turned up to 10° either way and sailed on, the
    /// keep-clear boat holding her course, both in straight lines over the ground for 0.5 s.
    @Test func sweepGeometry() throws {
        let rules = try RulesConfigFile.bundled(id: "fleet-rules", version: 2).content
        let sweep = rules.incidents.nearMissSweep
        let hull = try BoatClassFile.bundled(id: Fixtures.classID, version: Fixtures.version).content.hull
        func pair(gap: Double, converging: Double, speed: Double) -> (Boat, Boat) {
            let row = Boat(id: 0, isPlayer: false, colorIndex: 0, position: .zero, heading: 0, speed: speed)
            let across = IncidentFixture.abeam(gap: gap, converging: converging, hull: hull)
            let other = Boat(id: 1, isPlayer: false, colorIndex: 1, position: Vec2(across, 0), heading: -converging, speed: speed)
            return (row, other)
        }
        // Bearing down 30° at 3 m/s: 0.8 m off is a hit, 1.5 m isn't.
        let near = pair(gap: 0.8, converging: deg2rad(30), speed: 3)
        #expect(sweep.hits(near.0, near.1, hull: hull))
        let far = pair(gap: 1.5, converging: deg2rad(30), speed: 3)
        #expect(!sweep.hits(far.0, far.1, hull: hull))
        // Stopped, only the turn itself reaches across: her stern swings about 0.12 m towards the other
        // boat as she bears away 10°.
        let stopped = pair(gap: 0.05, converging: 0, speed: 0)
        #expect(sweep.hits(stopped.0, stopped.1, hull: hull))
        let stoppedFurther = pair(gap: 0.3, converging: 0, speed: 0)
        #expect(!sweep.hits(stoppedFurther.0, stoppedFurther.1, hull: hull))
        // Out of reach is never a hit, and is cheap to rule out.
        var distant = near
        distant.1.position = Vec2(50, 0)
        #expect(!sweep.canReach(distant.0, distant.1, hull: hull) && !sweep.hits(distant.0, distant.1, hull: hull))
        #expect(sweep.canReach(near.0, near.1, hull: hull))
    }

    /// #344: the near-miss reach a client draws is the umpire's own sweep. For a boat on a slant, with a current
    /// across her, the public `swept` hull at every check equals the sweep worked out from the spec by hand (her heading
    /// turned by each offset, sailed on at her speed plus the current), within 1e-9 m.
    @Test func reachIsTheUmpiresSweep() throws {
        let rules = try RulesConfigFile.bundled(id: "fleet-rules", version: 8).content
        let sweep = rules.incidents.nearMissSweep
        let hull = try BoatClassFile.bundled(id: Fixtures.classID, version: Fixtures.version).content.hull
        var row = Boat(id: 0, isPlayer: false, colorIndex: 0, position: Vec2(12.5, -40.25), heading: deg2rad(37), speed: 3.2)
        row.current = Vec2(0.3, -0.15)
        let reach = sweep.swept(row, hull: hull)

        let ticks = RulesConfig.ticks(sweep.seconds) / sweep.stepTicks
        #expect(reach.times.count == ticks && ticks > 0)
        #expect(reach.hulls.count == sweep.headingSamples)
        var worst = 0.0
        for (h, offset) in sweep.headingOffsets.enumerated() {
            let forward = Vec2.heading(row.heading + offset), right = forward.rightPerp
            for k in 0..<ticks {
                let t = Double((k + 1) * sweep.stepTicks) * Race.dt
                let centre = row.position + (forward * row.speed + row.current) * t
                worst = max(worst, (reach.centres[h][k] - centre).length)
                for (corner, local) in zip(reach.hulls[h][k], hull.outline) {
                    worst = max(worst, (corner - (centre + right * local.x + forward * local.y)).length)
                }
            }
        }
        #expect(worst <= 1e-9, "max difference \(worst) m")

        // The outline holds every swept corner, and a keep-clear boat lying still just inside it on her bow is a near
        // miss, just outside it none.
        let outline = reach.outline
        #expect(outline.count >= 3)
        let outside = reach.hulls.joined().joined().filter { corner in
            outline.indices.contains { i in
                (outline[(i + 1) % outline.count] - outline[i]).cross(corner - outline[i]) < -1e-9
            }
        }
        #expect(outside.isEmpty)
        var straight = Boat(id: 0, isPlayer: false, colorIndex: 0, position: .zero, heading: 0, speed: 3)
        straight.current = .zero
        let ahead = sweep.swept(straight, hull: hull).outline.map(\.y).max() ?? 0
        let stern = hull.outline.map(\.y).min() ?? 0
        func lyingAhead(_ into: Double) -> Boat {
            Boat(id: 1, isPlayer: false, colorIndex: 1, position: Vec2(0, ahead - into - stern), heading: 0, speed: 0)
        }
        #expect(sweep.hits(straight, lyingAhead(0.1), hull: hull))
        #expect(!sweep.hits(straight, lyingAhead(-0.1), hull: hull))
    }
}
