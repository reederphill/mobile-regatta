// `regatta-replay freeze-ticks [--check] <fixtures folder> <table.json>` (#404): each render fixture's freeze tick
// chosen by a condition on its log, not by hand, so a fixture re-record is one command (`scripts/record-fixtures.sh`).
// For each row of the table, the log is replayed once and the first tick (every `step` ticks) meeting every condition
// the row gives is the freeze tick of each fixture the row names. Without --check each fixture's `freezeTick` is
// rewritten in place, nothing else in its file; with --check nothing is written and each row reports whether the
// committed tick is the one its condition picks. Exits 1 when a row's condition is never met (or, with --check, when a
// committed tick differs), 2 on a usage error. `--explain` rewrites nothing either: it prints what each row's committed
// frame holds (the boats racing in view and the nearest's distance; the race camera's zoom), for choosing a condition.
//
// The conditions read the core race only (no scene): where a fixture's test checks a drawn thing, its condition
// reads what draws it (a backwind wedge: a boat's `backwindSail`; a ghost: `isGhost`; a rule cue line: a rule call
// in its last 8 s; the boat camera's view: a box around your boat 2 s ahead, as `RenderFixtureTests` reads it; the
// race camera's: its settled frame on the phone's screen, `RaceCameraFrame`).
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
    /// "race": in view means drawn on the phone's screen by the race camera (`RaceCameraFrame`: course up, the heading
    /// lead, the shot's zoom), as the app draws a fixture with `"view": "courseUp"`, and `view` isn't read. Nil: the
    /// `view` box, which is the north-up boat camera's frame (a fixture with no `view`). `freeze-ticks` refuses a row
    /// whose fixtures draw the other camera, so the boats a row counts are the boats its renders show (#474).
    var camera: String?
    /// With the race camera: the points of the screen's top, bottom and each side that don't count as in view, what
    /// the HUD and controls cover and a boat's own length off the edge (default none).
    var clear: [Double]?
    /// With the race camera: its zoom inside these bounds, both included (open water 0.7, mark rounding 0.9 or
    /// wider, close quarters 1.6), so a scene's boats keep their size from one recording to the next.
    var zoom: [Double]?

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
    /// Your place in the standings (`Race.place(of:)`, from 1) inside these bounds, both included: the live leaderboard's
    /// compact lines (the leader, the boat ahead, you, the boat behind) show a gap to the leader only off first place.
    var place: [Int]?
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
    /// How many calls are in their 8 s on screen, exactly, whatever their rules: that many rule cue lines. Looser than
    /// `liveRules` where a scene wants a second line and not which rule draws it (#474: `rules-call`, where a 21.2
    /// call inside your rule 10 call's 8 s is rare before the gun).
    var liveCalls: Int?
    /// Every one of those calls is short of its fade (its last `callFadeSeconds`, `BoatStyle.ruleCallFadeSeconds`): its
    /// line and badge are drawn at full strength.
    var callsUnfaded: Bool?
    /// Both boats of every one of those calls are in view: each line is drawn end to end.
    var callsInView: Bool?
    /// The boats of those calls, any two of them, are at least this many hull lengths apart (centre to centre): past
    /// the moment of the call, where they are drawn over one another under the badge, to where each line shows between
    /// its two boats (#474).
    var callsApart: Double?
    /// One of those calls is on you, under this rule ("10": port/starboard).
    var yourCall: String?
    /// Your penalty turn: "owed" (called, not started), "turning", or "either" (its arc shows). Started is
    /// `Boat.isTakingPenalty`: 30° in, or under a `tackAndGybe` penalty (#487, fleet-rules@6) its first counting
    /// crossing made, until served.
    var yourTurn: String?
    /// Under a `tackAndGybe` penalty (#487, fleet-rules@6): the counting crossing your owed turn has made, the penalty
    /// arc's lit half (#489): "none" (owing a turn, neither made: both halves grey), "tack" or "gybe" (that one made
    /// first, the other still to come). A prediction's held second crossing never shows here: a log replays
    /// authoritative.
    var yourCrossing: String?
    /// Your offset from the groove, the autohelm's or by hand on a class whose autohelm doesn't hold (`grooveOffset`):
    /// "pinching" (inside it) or "footing" (outside it).
    var groove: String?
    /// The size of that offset in degrees, above the first and below the second: past the app's sail-cue dead band
    /// and short of the reach where it shows no cue (`BoatStyle.grooveCueDeadbandDegrees`, `grooveCueReachDegrees`),
    /// so the drawn sail lifts its luff or fills as `BoatCueTests` checks.
    var grooveDegrees: [Double]?

    static let callSeconds = 8
    static let callFadeSeconds = 1.5
    static let noClear = [0.0, 0, 0]
    static let defaultView = [402 * 1.25 / 2 / 8, 874 * 1.25 / 2 / 8]
}

