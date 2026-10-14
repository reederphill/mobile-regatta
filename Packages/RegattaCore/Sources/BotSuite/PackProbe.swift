import Foundation
import RegattaCore
import RegattaBots

// PROTOTYPE (#525, never merged): the Q1 measures at the leeward gate, one `PK` line a gate rounding on stderr when
// REGATTA_PACK_DUMP is set. Reads the race only (the seat view for the mark-room notices), draws nothing.
struct PackProbe {
    static let enabled = ProcessInfo.processInfo.environment["REGATTA_PACK_DUMP"] != nil
    static let packRange = 40.0
    static let dirtyAir = 0.85

    struct Record {
        var seat: Int
        var leg: Int
        var entryTick = 0
        var neighbours: [(seat: Int, metres: Double)] = []
        var crossTick: Int?
        var crossPosition = Vec2.zero
        var owingAtCross: [Int: Vec2] = [:]
        var entitledOwing: Set<Int> = []
        var dirtyTicks = 0
        var dirtyMetres = 0.0
        var shadowMin = 1.0
        var rounded: Int?
        var passedOutside = false
        var passedOutsideAny = false
        var complete: Bool { crossTick != nil }
    }

    private var open: [Int: Record] = [:]
    private(set) var done: [[Record]]
    private let hull: Double
    private let rate = Double(Race.tickRate)
    private var gates: [Int: (left: Vec2, right: Vec2, centre: Vec2)] = [:]
    private var ownLeg: [Int]

    init(race: Race) {
        done = Array(repeating: [], count: race.boats.count)
        ownLeg = Array(repeating: -1, count: race.boats.count)
        hull = race.boatClass.hull.length
        for (leg, l) in race.course.legs.enumerated() {
            guard case .round(let index) = l, case .gate(let left, let right) = race.course.elements[index] else { continue }
            gates[leg] = (left.position, right.position, race.course.targetPosition(for: l))
        }
    }

    mutating func record(_ race: Race) {
        let up = race.course.upwind
        let tick = race.tick
        for seat in race.boats.indices {
            let boat = race.boats[seat]
            if var r = open[seat], !(boat.status == .racing && boat.legIndex == r.leg) {
                // The gate leg is over for her: which end she rounded.
                if let gate = gates[r.leg] {
                    let along = (gate.right - gate.left).normalized
                    r.rounded = (boat.position - (gate.left + gate.right) / 2).dot(along) < 0 ? 0 : 1
                    if r.complete {
                        let mark = r.rounded == 0 ? gate.left : gate.right
                        let mine = (r.crossPosition - mark).length
                        r.passedOutside = r.owingAtCross.values.contains { ($0 - mark).length <= mine - hull }
                        r.passedOutsideAny = r.owingAtCross.values.contains { ($0 - mark).length <= mine }
                        done[seat].append(r)
                    }
                }
                open[seat] = nil
            }
            guard boat.status == .racing, let gate = gates[boat.legIndex] else { continue }
            if open[seat] == nil {
                guard boat.roundingStage == 0, ownLeg[seat] != boat.legIndex else { continue }
                let rel = boat.position - gate.centre
                guard rel.length < RoundingObservation.entryRange, rel.dot(up) > RoundingObservation.gateAbove else { continue }
                ownLeg[seat] = boat.legIndex
                var r = Record(seat: seat, leg: boat.legIndex)
                r.entryTick = tick
                for other in race.boats.indices where other != seat {
                    let o = race.boats[other]
                    let d = (o.position - boat.position).length
                    if o.status == .racing, o.legIndex == boat.legIndex, o.roundingStage == 0, d < Self.packRange {
                        r.neighbours.append((other, d))
                    }
                }
                open[seat] = r
            }
            guard var r = open[seat] else { continue }
            if r.crossTick == nil {
                if boat.roundingStage >= 1 {
                    r.crossTick = tick
                    r.crossPosition = boat.position
                    for o in r.entitledOwing { r.owingAtCross[o] = race.boats[o].position }
                } else {
                    if tick % 6 == 0 {
                        for n in race.seatView(for: seat).own.markRoom where n.entitled == seat { r.entitledOwing.insert(n.owing) }
                    }
                }
            }
            if boat.shadow < Self.dirtyAir { r.dirtyTicks += 1 }
            r.dirtyMetres += (1 - boat.speedShadow(in: race.boatClass)) * boat.speed / rate
            r.shadowMin = min(r.shadowMin, boat.shadow)
            open[seat] = r
        }
    }

    /// The `PK` lines: the k-th gate observation of a seat with the k-th complete probe record of hers.
    func lines(_ cell: BotRaceCell, boats: [BoatDiagnosis]) -> String {
        var out = ""
        for seat in boats.indices {
            let gateObs = boats[seat].roundings.filter { $0.mark == .gate }
            for (k, r) in done[seat].enumerated() {
                let o = k < gateObs.count ? gateObs[k] : nil
                let e = o?.entryToEnd
                out += String(format: "PK %@:%@:%d:%d seat=%d tier=%@ leg=%d nb=%@ mark=%d ent=%d out=%d out0=%d dirtyS=%.2f dirtyM=%.2f shMin=%.2f e2em=%.1f e2es=%.1f e2eX=%.1f extra=%.1f below=%.1f over=%d\n",
                              cell.venue, cell.conditions, Int(cell.seed), cell.fleetSize, seat, "\(boats[seat].tier)", r.leg,
                              r.neighbours.map { String(format: "%d/%.1f", $0.seat, $0.metres) }.joined(separator: ","), r.rounded ?? -1,
                              r.entitledOwing.isEmpty ? 0 : 1, r.passedOutside ? 1 : 0, r.passedOutsideAny ? 1 : 0,
                              Double(r.dirtyTicks) / Double(Race.tickRate), r.dirtyMetres, r.shadowMin,
                              e?.metres ?? -1, e?.seconds ?? -1, e?.extraMetres ?? -999, o?.extraMetres ?? -999,
                              o?.belowTheLine?.seconds ?? -1, o?.overshoots == true ? 1 : 0)
            }
        }
        return out
    }
}
