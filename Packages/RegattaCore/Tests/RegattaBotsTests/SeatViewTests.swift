import Foundation
import Testing
import RegattaCore
@testable import RegattaBots

/// #98: a bot sees a race only through its seat's `SeatView`, which holds only what a player in that seat
/// can see now (#19, #10, #15): the wind as it is now and never a key (ADR 0001), and nothing of another
/// boat's input, the umpire's records or anyone's name.
@Suite struct SeatViewTests {
    /// Two keys-only races holding every key from the start, the same through window k and different
    /// after it: until the wind of window k + 1 reaches the present, every seat's view is the same in both,
    /// and so is every bot's input. The keys past the present, there all along, change nothing.
    @Test func botInputsIgnoreKeysPastThePresent() throws {
        let setup = try RaceSetup(raceSeed: RaceSeed(98), seats: Array(repeating: .bot, count: 8), laps: 1,
                                  startSequenceTicks: 45 * Race.tickRate)
        let probe = Race(setup: setup, windSeed: WindSeed(1))
        let windows = probe.wind.windows
        // Window k is the one after the gun's; both races hold keys through `last`.
        let k = windows.window(containing: 0) + 1
        let last = k + 4
        func keys(_ seed: UInt64) throws -> [WindKey] {
            var generator = try WindKeyGenerator(windSeed: WindSeed(seed), setup: probe.windSetup, windows: windows)
            return generator.keys(through: last)
        }
        let (mine, theirs) = (try keys(1), try keys(2))
        #expect(mine[k + 1] != theirs[k + 1])
        let a = Race(setup: setup, revealedWindKeys: mine)
        let b = Race(setup: setup, revealedWindKeys: Array(mine[...k]) + Array(theirs[(k + 1)...]))
        #expect(a.wind.keys.endWindow == b.wind.keys.endWindow && a.wind.keys.endWindow > windows.window(containing: a.tick) + 4)

        var driversA = setup.seats.indices.map { BotDriver(seat: $0, raceSeed: setup.raceSeed) }
        var driversB = driversA
        var diverged: Int?
        var decisions = 0
        while a.tick < windows.start(of: last) {
            guard a.boats.indices.allSatisfy({ a.seatView(for: $0) == b.seatView(for: $0) }) else {
                diverged = a.tick
                break
            }
            for seat in driversA.indices {
                let decision = driversA[seat].drive(a)
                #expect(decision == driversB[seat].drive(b), "seat \(seat) decided differently at tick \(a.tick)")
                if decision != nil { decisions += 1 }
            }
            try a.tryStep()
            try b.tryStep()
        }
        let divergence = try #require(diverged, "the keys after window \(k) never reached a view")
        #expect(divergence >= windows.start(of: k + 1), "a view showed window \(k + 1)'s wind at tick \(divergence), before it began")
        #expect(decisions > 3_000)
        #expect(a.boats.contains { $0.status == .racing })
    }

    /// A node of a value's reflection: where it is, its label, and its type.
    struct Node {
        let path: String
        let label: String
        let type: String
    }

    /// Every stored field under `value`, depth first, with the first few elements of each collection
    /// (their type is in the collection's, even when it's empty). Enum payloads and optionals included.
    static func fields(of value: Any, path: String = "view", label: String = "view", depth: Int = 0) -> [Node] {
        let mirror = Mirror(reflecting: value)
        var nodes = [Node(path: path, label: label, type: String(describing: mirror.subjectType))]
        guard depth < 16 else { return nodes }
        let children = mirror.displayStyle == .collection ? Array(mirror.children.prefix(3)) : Array(mirror.children)
        for (index, child) in children.enumerated() {
            let name = child.label ?? "[\(index)]"
            nodes += fields(of: child.value, path: "\(path).\(name)", label: name, depth: depth + 1)
        }
        return nodes
    }

