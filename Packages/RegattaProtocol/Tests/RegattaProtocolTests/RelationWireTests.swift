import RegattaCore
import Testing
@testable import RegattaProtocol

/// The server umpire's relations on the wire (#96, `WireRelation`): six bits a seat in each recipient's snapshot.
@Suite struct RelationWireTests {
    /// Acceptance (#96): the relation bits a seat's snapshot carries, decoded, are the authoritative race's
    /// `keepClearRelations(of:)` (the glow's source: rule 21 over rules 10–13) and `properCourseRestrictions(of:)`
    /// for every pair within the wire range, and none for a pair outside it, through a whole bot race.
    @Test func snapshotRelationBitsAreTheServersForEveryPairInRange() throws {
        let race = botRace()
        var inRange = 0, outOfRange = 0
        let hull = race.race.boatClass.hull.length
        while !race.isOver && race.tick < 6000 {
            for _ in 0..<3 { race.step() }
            for seat in race.race.boats.indices {
                var snapshot = try Snapshot(world: race.exportSnapshot())
                snapshot.relations = WireRelation.relations(of: seat, in: race.race)
                let frame = try Frame(decoding: Frame(seq: 1, tick: race.tick, message: .snapshot(snapshot)).encoded())
                guard case .snapshot(let received) = frame.message, let relations = received.relations else {
                    Issue.record("no relations")
                    return
                }
                let decoded = WireRelation.umpireRelations(relations, seat: seat)
                let server = race.race.keepClearRelations(of: seat)
                let restricted = race.race.properCourseRestrictions(of: seat)
                for other in race.race.boats.indices where other != seat {
                    let near = RightOfWayGlyph.isInRange(race.race.boats[seat].position, race.race.boats[other].position,
                                                         rangeHulls: WireRelation.rangeHulls, hullLength: hull)
                    if near {
                        if server[other] != nil { inRange += 1 }
                        #expect(decoded.keepClear[other] == server[other], "tick \(race.tick) \(seat)-\(other)")
                        #expect(decoded.restrictedBy.contains(other) == restricted.contains(other))
                    } else {
                        if server[other] != nil { outOfRange += 1 }
                        #expect(decoded.keepClear[other] == nil && !decoded.restrictedBy.contains(other))
                    }
                }
                #expect(decoded.keepClear[seat] == nil && relations[seat] == .none)
            }
        }
        #expect(inRange > 0 && outOfRange > 0)
    }

    /// Each relation has one encoding: no rule outside `wireRules`, no direction or rule bits without a relation,
    /// no padding bits.
    @Test func nonCanonicalRelationBitsAreRejected() throws {
        var gen = Gen(seed: 96)
        for n in 2...16 {
            let relations = gen.relations(n)
            var w = WireWriter()
            try encodeRelations(relations, to: &w)
            #expect(w.bytes.count == WireRelation.byteCount(seats: n))
            var r = WireReader(w.bytes)
            #expect(try decodeRelations(seats: n, from: &r) == relations)
        }
        #expect(throws: WireError.invalidValue("relation")) { try WireRelation(bits: 0b00_0010) }
        #expect(throws: WireError.invalidValue("relation")) { try WireRelation(bits: 0b00_0100) }
        #expect(throws: WireError.invalidValue("relation")) { try WireRelation(bits: 0b100_0000) }
        var padded = WireReader([0, 0, 0b1000_0000])
        #expect(throws: WireError.invalidValue("relations padding")) { try decodeRelations(seats: 3, from: &padded) }
        #expect(throws: WireError.outOfRange("relation.rule")) {
            var w = WireWriter()
            try encodeRelations([.none, WireRelation(keepClear: .init(recipientKeepsClear: true, rule: .properCourse),
                                                     isRestricted: false)], to: &w)
        }
        let relation = try WireRelation(bits: 0b10_0001)
        #expect(relation == WireRelation(keepClear: .init(recipientKeepsClear: true, rule: .portStarboard), isRestricted: true))
    }
}
