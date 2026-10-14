import Foundation
import Testing
import RegattaCore
@testable import RegattaBots

/// #518: the leg to the leeward gate before she is through it (`BotBrain.gateAim`). She picks her mark from 80 m above
/// the line and sails for her point inside it, straight for it on the gybe that rounds it in one luff; below the line
/// and not through it she sails back above it round the nearer end.
@Suite struct BotGateTests {
    /// What a pose is laid out by: the gate, the wind where she was last placed and her downwind groove in it.
    struct Bearings {
        var gate: BotBrain.Gate
        /// Upwind along the course's axis, and her point inside each mark.
        var up: Vec2
        var leftEntry: Vec2
        var rightEntry: Vec2
        /// The wind's direction where she is, and her downwind groove's angle off it.
        var wind: Double
        var down: Double
        /// The gybe that rounds the left mark in one luff (`BotBrain.roundingTack`); the right mark's is the other.
        var leftRounds: Tack

        func entry(left: Bool) -> Vec2 { left ? leftEntry : rightEntry }
        /// Whether the mark `tack` rounds in one luff is the left one.
        func rounded(on tack: Tack) -> Bool { tack == leftRounds }
        /// Outwards along the line from the gate's centre past a mark.
        func outwards(left: Bool) -> Vec2 { (gate.mark(left: left).position - gate.centre).normalized }
        func heading(_ tack: Tack, _ angle: Double) -> Double { tack == .starboard ? wind - angle : wind + angle }
        /// Metres above the gate's line.
        func above(_ position: Vec2) -> Double { up.dot(position - gate.centre) }

        /// Where the course to a mark's point is `deeper` radians deeper than her groove on `tack`, `above` metres
        /// above the line (or, with `out`, that many metres from the point): she lays it at 0.
        func laying(left: Bool, on tack: Tack, above: Double? = nil, out: Double? = nil, deeper: Double = 0) -> Vec2 {
            let course = Vec2.heading(heading(tack, down + deeper))
            let metres = out ?? ((above ?? 0) + BotBrain.gateDepth) / -up.dot(course)
            return entry(left: left) - course * metres
        }
    }

    /// Seat 0 alone on the leg to the gate, yet to cross its line, a groove-only bot (the baseline's tactics, no
    /// weaknesses, her laylines judged true) turning by hand at her best; seat 1 far off.
    struct Scene {
        let race: Race
        var hand: BotHandTackTests.Hand
        var bearings: Bearings

        var boat: Boat { race.boats[0] }
        var gate: BotBrain.Gate { bearings.gate }

        /// The decision's view for her seat, taken in as her brain takes it in.
        mutating func seen() -> SeatView {
            let view = hand.helm.view(race.seatView(for: 0))
            hand.brain.observe(view.own, view)
            return view
        }

        /// Her aim on the leg to the gate now, with what it leaves in her brain.
        mutating func aim() -> Aim? {
            let view = seen()
            return hand.brain.gateAim(view.own, view)
        }

        /// What each mark costs her now.
        mutating func costs() throws -> (left: Double, right: Double) {
            let view = seen()
            return try #require(hand.brain.gateCosts(view.own, view))
        }

        /// Sails her for `seconds` or until `until`: `each` after every step, with the seconds sailed.
        mutating func sail(seconds: Double, until: (Race) -> Bool = { _ in false }, each: (Race, Double) -> Void = { _, _ in }) {
            for tick in 1...Int(seconds * Double(Race.tickRate)) {
                hand.drive(race)
                race.step()
                each(race, Double(tick) / Double(Race.tickRate))
                if until(race) { return }
            }
        }
    }

    /// The scene with her running on `tack` in her groove at her target speed, on the plane with the spinnaker up,
    /// where `pose` puts her. The wind bends over the water, so she is posed by the wind where she is, thrice over.
    static func scene(seed: UInt64 = 3, tack: Tack, heading: ((Bearings) -> Double)? = nil,
                      pose: (Bearings) -> Vec2) throws -> Scene {
        let water = BotConductTests.Water(seed: seed, running: true)
        let course = water.race.course
        let leg = course.legs[water.leg]
        guard case .round(let index) = leg, case .gate(let left, let right) = course.elements[index] else {
            throw Missing.gate
        }
        var bearings: Bearings?
        var posed: Scene?
        for _ in 0..<4 {
            let position = bearings.map(pose) ?? course.targetPosition(for: leg) + course.upwind * 60
            let facing = bearings.map { heading?($0) ?? $0.heading(tack, $0.down) } ?? water.run(tack)
            try #require(course.isInRaceArea(position), "posed off the race area")
            let race = try BotConductTests.place(water, [
                .init(position: position, heading: facing, speed: water.down.speed),
                .init(position: water.centre + Vec2.heading(water.wind).rightPerp * 400, heading: water.run(.starboard),
                      speed: water.down.speed),
            ]) { snapshot in
                // The start the water was stepped through may have left her a penalty: she owes none.
                snapshot.seats[0].boat.penaltyTurnsOwed = 0
                snapshot.seats[0].boat.penaltyProgress = 0
                snapshot.seats[0].boat.penaltyClockTick = nil
                snapshot.seats[0].boat.isPlaning = true
                snapshot.seats[0].boat.spinnaker = .up
            }
            var hand = BotHandTackTests.Hand(seat: 0, race: race, handling: 1)
            hand.brain.senses.planing = true
            // She judges her laylines true: `navigate` gybes her onto her point's.
            hand.brain.laylineError = (water.leg, 0)
            let view = hand.helm.view(race.seatView(for: 0))
            hand.brain.observe(view.own, view)
            let gate = try #require(BotBrain.gate(of: view.own, view))
            #expect(gate.left.position == left.position && gate.right.position == right.position)
            let now = Bearings(gate: gate, up: course.upwind,
                               leftEntry: BotBrain.gateEntry(gate.left, centre: gate.centre, view),
                               rightEntry: BotBrain.gateEntry(gate.right, centre: gate.centre, view),
                               wind: view.own.windDirection, down: hand.brain.grooveAngle(.downwind, view.own, view),
                               leftRounds: BotBrain.roundingTack(gate.left, centre: gate.centre, view.own, view))
            #expect(BotBrain.roundingTack(gate.right, centre: gate.centre, view.own, view) == now.leftRounds.other)
            posed = bearings == nil ? nil : Scene(race: race, hand: hand, bearings: now)
            bearings = now
        }
        let scene = try #require(posed)
        try #require(scene.boat.tack == tack && scene.boat.roundingStage == 0)
        return scene
    }