    /// Types that carry another boat's input, the umpire's records and memory, names, the keys or the
    /// whole world: a view holds none of them, however deep.
    static let forbiddenTypes = #"\b(?:Race|Boat|BoatInput|BoatTap|InputRecord|RaceLog|WorldSnapshot|Seat|Incident|IncidentIndex|UmpireState|OverlapTracker|FleetRoster|WindField|WindKeyChain|WindKey|WindSeed)\b"#
    /// Field names for the same, anywhere in a view.
    static let forbiddenLabels: Set = [
        "heldInput", "heldInputs", "input", "desiredRudder", "incidents", "incident", "incidentId", "umpire",
        "fouls", "openIncidents", "rule18", "exonerated", "overlaps", "keys", "windKeys", "windSeed",
        "sailingName", "handle", "isPlayer", "isBot", "roster",
    ]

    static func violations(in value: Any) throws -> [String] {
        let types = try Regex(forbiddenTypes).wordBoundaryKind(.simple)
        return fields(of: value).compactMap { node in
            if node.type.contains(types) { return "\(node.path): \(node.type)" }
            if forbiddenLabels.contains(node.label) { return "\(node.path)" }
            return nil
        }
    }

    /// A bot's view of a race with players and bots, held inputs, a rule call and a named roster: no field
    /// for another boat's input, rule 18 records or incident memory, or anyone's name. Another boat shows
    /// only what is drawn of her, and the race's own world snapshot, which has all of these, fails the scan.
    @Test func noFieldForHeldInputsRule18RecordsOrNames() throws {
        let race = botRace(seats: [.human, .bot, .human] + Array(repeating: .bot, count: 9), seed: 98)
        var controllers = SeatControllers(setup: race.setup)
        var views: [SeatView] = []
        for step in 0..<(900 * Race.tickRate) where !race.isOver {
            if step % 60 == 0 {
                for seat in [0, 2] { race.apply(BoatInput(rudder: Int8(step % 7 * 20 - 60), ease: step % 120 == 0), seat: seat, atTick: race.tick + 1) }
            }
            controllers.drive(race)
            race.step()
            if step % 300 == 0 || (views.allSatisfy(\.ruleCallLines.isEmpty) && race.incidents.count > 0) {
                views.append(race.seatView(for: 1))
            }
        }
        #expect(views.contains { !$0.ruleCallLines.isEmpty }, "a rule call was on show")
        #expect(views.contains { $0.own.autohelm != nil } && views.contains { $0.laylines != nil })

        for view in views {
            let hits = try Self.violations(in: view)
            #expect(hits == [], "\(hits.joined(separator: "\n"))")
            // Nor any name for a boat: her seat is all that tells her from another.
            let named = Self.fields(of: view).filter {
                ($0.path.hasPrefix("view.own") || $0.path.hasPrefix("view.others") || $0.path.hasPrefix("view.ruleCallLines"))
                    && $0.label.lowercased().contains("name")
            }
            #expect(named.map(\.path) == [])
        }
        let view = try #require(views.last)
        #expect(view.others.count == race.boats.count - 1 && !view.others.contains { $0.seat == view.seat })
        let other = Self.fields(of: view.others[0]).filter { $0.path.split(separator: ".").count == 2 }.map(\.label)
        #expect(other == ["seat", "position", "heading", "speed", "boomSide", "isGhost", "rightOfWay"])

        // The scan sees them where they are.
        let snapshot = try Self.violations(in: race.exportSnapshot())
        #expect(snapshot.contains { $0.contains(".heldInput") } && snapshot.contains { $0.contains(": IncidentIndex") })
        #expect(snapshot.contains { $0.contains(": WindKeyChain") })
        #expect(try !Self.violations(in: FleetRoster(setup: race.setup)).isEmpty)
    }

