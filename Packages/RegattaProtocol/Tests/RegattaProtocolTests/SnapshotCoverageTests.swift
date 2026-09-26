import RegattaCore
@testable import RegattaProtocol
import Testing

/// The stored fields of a seat, as paths: each stored property of `WorldSnapshot.Seat`, and inside a
/// struct-valued one (`boat`, `heldInput`) each of its stored properties. Found by reflection, so a
/// field added to `Boat`, `BoatInput` or the seat shows up here without anyone listing it.
func storedSeatFields(of seat: Any) -> [String] {
    Mirror(reflecting: seat).children.flatMap { child -> [String] in
        guard let label = child.label else { return [] }
        let inner = Mirror(reflecting: child.value)
        guard inner.displayStyle == .struct, !inner.children.isEmpty else { return [label] }
        return inner.children.compactMap { $0.label.map { "\(label).\($0)" } }
    }
}

/// Seat fields in neither the wire list nor the exclusion list.
func uncoveredSeatFields(of seat: Any) -> [String] {
    storedSeatFields(of: seat).filter { !SnapshotFields.wire.contains($0) && SnapshotFields.excluded[$0] == nil }
}

/// A real seat whose boat reflects one more stored field than `Boat` has: what the coverage check sees
/// after someone adds `var coverageProbe = 0` to `Boat`, without leaving that field in `Boat`.
struct SeatWithProbedBoat: CustomReflectable {
    struct ProbedBoat: CustomReflectable {
        let boat: Boat
        var customMirror: Mirror {
            Mirror(self, children: Array(Mirror(reflecting: boat).children) + [(label: "coverageProbe", value: 0)],
                   displayStyle: .struct)
        }
    }

    let seat: WorldSnapshot.Seat
    var customMirror: Mirror {
        let children = Mirror(reflecting: seat).children.map { child -> Mirror.Child in
            child.label == "boat" ? (label: "boat", value: ProbedBoat(boat: seat.boat)) : child
        }
        return Mirror(self, children: children, displayStyle: .struct)
    }
}

/// A real seat with one more stored per-seat field beside the boat and held input.
struct SeatWithProbe: CustomReflectable {
    let seat: WorldSnapshot.Seat
    var customMirror: Mirror {
        Mirror(self, children: Array(Mirror(reflecting: seat).children) + [(label: "coverageProbe", value: true)],
               displayStyle: .struct)
    }
}

/// The mirror-based coverage test (#63): every stored field of a seat is on the wire or excluded with a
/// reason. It fails when `Boat`, `BoatInput` or `WorldSnapshot.Seat` gains a stored property that is
/// in neither list; later core tickets extend the snapshot and the lists to pass it.
@Suite struct SnapshotCoverageTests {
    static let seat = WorldSnapshot.Seat(
        boat: Boat(id: 0, isPlayer: true, colorIndex: 0, position: Vec2(0, 0), heading: 0, speed: 0),
        heldInput: .neutral
    )