    enum Missing: Error { case gate }

    /// One tick of a scene sailed.
    struct Tick {
        var time: Double
        var position: Vec2
        var boom: BoomSide
        var leg: Int
        var stage: Int
        /// Her angle off the wind where she is, radians.
        var offWind: Double
        var pick: Bool?
        var recovering: Bool
        var planned: Tack
    }

    /// The ticks at which her boom crossed.
    static func gybes(_ ticks: [Tick], from boom: BoomSide) -> [Double] {
        var side = boom
        return ticks.compactMap { tick in
            defer { side = tick.boom }
            return tick.boom != side ? tick.time : nil
        }
    }

    /// #518 acceptance: from 80 m above the line, on either gybe, she picks the mark her gybe rounds in one luff when
    /// she lays its point: laying it in her groove, with it 6° deeper than her groove (from nearer that mark's side),
    /// and reaching for it 8° above her groove (from the far side, beyond the other mark). The other mark, the nearer
    /// in metres or nearly so, costs her a gybe more, and that is more than she changes her mind for.
    @Test func picksTheMarkSheRoundsInOneLuff() throws {
        for tack in [Tack.starboard, .port] {
            for deeper in [0, deg2rad(6), -deg2rad(8)] {
                let name = "\(tack), her point \(rad2deg(deeper))° deeper than her groove"
                var scene = try Self.scene(tack: tack) {
                    $0.laying(left: $0.rounded(on: tack), on: tack, above: BotBrain.gatePickRange - 1, deeper: deeper)
                }
                let left = scene.bearings.rounded(on: tack)
                let costs = try scene.costs()
                let (hers, other) = left ? (costs.left, costs.right) : (costs.right, costs.left)
                #expect(hers + BotBrain.gateRepickMetres < other, "\(name): costs \(costs)")
                let view = scene.seen()
                #expect(BotBrain.roundingTack(scene.gate.mark(left: left), centre: scene.gate.centre, view.own, view) == tack)
                let aimAsked = scene.aim()
                let aim = try #require(aimAsked, "\(name)")
                let pick = try #require(scene.hand.brain.gatePick, "\(name)")
                #expect(pick.leg == scene.boat.legIndex && pick.left == left, "\(name): picked \(pick)")
                // And she sails for it on the gybe she is on.
                #expect(aim.tack == tack && scene.hand.brain.plannedTack == tack, "\(name)")
            }
        }
        // A metre higher she has not picked yet: the leg is still the corridor's to the gate's centre.
        var early = try Self.scene(tack: .port) { $0.laying(left: $0.rounded(on: .port), on: .port, above: BotBrain.gatePickRange + 1) }
        let none = early.aim()
        #expect(none == nil && early.hand.brain.gatePick == nil)
    }

    /// #518 acceptance: on the gybe that does not round a mark in one luff, close to that mark's side, she takes the
    /// far mark: the gybe round the mark is priced at `gateMarkGybeMetres`, a gybe before it at `gateGybeMetres`, and
    /// the reach across to the other mark's point is the shorter by that price. The points inside this gate's marks
    /// are 31 m apart, under `gateMarkGybeMetres`, so by the costs alone she never takes the gybe round the mark
    /// here; she does when she has picked that mark already and the far one is not `gateRepickMetres` cheaper, and
    /// then she sails for it on her own gybe: no gybe inside `gateStraightRange` of her point.
    @Test func gybeRoundTheMarkCostsMoreThanTheReachAcross() throws {
        let tack = Tack.starboard
        // Close in, 20 m above the line just inside the near mark: the gybe round it against the reach across.
        var close = try Self.scene(tack: tack) { $0.gate.centre + $0.outwards(left: !$0.rounded(on: tack)) * 20 + $0.up * 20 }
        let near = !close.bearings.rounded(on: tack)
        var costs = try close.costs()
        var toNear = (close.bearings.entry(left: near) - close.boat.position).length
        var toFar = (close.bearings.entry(left: !near) - close.boat.position).length
        try #require(toNear < BotBrain.gateStraightRange && toNear < toFar)
        // The way to the near mark's point (deeper than her groove, the gybing cone's length: a few metres more than
        // the straight line) and the gybe round it; the far mark's, the straight line alone.
        let gybeRound = (near ? costs.left : costs.right) - toNear - BotBrain.gateMarkGybeMetres
        #expect(gybeRound >= 0 && gybeRound < 5, "costs \(costs)")
        #expect(abs((near ? costs.right : costs.left) - toFar) < 1e-9, "costs \(costs)")
        _ = close.aim()
        #expect(close.hand.brain.gatePick?.left == !near)
        var ticks = Self.track(&close, seconds: 20)
        #expect(ticks.last?.leg == 3, "she rounds the far mark")
        #expect(Self.gybes(ticks, from: .port).isEmpty, "the reach across and the far mark rounded in one luff")

        // Further out, 60 m above the line and 12 m outside the near mark: a gybe onto its layline against the reach.
        var out = try Self.scene(tack: tack) {
            $0.gate.mark(left: !$0.rounded(on: tack)).position + $0.outwards(left: !$0.rounded(on: tack)) * 12 + $0.up * 60
        }
        costs = try out.costs()
        toNear = (out.bearings.entry(left: near) - out.boat.position).length
        toFar = (out.bearings.entry(left: !near) - out.boat.position).length
        try #require(toNear < toFar)
        #expect((near ? costs.left : costs.right) >= toNear + BotBrain.gateGybeMetres, "costs \(costs)")
        #expect(abs((near ? costs.right : costs.left) - toFar) < 1e-9, "costs \(costs)")
        _ = out.aim()
        #expect(out.hand.brain.gatePick?.left == !near)

        // The near mark picked already, and the far one under `gateRepickMetres` cheaper: she holds on for it on the
        // gybe she is on and, this low (no room to gybe above the line, `gateSetUpLow`; higher up she does, see
        // `farMarkSheGybesAboveTheLineNotAtTheMark`), gybes round it after the line.
        var held = try Self.scene(tack: tack, heading: {
            ($0.entry(left: !$0.rounded(on: tack)) - ($0.gate.centre + $0.outwards(left: !$0.rounded(on: tack)) * 28 + $0.up * 2)).bearing
        }) { $0.gate.centre + $0.outwards(left: !$0.rounded(on: tack)) * 28 + $0.up * 2 }
        held.hand.brain.gatePick = (held.boat.legIndex, near)
        costs = try held.costs()
        let (mine, other) = near ? (costs.left, costs.right) : (costs.right, costs.left)
        try #require(other < mine && other + BotBrain.gateRepickMetres >= mine, "costs \(costs)")
        let aimAsked = held.aim()
        let aim = try #require(aimAsked)
        #expect(aim.tack == tack && held.hand.brain.plannedTack == tack && held.hand.brain.gatePick?.left == near)
        ticks = Self.track(&held, seconds: 12)
        let before = ticks.prefix { $0.stage == 0 && $0.leg == 2 }
        try #require(before.count < ticks.count, "she never crossed the line")
        #expect(before.allSatisfy { $0.pick == near && $0.planned == tack })
        #expect(Self.gybes(Array(before), from: .port).isEmpty, "a gybe before the line")
    }