    /// The view is the race for its seat as it stands: her boat, her relation to each other boat, her place,
    /// her laylines as the scene draws them, the rule calls on show, and her mark's zone and the mark-room notices
    /// told her (#101), each rule 18 record naming her while it lasts.
    @Test func aSeatSeesItsBoatAndItsRelationsAsTheRaceHasThem() throws {
        let race = botRace(seed: 3)
        var controllers = allBots(race)
        var checked = 0
        var inZones = 0
        var notices = 0
        sail(race, &controllers, ticks: 1_500 * Race.tickRate) { race in
            guard race.tick % 97 == 0 else { return }
            let standings = race.standings()
            for seat in race.boats.indices {
                let view = race.seatView(for: seat)
                let boat = race.boats[seat]
                #expect(view.seat == seat && view.tick == race.tick && view.time == race.time)
                #expect(view.place == standings.firstIndex(of: seat)! + 1)
                #expect(view.fleetSize == race.boats.count)
                #expect(view.own.position == boat.position && view.own.heading == boat.heading && view.own.speed == boat.speed)
                #expect(view.own.velocity == boat.velocity && view.own.twa == boat.twa && view.own.tack == boat.tack)
                #expect(view.own.windOverGround == boat.windOverGround && view.own.sailingWind == boat.sailingWind)
                #expect(view.own.ease == race.heldInputs[seat].ease)
                #expect(view.own.autohelm == boat.autohelmReading(in: race.boatClass))
                #expect(view.own.penalty == race.owedPenalty(ofSeat: seat))
                let zone = race.course.markZone(of: boat, hull: boat.hull(outline: race.boatClass.hull.outline))
                #expect(view.own.zone?.mark == zone?.mark.position && view.own.zone?.side == zone?.side
                        && view.own.zone?.distance == zone?.distance && view.own.zone?.isIn == zone?.isIn)
                if view.own.zone?.isIn == true { inZones += 1 }
                let records = race.boats.indices.filter { $0 != seat }.compactMap { race.umpire?.markRoom(SeatPair(seat, $0)) }
                #expect(view.own.markRoom == records.map {
                    SeatView.MarkRoomNotice(entitled: $0.entitled, owing: $0.owing, rule: $0.rule)
                })
                #expect(view.own.markRoom.allSatisfy { $0.entitled == seat || $0.owing == seat })
                notices += view.own.markRoom.count
                for other in view.others {
                    #expect(other.rightOfWay == race.rightOfWay(seat, other.seat))
                    #expect(other.velocity == race.boats[other.seat].velocity && other.isGhost == race.isGhost(seat: other.seat))
                }
                #expect(view.shadowCones == race.boats.indices.compactMap(race.shadowCone(ofSeat:)))
                let leg = race.course.legSailed(status: boat.status, legIndex: boat.legIndex)
                let mark = race.course.targetPosition(for: leg)
                if let laylines = view.laylines {
                    let wind = race.groundWind(at: mark)
                    let best = laylines.groove == .upwind ? race.boatClass.polar.bestUpwind(tws: wind.speed)
                        : race.boatClass.polar.bestDownwind(tws: wind.speed)
                    #expect(laylines.mark == mark && laylines.starboardHeading == wind.direction - best.twa
                            && laylines.portHeading == wind.direction + best.twa)
                } else {
                    #expect(leg == .finish || leg == .round(CourseLayout.offsetIndex))
                }
                #expect(view.finishWindowRemaining == race.firstFinishTime.map { _ in Double(race.closeTick - race.tick) / 30 })
                checked += 1
            }
            let window = RulesConfig.ticks(race.rules.raceFormat.penalty.complete)
            let shown = race.incidents.incidents.compactMap { incident -> RuleCall? in
                if case .called(let call) = incident.outcome, call.tick + window >= race.tick { call } else { nil }
            }
            #expect(race.seatView(for: 0).ruleCallLines.map(\.tick) == shown.map(\.tick))
        }
        #expect(checked > 500)
        #expect(inZones > 0 && notices > 0, "boats were in a mark's zone (\(inZones)) and told of mark-room (\(notices))")
        #expect(race.firstFinishTime != nil, "the finish window opened")
    }
}
