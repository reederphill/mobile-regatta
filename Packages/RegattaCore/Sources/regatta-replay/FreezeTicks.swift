// `regatta-replay freeze-ticks [--check] <fixtures folder> <table.json>` (#404): each render fixture's freeze tick
// chosen by a condition on its log, not by hand, so a fixture re-record is one command (`scripts/record-fixtures.sh`).
// For each row of the table, the log is replayed once and the first tick (every `step` ticks) meeting every condition
// the row gives is the freeze tick of each fixture the row names. Without --check each fixture's `freezeTick` is
// rewritten in place, nothing else in its file; with --check nothing is written and each row reports whether the
// committed tick is the one its condition picks. Exits 1 when a row's condition is never met (or, with --check, when a
// committed tick differs), 2 on a usage error.
//
// The conditions read the core race only (no scene): where a fixture's test checks a drawn thing, its condition
// reads what draws it (a backwind wedge: a boat's `backwindSail`; a ghost: `isGhost`; a rule cue line: a rule call
// in its last 8 s; the boat camera's view: a box around your boat 2 s ahead, as `RenderFixtureTests` reads it).
import Foundation
import RegattaCore

struct FreezeTickRow: Decodable {
    /// The fixtures (their JSON's names, without `.json`) frozen on the tick this row picks: a fixture and its twins.
    var fixtures: [String]
    var log: String
    /// Whose view: the fixture HUD's seat, or the log's human seat when nil.
    var seat: Int?
    /// Ticks between candidates, from a multiple of it (default 10).
    var step: Int?
    /// The view box's half extents in metres, centred 2 s ahead of your boat (default the boat camera's at an iPhone
    /// 402 x 874 pt screen, 1.25 times over, 8 pt a metre, as `RenderFixtureTests.fleetFixtureShowsAGhostAmongTheFleet`).
    var view: [Double]?

    // The conditions: each one given must hold.
    /// Your leg (0: the first beat).
    var leg: Int?
    /// You are racing (started, not finished).
    var racing: Bool?
    /// A boat has finished and the race hasn't closed.
    var afterFirstFinish: Bool?
    /// At least this many ghosts (finished boats) in view.
    var ghostsInView: Int?
    /// At least this many boats racing in view, you among them.
    var racingInView: Int?
    /// At least this many boats in view casting a backwind wedge at half strength or more: sailing upwind, sail working.
    /// As the app draws it (`BoatEffects`): not a ghost, her cone's presence (none running, less across a reach) times
    /// the class's floor factor times her sail's backwind level (#437: a downwind leg after the first finish has none).
    var sailsWorkingInView: Int?
    /// The right-of-way glows you see in glow range (`RightOfWayGlyph`, #123), each of these kinds at least once:
    /// "giveWay" (red, you keep clear), "hasRight" (green).
    var glows: [String]?
    /// Whether the mark you sail for is in view (false: the edge arrow points at it, as the cue fixtures want).
    var markInView: Bool?
    /// The rules of the calls in their 8 s on screen, newest first, exactly (`RuleCalls.active(... seconds: 8 ...)`'s
    /// badges: one rule cue line each).
    var liveRules: [String]?
    /// One of those calls is on you, under this rule ("10": port/starboard).
    var yourCall: String?
    /// Your penalty turn: "owed" (called, not started), "turning", or "either" (its arc shows).
    var yourTurn: String?
    /// Your offset from the groove, the autohelm's or by hand on a class whose autohelm doesn't hold (`grooveOffset`):
    /// "pinching" (inside it) or "footing" (outside it).
    var groove: String?

    static let callSeconds = 8
    static let defaultView = [402 * 1.25 / 2 / 8, 874 * 1.25 / 2 / 8]
}

enum FreezeTicks {
    struct Failure: Error, CustomStringConvertible { var description: String }

    static func main(arguments: [String]) -> Int32 {
        var arguments = arguments
        let check = arguments.contains("--check")
        arguments.removeAll { $0 == "--check" }
        guard arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: regatta-replay freeze-ticks [--check] <fixtures folder> <table.json>\n".utf8))
            return 2
        }
        let folder = URL(fileURLWithPath: arguments[0])
        do {
            let rows = try JSONDecoder().decode([FreezeTickRow].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
            var status: Int32 = 0
            for row in rows {
                let name = row.fixtures.first ?? "?"
                guard let tick = try firstTick(row, log: RaceLog(jsonData: Data(contentsOf: folder.appendingPathComponent(row.log)))) else {
                    print("\(name): no tick in \(row.log) meets the condition")
                    status = 1
                    continue
                }
                for fixture in row.fixtures {
                    let url = folder.appendingPathComponent(fixture + ".json")
                    let text = try String(contentsOf: url, encoding: .utf8)
                    let committed = try committedTick(text, fixture)
                    if committed == tick {
                        print("\(fixture): \(tick)")
                    } else if check {
                        print("\(fixture): committed \(committed), the condition picks \(tick)")
                        status = 1
                    } else {
                        try rewritten(text, tick).write(to: url, atomically: true, encoding: .utf8)
                        print("\(fixture): \(committed) -> \(tick)")
                    }
                }
            }
            return status
        } catch {
            FileHandle.standardError.write(Data("regatta-replay: \(error)\n".utf8))
            return 1
        }
    }