    @Test func everyStoredSeatFieldIsOnTheWireOrExcluded() {
        let fields = storedSeatFields(of: Self.seat)
        #expect(fields.contains("boat.position") && fields.contains("heldInput.rudder"))
        #expect(fields.count > 20)
        #expect(uncoveredSeatFields(of: Self.seat) == [],
                "a seat gained stored state: add it to SnapshotFields.wire (and WireSeat) or SnapshotFields.excluded")
    }

    /// Checked with a test-only field: the same check fails on a seat whose `Boat` reflects one more
    /// stored field, and on a seat with one more field of its own.
    @Test func aBoatFieldMissingFromBothListsFailsTheCheck() {
        #expect(uncoveredSeatFields(of: SeatWithProbedBoat(seat: Self.seat)) == ["boat.coverageProbe"])
        #expect(uncoveredSeatFields(of: SeatWithProbe(seat: Self.seat)) == ["coverageProbe"])
        // The probe reflects everything the real seat does, plus the probe.
        let probed = storedSeatFields(of: SeatWithProbedBoat(seat: Self.seat))
        #expect(probed.count == storedSeatFields(of: Self.seat).count + 1)
        #expect(Set(probed) == Set(storedSeatFields(of: Self.seat) + ["boat.coverageProbe"]))
    }

    @Test func theListsNameOnlyRealFieldsAndDontOverlap() {
        let fields = Set(storedSeatFields(of: Self.seat))
        #expect(Set(SnapshotFields.wire).subtracting(fields).sorted() == [], "wire list names fields a seat doesn't have")
        #expect(Set(SnapshotFields.excluded.keys).subtracting(fields).sorted() == [], "exclusion list names fields a seat doesn't have")
        #expect(Set(SnapshotFields.wire).isDisjoint(with: SnapshotFields.excluded.keys))
        #expect(SnapshotFields.wire.count == Set(SnapshotFields.wire).count)
        #expect(SnapshotFields.excluded.values.allSatisfy { !$0.isEmpty })
    }

    /// #79: a boat's three winds and the current at her are recomputed at the start of every step, so
    /// the wire leaves them out and a receiver keeps its own.
    @Test func theBoatsWindsAndCurrentAreDerivedNotSent() {
        let fields = Set(storedSeatFields(of: Self.seat))
        for field in ["boat.windOverGround", "boat.sailingWind", "boat.apparentWind", "boat.current"] {
            #expect(fields.contains(field))
            #expect(!SnapshotFields.wire.contains(field))
            #expect(SnapshotFields.excluded[field]?.hasPrefix("derived:") == true, "\(field)")
        }
    }
}

/// #18: a 16-boat snapshot is about 0.5 KB. 512 bytes is a hard ceiling, with room left for the rules
/// fields #96 adds (per-pair right-of-way bits, penalty deadlines, ghost, OCS returning).
@Suite struct SnapshotBudgetTests {
    static let ceiling = 512
    /// Frame header, the ack (flag, seq, applied tick, margin) and the seat count.
    static let fixedBytes = Frame.headerSize + 1 + 4 + 4 + 2 + 1

    @Test func sixteenBoatSnapshotFitsIn512Bytes() throws {
        let race = botRace()
        var largest = 0
        var gen = Gen(seed: 512)
        // Real states through a whole race, and random ones over every field's full range.
        while !race.isOver && race.tick < 9000 {
            for _ in 0..<3 { race.step() }
            let snapshot = try Snapshot(world: race.exportSnapshot(), ack: InputAck(seq: .max, appliedTick: race.tick, margin: -32_768))
            largest = max(largest, try Frame(seq: .max, tick: race.tick, message: .snapshot(snapshot)).encoded().count)
        }
        for _ in 0..<500 {
            let snapshot = Snapshot(seats: gen.wireSeats(16), ack: InputAck(seq: gen.u32(), appliedTick: gen.tick(), margin: 5))
            largest = max(largest, try Frame(seq: gen.u32(), tick: gen.tick(), message: .snapshot(snapshot)).encoded().count)
        }
        let expected = Self.fixedBytes + 16 * SnapshotQuantisation.bytesPerSeat
        print("BUDGET 16-boat snapshot: \(largest) B of \(Self.ceiling) B (\(Self.ceiling - largest) B headroom); \(SnapshotQuantisation.bytesPerSeat) B per seat + \(Self.fixedBytes) B fixed")
        #expect(largest == expected)
        #expect(largest <= Self.ceiling)
    }

    @Test func aSeatIsItsDocumentedSize() throws {
        var gen = Gen(seed: 20)
        for n in 2...16 {
            let bytes = try Frame(seq: 0, tick: 0, message: .snapshot(Snapshot(seats: gen.wireSeats(n)))).encoded()
            #expect(bytes.count == Frame.headerSize + 1 + 1 + n * SnapshotQuantisation.bytesPerSeat)
        }
    }
}