    /// #525 fix round 2: come to her mark on the gybe that does not round it, from outside it and above the line
    /// (the pick held: a boat stopped above the other mark's point makes it dear), she does not sail straight for her
    /// point to cross on that gybe and gybe round the mark below the line: she sails across above her point
    /// (`gateSetUp`), for the point `gateSetUpMetres` up the rounding gybe's groove from it or, lower, on a reach of
    /// `gateSetUpReach`; and once her point bears on the rounding gybe's side she gybes onto it above the line. On
    /// main she sailed straight for her point, crossed on the other gybe and carried deep below the line.
    @Test func farMarkSheGybesAboveTheLineNotAtTheMark() throws {
        for tack in [Tack.starboard, .port] {
            for up in [10.0, 25.0] {
                let name = "\(tack), \(up) m up"
                let place: (Bearings) -> Vec2 = {
                    $0.gate.centre + $0.outwards(left: !$0.rounded(on: tack)) * 28 + $0.up * up
                }
                var scene = try Self.scene(tack: tack, heading: { ($0.entry(left: !$0.rounded(on: tack)) - place($0)).bearing },
                                           pose: place)
                let b = scene.bearings
                let mark = !b.rounded(on: tack)
                var snapshot = scene.race.exportSnapshot()
                snapshot.seats[1].boat.position = b.entry(left: !mark) + b.up * 6
                snapshot.seats[1].boat.heading = b.wind
                snapshot.seats[1].boat.speed = 0
                try scene.race.importSnapshot(snapshot)
                scene.hand.brain.gatePick = (scene.boat.legIndex, mark)
                let costs = try scene.costs()
                let (mine, other) = mark ? (costs.left, costs.right) : (costs.right, costs.left)
                try #require(other + BotBrain.gateRepickMetres >= mine, "\(name): costs \(costs)")
                let entry = b.entry(left: mark)
                let seen = scene.seen()
                let toEntry = Aim(heading: (entry - seen.own.position).bearing, seen.own, tolerance: 0)
                let aimAsked = scene.aim()
                let aim = try #require(aimAsked, "\(name)")
                #expect(scene.hand.brain.gatePick?.left == mark, "\(name): changed her pick")
                #expect(aim.tack == tack && scene.hand.brain.plannedTack == tack, "\(name): \(aim)")
                // Across, above her point: higher than the course to it by more than a few degrees.
                #expect(toEntry.tack == tack && aim.angle < toEntry.angle - deg2rad(10),
                        "\(name): aims \(rad2deg(aim.angle))° off the wind, her point is \(rad2deg(toEntry.angle))°")
            }
        }
        // Inside her point's groove on the rounding gybe, 10 m above the line, she gybes onto it.
        for tack in [Tack.starboard, .port] {
            var scene = try Self.scene(tack: tack) {
                $0.laying(left: !$0.rounded(on: tack), on: tack.other, above: 10, deeper: -deg2rad(10))
            }
            let mark = !scene.bearings.rounded(on: tack)
            scene.hand.brain.gatePick = (scene.boat.legIndex, mark)
            let aimAsked = scene.aim()
            let aim = try #require(aimAsked, "\(tack)")
            #expect(scene.hand.brain.gatePick?.left == mark && aim.tack == tack.other, "\(tack): \(aim)")
        }
    }

    /// #525 fix round 2: straight for her point on the gybe that rounds it, with the point a few degrees by the lee
    /// (inside `gateLee`), she sails as close to dead downwind as she does (`gateMaxAngle`), not as far the other side
    /// of it: that mirror sailed her away from her point, outside it, till a gybe at the line. It fails on main.
    @Test func herPointByTheLeeSheRunsNotMirrors() throws {
        for tack in [Tack.starboard, .port] {
            var scene = try Self.scene(tack: tack) {
                $0.laying(left: $0.rounded(on: tack), on: tack, out: 20, deeper: .pi - $0.down + deg2rad(6))
            }
            let left = scene.bearings.rounded(on: tack)
            scene.hand.brain.gatePick = (scene.boat.legIndex, left)
            let aimAsked = scene.aim()
            let aim = try #require(aimAsked, "\(tack)")
            #expect(aim.tack == tack && scene.hand.brain.gatePick?.left == left, "\(tack): \(aim)")
            #expect(abs(scene.hand.brain.planingAimed.asked - BotBrain.gateMaxAngle) < 1e-9,
                    "\(tack): asks \(rad2deg(scene.hand.brain.planingAimed.asked))°")
        }
    }

    /// #518 acceptance: on the gybe that rounds her mark, from 60 m above the line to the end of the leg, her boom
    /// never crosses once she is within `gateStraightRange` of her point: she rounds it in one luff. The water's wind
    /// shifts as any does; over these 12 s no shift gybed her.
    @Test func noGybeInsideThirtyMetresOfHerPoint() throws {
        for tack in [Tack.starboard, .port] {
            var scene = try Self.scene(tack: tack) { $0.laying(left: $0.rounded(on: tack), on: tack, above: 60) }
            let entry = scene.bearings.entry(left: scene.bearings.rounded(on: tack))
            let boom = scene.boat.boomSide
            let ticks = Self.track(&scene, seconds: 25)
            #expect(ticks.last?.leg == 3, "\(tack): she never rounded her mark")
            let inside = Array(ticks.drop { ($0.position - entry).length >= BotBrain.gateStraightRange })
            try #require(!inside.isEmpty && inside.count < ticks.count, "\(tack)")
            #expect(Self.gybes(inside, from: boom).isEmpty, "\(tack): her boom crossed at \(Self.gybes(inside, from: boom))")
            #expect(ticks.allSatisfy { $0.boom == boom }, "\(tack): a gybe on the way")
        }
    }

    /// #518 acceptance: on the gybe that rounds her mark with her point 7° deeper than her groove, 40 m off, she sails
    /// straight for it, deeper than her groove, not down her groove past it: she crosses the line between the marks,
    /// at her point, and is never outside her mark above the line.
    @Test func sailsStraightForHerPointNotPastIt() throws {
        for tack in [Tack.starboard, .port] {
            var scene = try Self.scene(tack: tack) {
                $0.laying(left: $0.rounded(on: tack), on: tack, out: 40, deeper: deg2rad(7))
            }
            let b = scene.bearings
            let left = b.rounded(on: tack)
            var posed = scene
            let aimAsked = posed.aim()
            let aim = try #require(aimAsked)
            #expect(aim.groove == nil && aim.tack == tack, "\(tack): \(aim)")
            // Straight for it is what she asks, 7° deeper than her groove; beyond `PlaningTable.gateRange` of it she sails
            // that no deeper than keeps her on the plane (`planingAim`), as any deep aim: deeper than her groove still.
            #expect(abs(posed.hand.brain.planingAimed.asked - b.down - deg2rad(7)) < deg2rad(1),
                    "\(tack): asks \(rad2deg(posed.hand.brain.planingAimed.asked))°")
            #expect(aim.angle > b.down + deg2rad(2) && aim.angle <= posed.hand.brain.planingAimed.asked + 1e-9,
                    "\(tack): \(rad2deg(aim.angle))°")
            #expect(posed.hand.brain.plannedTack == tack)
            // What `navigate` notes of a course to her mark, she notes of this one.
            #expect(posed.hand.brain.isNearHerMark && !posed.hand.brain.isAtHerGate)
            #expect(posed.hand.brain.gateCommitted?.left == left && posed.hand.brain.gateCommitted?.leg == 2)

            let ticks = Self.track(&scene, seconds: 15)
            let before = ticks.prefix { $0.stage == 0 && $0.leg == 2 }
            try #require(before.count < ticks.count, "\(tack): she never crossed the line")
            let outwards = b.outwards(left: left)
            let mark = b.gate.mark(left: left)
            // Along the line from her mark towards the other, metres: between the marks is 0 to the gate's width.
            let crossed = (ticks[before.count].position - mark.position).dot(-outwards)
            #expect(crossed > mark.radius && crossed < (b.gate.left.position - b.gate.right.position).length / 2,
                    "\(tack): crossed \(crossed) m inside her mark")
            #expect(abs((ticks[before.count].position - b.entry(left: left)).dot(outwards)) < 3,
                    "\(tack): crossed \((ticks[before.count].position - b.entry(left: left)).dot(outwards)) m outside her point")
            #expect(before.allSatisfy { ($0.position - mark.position).dot(outwards) < 0 }, "\(tack): outside her mark")
            #expect(ticks.allSatisfy { $0.boom == scene.race.boats[0].boomSide }, "\(tack): a gybe")
        }
    }

    /// #518 acceptance, as the code sails it: 60 m off her point on the gybe that rounds her mark, the point 20°
    /// deeper than her groove, she does not sail for it by the lee: that way is priced at two gybes, away and back.
    /// At this gate (her two points 31 m apart) the other mark is then always the cheaper by a gybe, so what she does
    /// is gybe once and round the other mark in one luff: one boom crossing, not the two of the ticket's wording.
    /// Only a pick she already holds, with the other mark not `gateRepickMetres` cheaper, has her gybe away for it.
    @Test func farAndDeepSheGybesAwayNotByTheLee() throws {
        for tack in [Tack.starboard, .port] {
            var scene = try Self.scene(tack: tack) {
                $0.laying(left: $0.rounded(on: tack), on: tack, out: 60, deeper: deg2rad(20))
            }
            let b = scene.bearings
            let left = b.rounded(on: tack)
            let costs = try scene.costs()
            let view = scene.seen()
            let hers = scene.hand.brain.gateOption(left: left, scene.gate, view.own, view)
            #expect(hers.farDeep && hers.needs == tack && hers.onOwn)
            // Her own mark at the gybing cone's length and two gybes; the other at the same cone and one.
            #expect(abs((left ? costs.left : costs.right) - (left ? costs.right : costs.left) - BotBrain.gateGybeMetres) < 1,
                    "\(tack): costs \(costs)")
            var posed = scene
            let aimAsked = posed.aim()
            let aim = try #require(aimAsked)
            #expect(posed.hand.brain.gatePick?.left == !left)
            #expect(aim.angle <= b.down + 1e-9, "\(tack): aims \(rad2deg(aim.angle))° off the wind")

            let boom = scene.boat.boomSide
            let ticks = Self.track(&scene, seconds: 40)
            #expect(ticks.last?.leg == 3, "\(tack): she never rounded a mark")
            let crossings = Self.gybes(ticks, from: boom)
            #expect(crossings.count == 1, "\(tack): boom crossings at \(crossings)")
            // No run by the lee: but for the gybe itself (she bears away through dead downwind by hand, some 3 s of it)
            // she is never deeper than the deepest she sails straight for a point, and 2° for her hand.
            let deepest = ticks.filter { tick in !crossings.contains { tick.time > $0 - 3.5 && tick.time < $0 + 1 } }
                .map(\.offWind).max() ?? 0
            #expect(deepest < b.down + BotBrain.gateDeepest + deg2rad(2), "\(tack): \(rad2deg(deepest))° off the wind")

            // Holding her pick (the other mark under `gateRepickMetres` cheaper: from above her own mark, her point on
            // the other side) she plans the gybe away and sails her groove, not for her point by the lee.
            var holding = try Self.scene(tack: tack) { $0.entry(left: $0.rounded(on: tack)) + $0.outwards(left: $0.rounded(on: tack)) * 5 + $0.up * 34 }
            holding.hand.brain.gatePick = (2, left)
            let held = try holding.costs()
            let (mine, other) = left ? (held.left, held.right) : (held.right, held.left)
            try #require(other < mine && other + BotBrain.gateRepickMetres >= mine, "\(tack): costs \(held)")
            let awayAsked = holding.aim()
            let away = try #require(awayAsked)
            #expect(holding.hand.brain.gatePick?.left == left && holding.hand.brain.plannedTack == tack.other, "\(tack)")
            #expect(away.angle <= holding.bearings.down + 1e-9, "\(tack): aims \(rad2deg(away.angle))° off the wind")
        }
    }

    /// #518 acceptance: 15 m below the line and 10 m outside the nearer mark, not through the gate, she sails back
    /// above the line round that end (every aim upwind until she is `gateRecoverAbove` above it), then picks her mark
    /// and crosses the line within 25 s.
    @Test func belowTheLineSheSailsBackAboveRoundTheNearerEnd() throws {
        for left in [true, false] {
            let tack: Tack = left ? .port : .starboard
            var scene = try Self.scene(tack: tack) { $0.gate.mark(left: left).position + $0.outwards(left: left) * 10 - $0.up * 15 }
            let b = scene.bearings
            try #require(b.rounded(on: tack) == left)
            var back: Double?
            var crossed: Double?
            for tick in 1...Int(90 * Double(Race.tickRate)) {
                let time = Double(tick) / Double(Race.tickRate)
                if back == nil, (scene.race.tick).isMultiple(of: BotDriver.decisionInterval) {
                    // What she aims for at this decision, on a copy of her brain.
                    var probe = scene
                    let view = probe.seen()
                    let asked = probe.hand.brain.gateAim(view.own, view)
                    let aim = try #require(asked, "at \(time) s")
                    let above = b.above(view.own.position)
                    if above <= BotBrain.gateRecoverAbove {
                        #expect(probe.hand.brain.gateRecovering, "at \(time) s, \(above) m above the line")
                        #expect(Vec2.heading(aim.heading(wind: view.own.windDirection)).dot(b.up) > 0,
                                "at \(time) s, \(above) m above the line: aims \(rad2deg(aim.angle))° off the wind")
                    }
                }
                scene.hand.drive(scene.race)
                scene.race.step()
                // Never through the gate from below, nor outside it.
                try #require(scene.boat.legIndex == 2)
                if back == nil, b.above(scene.boat.position) > BotBrain.gateRecoverAbove {
                    back = time
                    #expect((scene.boat.position - b.gate.mark(left: left).position).dot(b.outwards(left: left)) > 0,
                            "back above the line inside the mark")
                }
                if scene.boat.roundingStage >= 1 {
                    crossed = time
                    break
                }
                if back == nil { #expect(scene.boat.roundingStage == 0) }
            }
            let above = try #require(back, "never back above the line")
            let through = try #require(crossed, "never through the gate")
            #expect(!scene.hand.brain.gateRecovering)
            #expect(through - above <= 25, "through the gate \(through - above) s after she was back above it")
        }
    }

    /// #518 acceptance: she keeps her pick for the leg. Sailing straight for it from 75 m it never changes; she
    /// changes it for a gain of more than `gateRepickMetres`, not for less; and once she has sailed straight for a
    /// mark's point, that point is not repriced as far and deep.
    @Test func keepsHerPickForLessThanTenMetres() throws {
        for tack in [Tack.starboard, .port] {
            var scene = try Self.scene(tack: tack) { $0.laying(left: $0.rounded(on: tack), on: tack, above: 75) }
            let left = scene.bearings.rounded(on: tack)
            let ticks = Self.track(&scene, seconds: 25)
            let before = ticks.prefix { $0.stage == 0 && $0.leg == 2 }
            try #require(before.count < ticks.count, "\(tack): she never crossed the line")
            #expect(before.allSatisfy { $0.pick == left }, "\(tack): she changed her pick")
            #expect(scene.hand.brain.gateCommitted?.left == left)
        }

        // The rule itself: a gain of 9 m is not worth a change of mind, one of 11 m is; no pick yet, the cheaper.
        #expect(BotBrain.picksLeftGateMark(held: true, left: 60, right: 51))
        #expect(!BotBrain.picksLeftGateMark(held: true, left: 60, right: 49))
        #expect(!BotBrain.picksLeftGateMark(held: false, left: 51, right: 60))
        #expect(BotBrain.picksLeftGateMark(held: false, left: 49, right: 60))
        #expect(BotBrain.picksLeftGateMark(held: nil, left: 50, right: 51) && !BotBrain.picksLeftGateMark(held: nil, left: 51, right: 50))
        #expect(BotBrain.gateRepickMetres == 10)

        // And at the helm, with the dearer mark picked: from the middle of the gate 30 m up it is a gybe dearer, more
        // than she changes for; from outside the other mark 40 m up (a gybe to it against the longer reach), less.
        for (off, above, flips) in [(0.0, 30.0, true), (-27.0, 40.0, false)] {
            var middle = try Self.scene(tack: .port) { $0.gate.centre + $0.outwards(left: $0.rounded(on: .port)) * off + $0.up * above }
            let costs = try middle.costs()
            let dearerIsLeft = costs.left > costs.right
            let gain = abs(costs.left - costs.right)
            try #require(flips ? gain > BotBrain.gateRepickMetres + 1 : gain < BotBrain.gateRepickMetres - 1 && gain > 1,
                         "costs \(costs)")
            middle.hand.brain.gatePick = (2, dearerIsLeft)
            _ = middle.aim()
            #expect(middle.hand.brain.gatePick?.left == (flips ? !dearerIsLeft : dearerIsLeft), "costs \(costs)")
            // Another leg's pick is none of this leg's: she picks the cheaper.
            middle.hand.brain.gatePick = (0, dearerIsLeft)
            _ = middle.aim()
            #expect(middle.hand.brain.gatePick?.leg == 2 && middle.hand.brain.gatePick?.left == !dearerIsLeft)
        }

        // The latch: far and deep of her point (60 m off, 20° deeper than her groove) she would change for the other
        // mark; having sailed straight for it she holds on, and its cost is the way there alone.
        var deep = try Self.scene(tack: .port) { $0.laying(left: $0.rounded(on: .port), on: .port, out: 60, deeper: deg2rad(20)) }
        let left = deep.bearings.rounded(on: .port)
        let fresh = try deep.costs()
        deep.hand.brain.gatePick = (2, left)
        deep.hand.brain.gateCommitted = (2, left)
        let committed = try deep.costs()
        #expect(abs((left ? fresh.left - committed.left : fresh.right - committed.right) - 2 * BotBrain.gateGybeMetres) < 1e-9)
        let aimAsked = deep.aim()
        let aim = try #require(aimAsked)
        #expect(deep.hand.brain.gatePick?.left == left && aim.tack == .port && deep.hand.brain.plannedTack == .port)
        // Straight for it is what she asks; how deep she sails it is her planing's (`planingAim`), as any deep aim's.
        #expect(aim.groove == nil && deep.hand.brain.planingAimed.asked > deep.bearings.down + BotBrain.gateDeepest)
        // Committed to another leg's mark, she is far and deep of this one as before.
        deep.hand.brain.gateCommitted = (0, left)
        let other = try deep.costs()
        #expect(other.left == fresh.left && other.right == fresh.right)
    }

    /// #523 acceptance: from the pick on (70 m above the line, inside `gatePickRange` and outside `PlaningTable.markRange`)
    /// she is near her mark of her leg: slow on the plane (her point far and deep) and wanting a gybe, she builds no speed
    /// first, as inside 60 m. Away from it, as before, she does.
    @Test func noSpeedBuildBetweenPickAndMarkRange() throws {
        for tack in [Tack.starboard, .port] {
            var scene = try Self.scene(tack: tack) {
                $0.laying(left: $0.rounded(on: tack), on: tack, out: 72, deeper: deg2rad(20))
            }
            _ = scene.aim()
            try #require(scene.hand.brain.gatePick != nil)
            #expect(PlaningTable.markRange < BotBrain.gatePickRange && scene.bearings.above(scene.boat.position) > PlaningTable.markRange)
            // Slow for her angle: 30 % of her polar speed there.
            let first = scene.seen()
            let angle = abs(scene.hand.brain.sailingAngle(first.own))
            var snapshot = scene.race.exportSnapshot()
            snapshot.seats[0].boat.speed = 0.3 * first.boatClass.polar.speed(twa: angle, tws: first.own.polarWindSpeed)
                * first.own.speedShadow
            try scene.race.importSnapshot(snapshot)
            let view = scene.seen()
            var away = scene.hand.brain
            away.senses.planing = true
            away.isNearHerMark = false
            let buildsAway = away.buildsSpeedToGybe(view.own, view)
            try #require(buildsAway, "\(tack): not slow for her angle")
            var near = scene.hand.brain
            near.senses.planing = true
            let isNear = near.isNearHerMark && near.isNearMarkOfHerLeg(view.own, view)
            let builds = near.buildsSpeedToGybe(view.own, view)
            #expect(isNear, "\(tack)")
            #expect(!builds, "\(tack): she builds speed for the gybe at the pick")
        }
    }

    /// #523 acceptance: at 75 m, the plan a reach on the other gybe (her pick's point to the other side of dead
    /// downwind) and the gybe refused, she holds the closest course to her point on her own gybe, never the mirror of
    /// the plan's angle away from it.
    @Test func refusedGybeAtThePickHoldsHerCourseToThePoint() throws {
        for tack in [Tack.starboard, .port] {
            var found = 0
            for off in stride(from: -50.0, through: 50.0, by: 5.0) {
                var scene = try Self.scene(tack: tack) { $0.gate.centre + $0.outwards(left: true) * off + $0.up * 75 }
                let aimAsked = scene.aim()
                guard let aim = aimAsked, aim.tack != tack, aim.groove == nil else { continue }
                let view = scene.seen()
                guard let pick = scene.hand.brain.gatePick else { continue }
                found += 1
                #expect(scene.hand.brain.isNearMarkOfHerLeg(view.own, view), "\(tack), \(off) m: not near her mark at 75 m")
                let held = try #require(scene.hand.brain.refusedTurnAim(aim, view.own, view), "\(tack), \(off) m")
                #expect(held.tack == tack)
                let entry = scene.bearings.entry(left: pick.left)
                let bearing = (entry - view.own.position).bearing
                let wind = view.own.windDirection
                let mirror = Aim(angle: aim.angle, tack: tack)
                #expect(abs(wrapAngle(held.heading(wind: wind) - bearing)) <= abs(wrapAngle(mirror.heading(wind: wind) - bearing)) + 1e-9,
                        "\(tack), \(off) m: holds \(rad2deg(held.angle))° against the mirror's \(rad2deg(mirror.angle))°")
            }
            #expect(found >= 1, "\(tack): no pose with a reach on the other gybe")
        }
    }

    /// #523 acceptance: rounding a gate mark on its rounding tack with the beat's plan wanting the other (the
    /// corridor's), her first beat aim is the rounding tack close-hauled: the turn is a luff (her angle off the wind
    /// never grows past what it was, never through dead downwind), and she is close-hauled on it before she tacks.
    @Test func offTheGateTheBeatStartsOnTheRoundingTack() throws {
        for tack in [Tack.port, .starboard] {
            var scene = try Self.scene(tack: tack) { $0.laying(left: $0.rounded(on: tack), on: tack, above: 40) }
            let leg = scene.boat.legIndex
            var changed: (offWind: Double, boom: BoomSide)?
            var seconds = 0.0
            var widest = 0.0
            var crossed = false
            var hauled = false
            for _ in 1...Int(60 * Double(Race.tickRate)) {
                scene.hand.drive(scene.race)
                scene.race.step()
                let boat = scene.boat
                let wind = scene.race.groundWind(at: boat.position).direction
                let offWind = abs(wrapAngle(wind - boat.heading))
                if changed == nil, boat.legIndex != leg {
                    changed = (offWind, boat.boomSide)
                    // The corridor wants the other tack.
                    scene.hand.brain.plannedTack = tack.other
                }
                guard let at = changed else { continue }
                seconds += 1 / Double(Race.tickRate)
                widest = max(widest, offWind - at.offWind)
                if boat.boomSide != at.boom { crossed = true }
                if boat.tack == tack && offWind < deg2rad(60) { hauled = true }
                if hauled || seconds > 25 { break }
            }
            try #require(changed != nil, "\(tack): she never left the gate's leg")
            #expect(!crossed, "\(tack): her boom crossed on the way to close-hauled")
            #expect(widest < deg2rad(3), "\(tack): her angle off the wind grew by \(rad2deg(widest))°")
            #expect(hauled, "\(tack): never close-hauled on the rounding tack")
            #expect(scene.hand.brain.plannedTack == tack, "\(tack): planned \(scene.hand.brain.plannedTack)")
        }
    }

    /// Sails `scene` to the end of her leg, or for `seconds`: every tick.
    static func track(_ scene: inout Scene, seconds: Double) -> [Tick] {
        var ticks: [Tick] = []
        let leg = scene.boat.legIndex
        for tick in 1...Int(seconds * Double(Race.tickRate)) {
            scene.hand.drive(scene.race)
            scene.race.step()
            let boat = scene.boat
            let wind = scene.race.groundWind(at: boat.position).direction
            let brain = scene.hand.brain
            ticks.append(Tick(time: Double(tick) / Double(Race.tickRate), position: boat.position, boom: boat.boomSide,
                              leg: boat.legIndex, stage: boat.roundingStage, offWind: abs(wrapAngle(wind - boat.heading)),
                              pick: brain.gatePick.flatMap { $0.leg == leg ? $0.left : nil },
                              recovering: brain.gateRecovering, planned: brain.plannedTack))
            if boat.legIndex != leg { break }
        }
        return ticks
    }

    // MARK: - #525 H1: the crowded mark and the shadow gybe

    /// Moves seat 1 (far off in `scene`) to `position`, `status` as given: racing on the gate's leg, at her heading and speed.
    static func park(_ scene: inout Scene, at position: Vec2, status: BoatStatus = .racing) throws {
        var snapshot = scene.race.exportSnapshot()
        snapshot.seats[1].boat.position = position
        snapshot.seats[1].boat.heading = scene.boat.heading
        snapshot.seats[1].boat.speed = scene.boat.speed
        snapshot.seats[1].boat.status = status
        try scene.race.importSnapshot(snapshot)
    }

    /// A scene 60 m above the line whose marks cost her nearly the same, the left the cheaper or equal (a fresh pick
    /// takes the left on a tie), and her cost of each.
    static func closePick() throws -> (scene: Scene, costs: (left: Double, right: Double)) {
        var found: (Scene, (left: Double, right: Double), Double)?
        for off in stride(from: -30.0, through: 30.0, by: 1.5) {
            var scene = try Self.scene(tack: .starboard) { $0.gate.centre + $0.outwards(left: true) * off + $0.up * 60 }
            let costs = try scene.costs()
            let gap = costs.right - costs.left
            if gap >= 0, gap < 20, gap < (found?.2 ?? .infinity) { found = (scene, costs, gap) }
        }
        let close = try #require(found, "no pose 60 m above the line with the left mark the cheaper by under 20 m")
        return (close.0, close.1)
    }

    /// #525 H1 acceptance: a boat parked on the line to one mark's point makes that mark dearer (`gateCosts`), by
    /// `gateTrafficBoatMetres` on the line, and in a scene that picks the left mark (a tie goes left) she picks the
    /// other. A boat through the gate, behind her, off the line by `gateTrafficNear`, and a ghost add nothing.
    @Test func aBoatOnTheLineToAMarkMakesItDearer() throws {
        var (scene, base) = try Self.closePick()
        let fresh = scene.hand.brain
        _ = scene.aim()
        try #require(scene.hand.brain.gatePick?.left == true, "the pose picks the left mark on its own")
        scene.hand.brain = fresh

        let me = scene.boat.position
        let entry = scene.bearings.leftEntry
        // Nine tenths of the way: the right mark's line is 0.9 x 31 m off it, clear of `gateTrafficNear`.
        let onTheLine = me + (entry - me) * 0.9
        let toRight = scene.bearings.rightEntry - me
        let lineOff = abs((onTheLine - me).cross(toRight.normalized))
        try #require(lineOff >= BotBrain.gateTrafficNear, "the right mark's line is \(lineOff) m off the parked boat")
        try #require(scene.bearings.above(onTheLine) > 0, "she is parked above the gate's line")
        try Self.park(&scene, at: onTheLine)
        let costs = try scene.costs()
        #expect(abs(costs.left - (base.left + BotBrain.gateTrafficBoatMetres)) < 1e-6, "left \(base.left) -> \(costs.left)")
        #expect(abs(costs.right - base.right) < 1e-6, "right \(base.right) -> \(costs.right)")
        _ = scene.aim()
        #expect(scene.hand.brain.gatePick?.left == false, "she picks the right mark, the left one crowded")

        // Off the line it fades, and at `gateTrafficNear` off it is nothing.
        // Off the line to its upper side, still above the gate's line.
        let side = -(entry - me).normalized.rightPerp
        try Self.park(&scene, at: onTheLine + side * (BotBrain.gateTrafficNear * 0.5))
        let half = try scene.costs()
        #expect(abs(half.left - (base.left + BotBrain.gateTrafficBoatMetres * 0.5)) < 1e-6, "half way off: \(half.left), base \(base.left)")

        // None of these is in her road.
        // Three metres past her point along the line: on the way, but 5 m below the gate's line.
        let beyond = entry + (entry - me).normalized * 3
        try #require(scene.bearings.above(beyond) < -3)
        let cases: [(String, Vec2, BoatStatus)] = [
            ("through the gate", beyond, .racing),
            ("behind her", me + scene.bearings.up * 20, .racing),
            ("ghost on the line", onTheLine, .finished),
            ("far off the line", onTheLine + side * BotBrain.gateTrafficNear, .racing),
        ]
        for (name, position, status) in cases {
            try Self.park(&scene, at: position, status: status)
            let moved = try scene.costs()
            #expect(abs(moved.left - base.left) < 1e-6 && abs(moved.right - base.right) < 1e-6, "\(name): \(moved) against \(base)")
        }
    }

    /// #525 H1: the traffic she prices is blended over `gateTrafficSeconds`: a boat that sails on through the gate leaves
    /// the mark it crowded dear a while, and her pick holds (unblended, the pick followed the pack and changed 70 of 128
    /// roundings in a trace, against 8).
    @Test func aBoatThatSailsOnLeavesTheMarkDearAWhile() throws {
        var (scene, base) = try Self.closePick()
        let me = scene.boat.position
        try Self.park(&scene, at: me + (scene.bearings.leftEntry - me) * 0.9)
        _ = scene.aim()
        try #require(scene.hand.brain.gatePick?.left == false, "the left mark, crowded, is not picked")
        let first = try #require(scene.hand.brain.gateTraffic)
        #expect(abs(first.left - BotBrain.gateTrafficBoatMetres) < 1e-6 && first.right == 0)
        // The boat is gone (far off), a second on: the left mark is cheap again by the costs now.
        try Self.park(&scene, at: me + scene.bearings.up * 300)
        for _ in 0..<Race.tickRate { scene.race.step() }
        let costs = try scene.costs()
        #expect(abs(costs.left - base.left) < 5, "left costs \(costs.left) against \(base.left) without the boat")
        _ = scene.aim()
        let later = try #require(scene.hand.brain.gateTraffic)
        let share = 1 - exp(-1 / BotBrain.gateTrafficSeconds)
        #expect(abs(later.left - first.left * (1 - share)) < 0.5, "the traffic she prices decays to \(later.left) from \(first.left)")
        #expect(later.left > first.left / 2 && scene.hand.brain.gatePick?.left == false, "and she holds her pick")
    }

    /// #525 H1 acceptance: with no other boat in range the traffic term is nothing: a single-boat scene costs what it
    /// did, the wake's loss included (none in clean air).
    @Test func noBoatInRangeAddsNothing() throws {
        var scene = try Self.scene(tack: .starboard) { $0.gate.centre + $0.up * 60 }
        let view = scene.seen()
        let gate = scene.gate
        let entry = scene.bearings.leftEntry
        #expect(scene.hand.brain.gateTrafficMetres(to: entry, gate, view.own, view) == 0)
        try Self.park(&scene, at: scene.boat.position + scene.bearings.up * 300)
        let far = scene.seen()
        #expect(scene.hand.brain.gateTrafficMetres(to: entry, gate, far.own, far) == 0)
    }

    /// #525 H1 acceptance: on the rounding gybe, in a shadow, 45 m or more from her point, she plans the other gybe once
    /// on the leg (`navigate` brings her back on its layline); not a second time that leg, not inside 45 m, not in clean
    /// air.
    @Test func gybesOutOfDirtyAirOnceOnTheRoundingGybe() throws {
        for tack in [Tack.starboard, .port] {
            func scene(out: Double, shadow: Double) throws -> Scene {
                var scene = try Self.scene(tack: tack) {
                    $0.laying(left: $0.rounded(on: tack), on: tack, out: out, deeper: deg2rad(6))
                }
                var snapshot = scene.race.exportSnapshot()
                snapshot.seats[0].boat.shadow = shadow
                try scene.race.importSnapshot(snapshot)
                return scene
            }
            // In dirty air with room: the other gybe, once.
            var shadowed = try scene(out: BotBrain.gateShadowGybeMetres + 15, shadow: 0.7)
            let view = shadowed.seen()
            try #require(view.own.shadow < BotBrain.dirtyAir, "\(tack): shadow \(view.own.shadow)")
            let aimAsked = shadowed.aim()
            let first = try #require(aimAsked, "\(tack)")
            let pick = try #require(shadowed.hand.brain.gatePick, "\(tack)")
            try #require(BotBrain.roundingTack(shadowed.gate.mark(left: pick.left), centre: shadowed.gate.centre, view.own, view) == tack,
                         "\(tack): she is on the gybe that rounds her mark")
            #expect(shadowed.hand.brain.plannedTack == tack.other, "\(tack): planned \(shadowed.hand.brain.plannedTack)")
            #expect(first.tack == tack.other, "\(tack): aims on \(first.tack)")
            // Not a second time that leg: she holds on for her point.
            _ = shadowed.aim()
            #expect(shadowed.hand.brain.plannedTack == tack, "\(tack): gybed away twice")
            // Not inside 45 m, nor in clean air.
            var near = try scene(out: BotBrain.gateShadowGybeMetres - 5, shadow: 0.7)
            _ = near.aim()
            #expect(near.hand.brain.plannedTack == tack, "\(tack): gybed out of the shadow inside \(BotBrain.gateShadowGybeMetres) m")
            var clean = try scene(out: BotBrain.gateShadowGybeMetres + 15, shadow: 1)
            _ = clean.aim()
            #expect(clean.hand.brain.plannedTack == tack, "\(tack): gybed in clean air")
        }
    }
}