    /// The first tick of `log`, every `row.step` ticks, meeting the row's conditions, or nil.
    static func firstTick(_ row: FreezeTickRow, log: RaceLog) throws -> Int? {
        let me = row.seat ?? log.header.setup.seats.firstIndex(of: .human) ?? 0
        let step = row.step ?? 10
        let view = row.view ?? FreezeTickRow.defaultView
        var calls: [RuleCall] = []
        var firstFinish = false
        var found: Int?
        _ = try Replayer.replay(log, requireMatchingVersion: false) { race in
            for event in race.drainEvents() {
                switch event.kind {
                case .ruleCall(let call): calls.append(call)
                case .firstFinish: firstFinish = true
                default: break
                }
            }
            guard found == nil, race.tick % step == 0 else { return }
            if meets(row, race, me: me, view: view, calls: calls, firstFinish: firstFinish) { found = race.tick }
        }
        return found
    }

    static func meets(_ row: FreezeTickRow, _ race: Race, me: Int, view: [Double], calls: [RuleCall],
                      firstFinish: Bool) -> Bool {
        let boat = race.boats[me]
        if let leg = row.leg, boat.legIndex != leg { return false }
        if let racing = row.racing, (boat.status == .racing) != racing { return false }
        if let after = row.afterFirstFinish, (firstFinish && !race.isOver) != after { return false }

        let centre = boat.position + boat.velocity * 2
        let inView = race.boats.indices.filter { seat in
            let p = race.boats[seat].position
            return abs(p.x - centre.x) < view[0] && abs(p.y - centre.y) < view[1]
        }
        if let markInView = row.markInView {
            guard race.course.legs.indices.contains(boat.legIndex) else { return false }
            let mark = race.course.targetPosition(for: race.course.legs[boat.legIndex])
            if (abs(mark.x - centre.x) < view[0] && abs(mark.y - centre.y) < view[1]) != markInView { return false }
        }
        if let n = row.ghostsInView, inView.filter({ race.boats[$0].isGhost }).count < n { return false }
        if let n = row.racingInView, inView.filter({ !race.boats[$0].isGhost && race.boats[$0].status == .racing }).count < n {
            return false
        }
        if let n = row.sailsWorkingInView, inView.filter({ wedgePresence(race, seat: $0) >= 0.5 }).count < n { return false }
        if let kinds = row.glows {
            guard !boat.isGhost else { return false }
            let relations = race.keepClearRelations(of: me)
            let shown = race.boats.indices.compactMap { seat -> String? in
                guard seat != me, relations.indices.contains(seat),
                      RightOfWayGlyph.isInRange(boat.position, race.boats[seat].position,
                                                rangeHulls: RightOfWayGlyph.defaultRangeHulls,
                                                hullLength: race.boatClass.hull.length) else { return nil }
                return RightOfWayGlyph.glyph(for: relations[seat], me: me).map { "\($0)" }
            }
            if !kinds.allSatisfy(shown.contains) { return false }
        }

        let live = calls.filter { race.tick - $0.tick < FreezeTickRow.callSeconds * Race.tickRate }
        if let rules = row.liveRules, live.reversed().map(\.rule.rawValue) != rules { return false }
        if let rule = row.yourCall, !live.contains(where: { $0.offender == me && $0.rule.rawValue == rule }) { return false }

        switch row.yourTurn {
        case nil: break
        case "owed": if boat.penaltyTurnsOwed == 0 || boat.isTakingPenalty { return false }
        case "turning": if !boat.isTakingPenalty { return false }
        case "either": if boat.penaltyTurnsOwed == 0 && !boat.isTakingPenalty { return false }
        default: return false
        }
        switch row.groove {
        case nil: break
        case let groove?:
            guard let offset = grooveOffset(boat, in: race.boatClass) else { return false }
            if (groove == "pinching") != (offset < 0) || offset == 0 { return false }
        }
        return true
    }

    /// The strength of `seat`'s backwind wedge as the app draws it (`BoatEffects`), 0...1: none for a ghost.
    static func wedgePresence(_ race: Race, seat: Int) -> Double {
        let boat = race.boats[seat]
        guard !boat.isGhost else { return 0 }
        let cone = ShadowCone(apex: boat.position, apparentWindDirection: boat.apparentWind.direction, heading: boat.heading,
                              windwardSide: boat.tack, shadow: race.boatClass.windShadow, trueWindAngle: boat.twa,
                              speed: boat.speedThroughWater)
        return cone.backwindPresence * race.boatClass.windShadow.backwindFloorFactor(speed: boat.speedThroughWater)
            * race.backwindSail(ofSeat: seat).clamped(to: 0...1)
    }

    /// Her offset from the groove as the vane and sail cues read it: the autohelm's while it has her, or on a class
    /// whose autohelm doesn't hold a centred rudder (#437's skiff@7), her own sailing angle off the groove of the wind
    /// she is in (the app's `HandSteering`). Nil otherwise.
    static func grooveOffset(_ boat: Boat, in boatClass: BoatClass) -> Double? {
        if let reading = boat.autohelmReading(in: boatClass) { return reading.offsetFromGroove }
        guard !boatClass.steering.autohelm.holdsWhenCentred else { return nil }
        let groove: Autohelm.Groove = abs(boat.sailingAngle) < .pi / 2 ? .upwind : .downwind
        let angle = Autohelm.grooveAngle(groove, tws: boat.grooveWindSpeed(in: boatClass), boatClass: boatClass)
        return wrapAngle(boat.sailingAngle - angle)
    }

    static func committedTick(_ text: String, _ fixture: String) throws -> Int {
        guard let range = text.range(of: #""freezeTick"\s*:\s*-?[0-9]+"#, options: .regularExpression),
              let tick = Int(text[range].split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) else {
            throw Failure(description: "\(fixture).json has no freezeTick")
        }
        return tick
    }

    static func rewritten(_ text: String, _ tick: Int) -> String {
        // Only the number: the file keeps its own spacing.
        text.replacingOccurrences(of: #"("freezeTick"\s*:\s*)-?[0-9]+"#, with: "$1\(tick)", options: .regularExpression)
    }
}