enum FreezeTicks {
    struct Failure: Error, CustomStringConvertible { var description: String }

    static func main(arguments: [String]) -> Int32 {
        var arguments = arguments
        let check = arguments.contains("--check")
        let explain = arguments.contains("--explain")
        arguments.removeAll { $0 == "--check" || $0 == "--explain" }
        guard arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: regatta-replay freeze-ticks [--check | --explain] <fixtures folder> <table.json>\n".utf8))
            return 2
        }
        let folder = URL(fileURLWithPath: arguments[0])
        do {
            let rows = try JSONDecoder().decode([FreezeTickRow].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
            var status: Int32 = 0
            for row in rows {
                let name = row.fixtures.first ?? "?"
                if explain {
                    let text = try String(contentsOf: folder.appendingPathComponent(name + ".json"), encoding: .utf8)
                    let log = try RaceLog(jsonData: Data(contentsOf: folder.appendingPathComponent(row.log)))
                    print("\(name): \(try explained(row, log: log, tick: committedTick(text, name)))")
                    continue
                }
                guard let tick = try firstTick(row, log: RaceLog(jsonData: Data(contentsOf: folder.appendingPathComponent(row.log)))) else {
                    print("\(name): no tick in \(row.log) meets the condition")
                    status = 1
                    continue
                }
                for fixture in row.fixtures {
                    let url = folder.appendingPathComponent(fixture + ".json")
                    let text = try String(contentsOf: url, encoding: .utf8)
                    if let camera = try cameraMismatch(row, fixture: fixture, text: text) {
                        print("\(fixture): \(camera)")
                        status = 1
                        continue
                    }
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

    /// Why `row`'s in-view conditions don't read the camera `fixture` is drawn from, or nil when they do: the race
    /// camera for `"view": "courseUp"`, the box for the north-up boat camera (no `view`).
    static func cameraMismatch(_ row: FreezeTickRow, fixture: String, text: String) throws -> String? {
        struct Drawn: Decodable { var view: String? }
        if let camera = row.camera, camera != "race" { return "its row's camera is \"\(camera)\": only \"race\" is known" }
        let view = try JSONDecoder().decode(Drawn.self, from: Data(text.utf8)).view
        switch (row.camera, view) {
        case (nil, nil), ("race"?, "courseUp"?): return nil
        case (nil, let view?): return "drawn with \"view\": \"\(view)\", so its row needs \"camera\": \"race\""
        case (_?, let view): return "its row reads the race camera, but it's drawn with \"view\": \(view ?? "none")"
        }
    }

    /// What `row`'s frame holds at `tick` of `log`, in a line.
    static func explained(_ row: FreezeTickRow, log: RaceLog, tick: Int) throws -> String {
        var cut = log
        cut.inputs.removeAll { $0.tick > tick }
        cut.seatEvents.removeAll { $0.tick > tick }
        cut.finalTick = tick
        let race = try Replayer.replay(cut, requireMatchingVersion: false)
        let me = row.seat ?? log.header.setup.seats.firstIndex(of: .human) ?? 0
        let boat = race.boats[me]
        let hull = race.boatClass.hull.length
        let racing = race.boats.indices.filter { !race.boats[$0].isGhost && race.boats[$0].status == .racing }
        let nearest = racing.filter { $0 != me }.map { (race.boats[$0].position - boat.position).length / hull }.min() ?? .infinity
        var line = String(format: "tick %d, leg %d, place %d, %.1f m/s, nearest %.1f hulls", tick, boat.legIndex,
                          race.place(of: me), boat.velocity.length, nearest)
        let view = row.view ?? FreezeTickRow.defaultView
        let centre = boat.position + boat.velocity * 2
        let boxed = racing.filter { abs(race.boats[$0].position.x - centre.x) < view[0] && abs(race.boats[$0].position.y - centre.y) < view[1] }
        line += "; racing in the box \(boxed.count)"
        let frame = RaceCameraFrame(race, me: me)
        let clear = row.clear.flatMap { $0.count == 3 ? $0 : nil } ?? FreezeTickRow.noClear
        return line + String(format: "; race camera zoom %.2f, racing on screen %d (clear of the HUD %d)", frame.zoom,
                             racing.filter { frame.shows(race.boats[$0].position, clear: FreezeTickRow.noClear) }.count,
                             racing.filter { frame.shows(race.boats[$0].position, clear: clear) }.count)
    }

    /// The first tick of `log`, every `row.step` ticks, meeting the row's conditions, or nil.
    static func firstTick(_ row: FreezeTickRow, log: RaceLog) throws -> Int? {
        var scan = Scan([row], setup: log.header.setup)
        _ = try Replayer.replay(log, requireMatchingVersion: false) { scan.observe($0) }
        return scan.found[0]
    }

    /// Rows' conditions read tick by tick as a race sails or replays (`observe` once at its first tick and after each
    /// step): what each row needs from the race so far (the calls, the first finish), and the first tick each row meets.
    /// The replay above and the recorder (`RecordFixture`) read a race the same way, so a recorded log replays to the
    /// ticks its recording found.
    struct Scan {
        let rows: [FreezeTickRow]
        let seats: [Int]
        private(set) var found: [Int?]
        private(set) var calls: [RuleCall] = []
        private var firstFinish = false

        init(_ rows: [FreezeTickRow], setup: RaceSetup) {
            self.rows = rows
            seats = rows.map { $0.seat ?? setup.seats.firstIndex(of: .human) ?? 0 }
            found = rows.map { _ in nil }
        }

        var allFound: Bool { found.allSatisfy { $0 != nil } }

        /// Drains the race's events: nothing else may drain them while a scan reads the race.
        mutating func observe(_ race: Race) {
            for event in race.drainEvents() {
                switch event.kind {
                case .ruleCall(let call): calls.append(call)
                case .firstFinish: firstFinish = true
                default: break
                }
            }
            for (index, row) in rows.enumerated() where found[index] == nil && race.tick % (row.step ?? 10) == 0 {
                if FreezeTicks.meets(row, race, me: seats[index], view: row.view ?? FreezeTickRow.defaultView, calls: calls,
                                     firstFinish: firstFinish) {
                    found[index] = race.tick
                }
            }
        }

        /// Whether a row still unmet can no longer be met: its seat has sailed past the leg it wants, or is a ghost
        /// where the row wants her racing or on a leg.
        func isHopeless(_ race: Race) -> Bool {
            rows.indices.contains { index in
                guard found[index] == nil else { return false }
                let boat = race.boats[seats[index]]
                if let leg = rows[index].leg, boat.legIndex > leg { return true }
                return boat.isGhost && (rows[index].leg != nil || rows[index].racing == true)
            }
        }
    }

    static func meets(_ row: FreezeTickRow, _ race: Race, me: Int, view: [Double], calls: [RuleCall],
                      firstFinish: Bool) -> Bool {
        let boat = race.boats[me]
        if let leg = row.leg, boat.legIndex != leg { return false }
        if let racing = row.racing, (boat.status == .racing) != racing { return false }
        if let after = row.afterFirstFinish, (firstFinish && !race.isOver) != after { return false }

        // In view: on the race camera's screen, or in the boat camera's box.
        let shows: (Vec2) -> Bool
        if row.camera != nil {
            let frame = RaceCameraFrame(race, me: me)
            if let zoom = row.zoom, zoom.count == 2, !(zoom[0]...zoom[1]).contains(frame.zoom) { return false }
            let clear = row.clear.flatMap { $0.count == 3 ? $0 : nil } ?? FreezeTickRow.noClear
            shows = { frame.shows($0, clear: clear) }
        } else {
            let centre = boat.position + boat.velocity * 2
            shows = { abs($0.x - centre.x) < view[0] && abs($0.y - centre.y) < view[1] }
        }
        let inView = race.boats.indices.filter { shows(race.boats[$0].position) }
        if let markInView = row.markInView {
            guard race.course.legs.indices.contains(boat.legIndex) else { return false }
            if shows(race.course.targetPosition(for: race.course.legs[boat.legIndex])) != markInView { return false }
        }
        if let n = row.ghostsInView, inView.filter({ race.boats[$0].isGhost }).count < n { return false }
        if let n = row.racingInView, inView.filter({ !race.boats[$0].isGhost && race.boats[$0].status == .racing }).count < n {
            return false
        }
        if let bounds = row.place, bounds.count == 2, !(bounds[0]...bounds[1]).contains(race.place(of: me)) { return false }
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
        if let count = row.liveCalls, live.count != count { return false }
        if row.callsUnfaded == true {
            let fading = Double(FreezeTickRow.callSeconds) - FreezeTickRow.callFadeSeconds
            if live.contains(where: { Double(race.tick - $0.tick) >= fading * Double(Race.tickRate) }) { return false }
        }
        if row.callsInView == true,
           live.contains(where: { !shows(race.boats[$0.offender].position) || !shows(race.boats[$0.victim].position) }) {
            return false
        }
        if let hulls = row.callsApart {
            let called = Set(live.flatMap { [$0.offender, $0.victim] }).sorted()
            let apart = hulls * race.boatClass.hull.length
            for (index, a) in called.enumerated() {
                if called[(index + 1)...].contains(where: { (race.boats[$0].position - race.boats[a].position).length < apart }) {
                    return false
                }
            }
        }
        if let rule = row.yourCall, !live.contains(where: { $0.offender == me && $0.rule.rawValue == rule }) { return false }

        switch row.yourTurn {
        case nil: break
        case "owed": if boat.penaltyTurnsOwed == 0 || boat.isTakingPenalty { return false }
        case "turning": if !boat.isTakingPenalty { return false }
        case "either": if boat.penaltyTurnsOwed == 0 && !boat.isTakingPenalty { return false }
        default: return false
        }
        switch row.yourCrossing {
        case nil: break
        case "none": if boat.penaltyTurnsOwed == 0 || boat.penaltyFirstCrossing != nil { return false }
        case "tack": if boat.penaltyTurnsOwed == 0 || boat.penaltyFirstCrossing != .tack { return false }
        case "gybe": if boat.penaltyTurnsOwed == 0 || boat.penaltyFirstCrossing != .gybe { return false }
        default: return false
        }
        switch row.groove {
        case nil: break
        case let groove?:
            guard let offset = grooveOffset(boat, in: race.boatClass) else { return false }
            if (groove == "pinching") != (offset < 0) || offset == 0 { return false }
            if let range = row.grooveDegrees, range.count == 2,
               !(range[0] < abs(offset) * 180 / .pi && abs(offset) * 180 / .pi < range[1]) {
                return false
            }
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
