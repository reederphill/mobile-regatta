import Foundation
import Testing
import RegattaCore
@testable import RegattaBots

// MARK: - Racing keep-clear on the shared scorer (#531)

extension BotConductTests {
    /// #531: seat 0 a bot beating on `own` at the water's upwind speed; seat 1 `ahead` hull lengths up her course and
    /// `across` to starboard of it, on `tack`'s beat (or `heading`) at `share` of that speed.
    static func scorerScene(ahead: Double, across: Double = 0, own: Tack = .starboard, tack: Tack = .starboard,
                            heading: Double? = nil, share: Double = 1, seed: UInt64 = 3) throws -> Race {
        let water = Water(seed: seed)
        let course = water.beat(own)
        let forward = Vec2.heading(course)
        return try place(water, [
            Placement(position: water.centre, heading: course, speed: water.up.speed),
            Placement(position: water.centre + forward * water.length * ahead + forward.rightPerp * water.length * across,
                      heading: heading ?? water.beat(tack), speed: water.up.speed * share),
        ])
    }

    /// A skill-1 live bot's brain for seat 0 of `race`, on the tack she sails.
    static func scorerBrain(_ race: Race) -> BotBrain {
        Pilot(seat: 0, plannedTack: nil, race: race).brain
    }

    /// #531 acceptance: the predictor rolls a turning boat on the yaw rate she was seen turning at over the last second
    /// (`measuredMotion`, the per-seat memory `glimpsed`), not in a straight line.
    @Test func predictorRollsATurningBoatOnHerYawRate() throws {
        let race = try Self.scorerScene(ahead: 6, across: 3)
        let view = race.seatView(for: 0)
        let other = try #require(view.others.first)
        var brain = Self.scorerBrain(race)
        let straight = brain.predictedTrack(of: other, .measured, view, steps: 20)
        let rate = deg2rad(20)
        brain.glimpsed = [[], [BotBrain.Glimpse(time: view.time - 1, position: other.position - other.velocity,
                                                heading: other.heading - rate, speed: other.speed)]]
        #expect(abs(brain.measuredMotion(of: other, view).turnRate - rate) < 1e-9)
        let turning = brain.predictedTrack(of: other, .measured, view, steps: 20)
        let lateral = (turning[19] - straight[19]).dot(other.forward.rightPerp)
        #expect(lateral > 1, "2 s on, turning to starboard: \(lateral) m off the straight line")
        let chord = (turning[19] - other.position).bearing
        #expect(abs(wrapAngle(chord - (other.heading + rate))) < deg2rad(3), "on the arc: \(rad2deg(chord - other.heading))°")
    }

    /// #531 acceptance: a stalling boat is rolled on the speed she was seen losing (clamped to `guardSlowing`), and a
    /// stopped one that can't keep clear comes to rest.
    @Test func predictorSlowsAStallingBoatOnHerMeasuredLoss() throws {
        let race = try Self.scorerScene(ahead: 6, across: 3)
        let view = race.seatView(for: 0)
        let other = try #require(view.others.first)
        var brain = Self.scorerBrain(race)
        let straight = brain.predictedTrack(of: other, .measured, view, steps: 30)
        brain.glimpsed = [[], [BotBrain.Glimpse(time: view.time - 1, position: other.position - other.velocity,
                                                heading: other.heading, speed: other.speed + 2)]]
        #expect(abs(brain.measuredMotion(of: other, view).acceleration + 2) < 1e-9)
        let slowing = brain.predictedTrack(of: other, .measured, view, steps: 30)
        let sailed = (slowing[29] - other.position).length, held = (straight[29] - other.position).length
        let v = other.speed, t = min(3, v / 2)
        #expect(abs(sailed - (v * t - t * t)) < 0.3, "slowing at 2 m/s²: \(sailed) m, held: \(held) m")
        brain.glimpsed = [[], [BotBrain.Glimpse(time: view.time - 1, position: other.position, heading: other.heading,
                                                speed: other.speed + 9)]]
        #expect(abs(brain.measuredMotion(of: other, view).acceleration + BotBrain.guardSlowing) < 1e-9, "clamped")
        brain.glimpsed = []
        let stopping = brain.predictedTrack(of: other, .cannot(stopped: true), view, steps: 30)
        #expect((stopping[29] - other.position).length < held - 1, "a stopped boat comes to rest")
    }

    /// #531 acceptance: the distance horizon on a slow overtake. A boat dead ahead on her tack at 0.6 of her speed, 3.5
    /// lengths up: the 4.5 s test sees nothing coming, the distance flag does (she comes inside 1.3 lengths within
    /// 6 lengths of her own travel), and the scorer commits her to a lane past it.
    @Test func distanceHorizonFlagsASlowOvertake() throws {
        let race = try Self.scorerScene(ahead: 3.5, share: 0.6)
        let view = race.seatView(for: 0)
        let b = view.own
        let other = try #require(view.others.first)
        let brain = Self.scorerBrain(race)
        #expect(!brain.isAboutToHit(other, b, view, desired: b.heading, lookahead: brain.keepClearLookahead))
        #expect(brain.overtakeFlag(other, b, view, desired: b.heading) != nil)
        let decided = try #require(brain.scoreRacingKeepClear(b, view, desired: b.heading,
                                                              lookahead: brain.keepClearLookahead))
        #expect(decided.threat == 1 && decided.latch?.lane == 1, "\(decided)")
        // Twice as far off, not yet.
        let far = try Self.scorerScene(ahead: 7, share: 0.6)
        let farView = far.seatView(for: 0)
        #expect(brain.overtakeFlag(try #require(farView.others.first), farView.own, farView, desired: farView.own.heading) == nil)
    }

    /// #531 acceptance: the committed pass is held to clear ahead. Latched on her lane, she still passes a boat two
    /// lengths abeam on that side, which no flag would see, until clear ahead of it; then she is let go.
    @Test func committedPassIsHeldToClearAhead() throws {
        let flagged = try Self.scorerScene(ahead: 3.5, share: 0.6)
        let view = flagged.seatView(for: 0)
        var brain = Self.scorerBrain(flagged)
        let latch = try #require(brain.scoreRacingKeepClear(view.own, view, desired: view.own.heading,
                                                            lookahead: brain.keepClearLookahead)?.latch)
        #expect(latch.lane == 1)
        brain.keepClearLatch = latch
        // Her lane's side, across her course: on starboard tack, bearing away is to port.
        let across = -latch.side * BotBrain.laneLengths // the other boat on the far side of her lane
        let alongside = try Self.scorerScene(ahead: 0.5, across: across, share: 0.6)
        let near = alongside.seatView(for: 0)
        let other = try #require(near.others.first)
        #expect(brain.overtakeFlag(other, near.own, near, desired: near.own.heading) == nil, "no flag alongside")
        let held = try #require(brain.scoreRacingKeepClear(near.own, near, desired: near.own.heading,
                                                           lookahead: brain.keepClearLookahead))
        #expect(held.latch == latch && held.threat == 1, "held: \(held)")
        let clear = try Self.scorerScene(ahead: -1.5, across: across, share: 0.6)
        let past = clear.seatView(for: 0)
        #expect(brain.scoreRacingKeepClear(past.own, past, desired: past.own.heading,
                                           lookahead: brain.keepClearLookahead) == nil, "clear ahead, let go")
    }

    /// #531 acceptance (`tapIsClear`): the tack is refused when the track she will sail through it (`tapTrack`) fouls
    /// a boat rolled as the scorer rolls it, though the straight line onto the new heading clears: a port boat ahead
    /// bearing away across her slow tack from a reach (the cautious bot's seed-69 scene, #350). Racing only (#531 Q6).
    @Test func tapIsClearRefusesATackWhoseRealTrackFouls() throws {
        let water = Water(seed: 1)
        let heading = water.heading(.starboard, deg2rad(63))
        let forward = Vec2.heading(heading)
        var found = 0
        for ahead in stride(from: 8.0, through: 20.0, by: 2.0) {
            for across in stride(from: 0.0, through: 8.0, by: 1.0) {
                let race = try Self.place(Water(seed: 1), [
                    Placement(position: water.centre, heading: heading, speed: 1.5),
                    Placement(position: water.centre + forward * ahead + forward.rightPerp * across,
                              heading: water.beat(.port), speed: water.up.speed),
                ])
                let view = race.seatView(for: 0)
                let b = view.own
                let other = try #require(view.others.first)
                var brain = Self.scorerBrain(race)
                brain.glimpsed = [[], [BotBrain.Glimpse(time: view.time - 1, position: other.position - other.velocity,
                                                        heading: other.heading, speed: other.speed)]]
                guard brain.tapIsClear(b, view) else { continue } // sailing straight, clear by every reckoning
                brain.glimpsed = [[], [BotBrain.Glimpse(time: view.time - 0.5, position: other.position - other.velocity * 0.5,
                                                        heading: other.heading - BotBrain.guardTurnRate * 0.5,
                                                        speed: other.speed)]]
                // The predictor kept, her tack as a straight line onto the new heading at the tap's speed share
                // (`closestApproach`'s reckoning): the scenes where that alone clears the turning boat.
                let lookahead = BotBrain.tapLookahead * brain.tapLookaheadScale
                let dt = BotBrain.keepClearPredictionStep
                let steps = Int((lookahead / dt).rounded())
                let theirs = brain.predictedTrack(of: other, brain.tackReaction(of: other, b, view), view, steps: steps)
                let line = Vec2.heading(2 * b.windDirection - b.heading) * (b.speed * BotBrain.tapSpeedShare)
                let straight = (1...steps).map { b.position + line * (Double($0) * dt) }
                let clear = min(view.boatClass.hull.length * brain.tapClearanceLengths, (other.position - b.position).length)
                guard zip(straight, theirs).map({ ($1 - $0).length }).min() ?? 0 >= clear else { continue }
                // Only her real track (`tapTrack`) against the same roll-out can refuse it.
                let track = brain.tapTrack(b, view, seconds: BotBrain.tapOntoPortLookahead * brain.tapLookaheadScale)
                let real = zip(track, theirs).map { ($1 - $0).length }.min() ?? .infinity
                guard real < clear else { continue }
                found += 1
                #expect(!brain.tapIsClear(b, view), "ahead \(ahead), across \(across): her track passes \(real) m off")
            }
        }
        #expect(found > 0, "no tack whose straight line clears and whose real track fouls")
    }

    /// #531 (design point 5): the tack track `tapIsClear` sails (`tapTrack`, the autohelm's tap) against one real tack
    /// by hand on the default class: where her hand puts her in the 3 s of the tap's lookahead is within 0.75 of a hull
    /// length of where the track does, sampled at the track's own tenths of a second from the tick it was taken at.
    @Test func tapTrackFollowsARealTackByHand() throws {
        let water = Water(seed: 3)
        let race = try Self.place(water, [
            Placement(position: water.centre, heading: water.beat(.starboard), speed: water.up.speed),
            Placement(position: water.centre + Vec2(200, -200), heading: water.beat(.port), speed: water.up.speed),
        ])
        var pilot = Pilot(seat: 0, plannedTack: .port, race: race)
        // The first decision starts her tack by hand: the track is taken from that moment.
        var track: [Vec2] = []
        var sailed: [Vec2] = []
        var captured = 0
        for _ in 0..<(4 * Race.tickRate) where !race.isOver {
            let view = race.seatView(for: 0)
            if track.isEmpty, (race.tick + pilot.seat).isMultiple(of: BotDriver.decisionInterval) {
                track = pilot.brain.tapTrack(view.own, view, seconds: BotBrain.tapLookahead)
                captured = race.tick
            }
            _ = pilot.drive(race)
            race.step()
            // The track's i-th point is (i + 1) tenths of a second on from the tick it was taken at.
            if !track.isEmpty, (race.tick - captured).isMultiple(of: Race.tickRate / 10) {
                sailed.append(race.boats[0].position)
            }
        }
        #expect(race.boats[0].tack == .port, "she tacked")
        #expect(sailed.count >= track.count)
        let worst = zip(track, sailed).map { ($0 - $1).length }.max() ?? .infinity
        // Measured worst 3.12 m, 0.64 L (#531 fix round 2), the track's first second sharper than her hand's.
        #expect(worst < water.length * 0.75, "the track is \(worst) m off her hand's tack")
    }

    /// #531 acceptance (owner amendment, 2026-10-15): "the tack wins on a thin margin". Of the crossings a port bot meets
    /// a starboard boat in, the ones where every heading on her tack that clears it does so on a thin margin (under
    /// `thinMargin` of her out distance: a deep duck) and the tack she can tap now clears it: the scorer tacks her.
    @Test func theTackWinsOnAThinMargin() throws {
        var found = 0
        for ahead in stride(from: 1.5, through: 5.0, by: 0.25) {
            for across in stride(from: -1.0, through: 4.0, by: 0.25) {
                let race = try Self.scorerScene(ahead: ahead, across: across, own: .port, tack: .starboard)
                let view = race.seatView(for: 0)
                let b = view.own
                let brain = Self.scorerBrain(race)
                guard brain.canTap(b, view, byHand: true) else { continue }
                let (decision, scores) = brain.scoredRacingKeepClear(b, view, desired: b.heading,
                                                                     lookahead: brain.keepClearLookahead, tackable: true)
                guard let decision, let tack = scores.first(where: { $0.heading == nil }) else { continue }
                let clearing = scores.filter { $0.heading != nil && $0.margin >= 1 }
                guard tack.margin >= 1, !clearing.isEmpty,
                      clearing.allSatisfy({ $0.margin < BotBrain.thinMargin }) else { continue }
                #expect(decision.tacks, "ahead \(ahead), across \(across): \(decision)")
                found += 1
            }
        }
        #expect(found > 0, "no crossing tacks on a thin margin")
    }

    /// #531 (owner, 2026-10-16): a person's boat is never rolled giving way. A port boat crossing ahead of a starboard
    /// bot, owing her, is rolled bearing away when a bot sails it; a person's is sailed on as she has been, and can't
    /// when stopped. `SeatControllers` tells every bot which seats people sail.
    @Test func aPersonsBoatIsNeverRolledGivingWay() throws {
        let race = try Self.scorerScene(ahead: 5, across: 2, tack: .port)
        let view = race.seatView(for: 0)
        let other = try #require(view.others.first)
        #expect(other.rightOfWay?.keepClear == 1)
        var brain = Self.scorerBrain(race)
        guard case .givesWay = brain.reaction(of: other, view.own, view) else {
            Issue.record("a bot owing her gives way: \(brain.reaction(of: other, view.own, view))")
            return
        }
        brain.humanSeats = [false, true]
        #expect(brain.reaction(of: other, view.own, view) == .measured)
        let stopped = try Self.scorerScene(ahead: 5, across: 2, tack: .port, share: 0.05)
        let still = stopped.seatView(for: 0)
        #expect(brain.reaction(of: try #require(still.others.first), still.own, still) == .cannot(stopped: true))

        var controllers = SeatControllers([.bot(BotDriver(seat: 0, raceSeed: race.setup.raceSeed)), .human])
        for _ in 0..<BotDriver.decisionInterval {
            controllers.drive(race)
            race.step()
        }
        #expect(controllers[0].driver?.brain.humanSeats == [false, true])
    }

    /// #538 review: `tapMeetsBoatNotKeepingClear` refuses a tack while a boat trips the trigger on her heading (a port
    /// boat stalled 1.5 s ahead of a starboard bot), and not with that boat 5 s out.
    @Test func tapMeetsBoatNotKeepingClearRefusesATurnIntoAStalledBoat() throws {
        let (pilot, view, verdict) = try Self.judged(Self.avoidScene(seconds: 1.5))
        #expect(verdict == .cannot)
        #expect(pilot.brain.tapMeetsBoatNotKeepingClear(view.own, view))
        #expect(!pilot.brain.isClearToTurn(view.own, view))
        let far = try Self.judged(Self.avoidScene(seconds: 5))
        #expect(!far.pilot.brain.tapMeetsBoatNotKeepingClear(far.view.own, far.view))
    }
}

// MARK: - Pre-start keep-clear on the shared scorer (#542)

extension BotConductTests {
    /// #542: seat 0 a bot before her start, `below` hull lengths below the middle of the line `toGun` seconds before the
    /// gun, on `own` at `angle` off the wind (her hold, 3° outside the no-go zone, unless given) at the water's upwind
    /// speed; the other seats each `ahead` hull lengths up her course and `across` to starboard of it, on its tack's
    /// beat at `share` of that speed (a share under 0.1 parks it, the autohelm off). `herWind`: her angle is off the
    /// wind she sails in (`SeatView.OwnBoat.windDirection`), not the water's.
    static func preStartScorerScene(_ others: [(ahead: Double, across: Double, tack: Tack, share: Double)],
                                    own: Tack = .port, angle: Double? = nil, toGun: Int = 30, below: Double = 8,
                                    seed: UInt64 = 3, herWind: Bool = false) throws -> Race {
        var shift = 0.0
        if herWind {
            let race = try preStartScorerScene(others, own: own, angle: angle, toGun: toGun, below: below, seed: seed)
            shift = wrapAngle(race.seatView(for: 0).own.windDirection - Water(seed: seed, toGun: toGun, below: below).wind)
        }
        let water = Water(seed: seed, toGun: toGun, below: below, seats: others.count + 1)
        let hold = BoatDynamics.noGoAngle(water.race.boatClass.polar) + BotBrain.holdMargin
        let course = water.heading(own, angle ?? hold) + shift
        let forward = Vec2.heading(course)
        var placements = [Placement(position: water.centre, heading: course, speed: water.up.speed, status: .prestart)]
        for other in others {
            placements.append(Placement(
                position: water.centre + forward * water.length * other.ahead + forward.rightPerp * water.length * other.across,
                heading: other.share < 0.1 ? water.heading(other.tack, deg2rad(30)) : water.beat(other.tack),
                speed: water.up.speed * other.share, status: .prestart))
        }
        return try place(water, placements) { snapshot in
            for (i, other) in others.enumerated() where other.share < 0.1 { snapshot.seats[i + 1].boat.autohelm = nil }
        }
    }

    /// The pre-start scorer's decision and every candidate's score for seat 0 of `race`, on `desired` (her heading).
    static func preStartScored(_ race: Race, _ brain: BotBrain, desired: Double? = nil, tackable: Bool = false)
        -> (decision: BotBrain.RacingKeepClear?, scores: [BotBrain.KeepClearScore], view: SeatView) {
        let view = race.seatView(for: 0)
        let scored = brain.scoredRacingKeepClear(view.own, view, desired: desired ?? view.own.heading,
                                                 lookahead: brain.keepClearLookahead, tackable: tackable, overtakes: false,
                                                 preStart: true)
        return (scored.decision, scored.scores, view)
    }

    /// The crossings the pre-start acceptance tests sweep: a port bot at her hold meeting a starboard boat.
    static let preStartCrossings: [(ahead: Double, across: Double)] = stride(from: 1.5, through: 4.5, by: 0.5).flatMap { ahead in
        stride(from: -1.0, through: 3.0, by: 0.5).map { (ahead, $0) }
    }

    /// #542 acceptance: before the gun, holding her course wins when it clears. A port bot holding just outside the
    /// no-go zone (her hold, 3° out: under the racing floor of 5°, so the pre-start floor, `startLuffFloor`, keeps it a
    /// candidate as it is, Q6), her plan's heading 15-30° down onto a starboard boat parked on it: wherever her heading
    /// held clears it, no bear-away short of her plan's does, and it costs least of the clearing courses (#529: holding
    /// is costed like every other, never ranked first), she holds it, steered (not nil, not her plan's).
    @Test func preStartHoldingCourseWinsWhenItClears() throws {
        var found = 0
        for (distance, plan) in [3.0, 3.5, 4.0, 4.5, 5.0].flatMap({ d in [15.0, 20.0, 25.0, 30.0].map { (d, $0) } }) {
            // A starboard boat parked `distance` lengths down her plan's heading, `plan` degrees below her hold.
            let theta = deg2rad(plan)
            let race = try Self.preStartScorerScene([(distance * cos(theta), distance * sin(theta), .starboard, 0.02)],
                                                    toGun: 20, below: 20, herWind: true)
            let brain = Self.scorerBrain(race)
            let b = race.seatView(for: 0).own
            let (ahead, across) = (distance, plan)
            let desired = b.heading + theta
            let (decision, scores, _) = Self.preStartScored(race, brain, desired: desired)
            guard let decision else { continue }
            let hold = try #require(scores.first { $0.heading.map { abs(wrapAngle($0 - b.heading)) < 1e-9 } == true },
                                    "her hold is a candidate as it is: \(rad2deg(abs(wrapAngle(b.heading - b.windDirection))))°")
            // Her plan's heading, and every bear-away short of it, runs onto the parked boat.
            let between = scores.filter { s in
                guard let h = s.heading else { return false }
                let off = wrapAngle(h - b.heading) * (b.tack == .port ? 1 : -1)
                return off > 1e-9 && off <= theta + 1e-9
            }
            let others = scores.filter { $0.heading != hold.heading && $0.margin >= 1 }
            guard hold.margin >= 1, !hold.early, between.allSatisfy({ $0.margin < 1 }),
                  others.allSatisfy({ $0.cost > hold.cost }) else { continue }
            #expect(decision.heading.map { abs(wrapAngle($0 - b.heading)) < 1e-9 } == true,
                    "distance \(ahead), plan \(across)°: \(decision)")
            found += 1
        }
        #expect(found > 0, "no crossing held")
    }

    /// #542 acceptance: a committed side is kept while it clears (#529 Q5, `KeepClearLatch`). Wherever courses on both
    /// sides of her plan's heading clear the starboard boat, latched to the side the free pick didn't take she sails a
    /// clearing course on the latched side.
    @Test func preStartCommittedSideIsKeptWhileItClears() throws {
        var found = 0
        for (ahead, across) in Self.preStartCrossings {
            let race = try Self.preStartScorerScene([(ahead, across, .starboard, 0.02)], angle: deg2rad(60))
            var brain = Self.scorerBrain(race)
            let b = race.seatView(for: 0).own
            let (free, scores, _) = Self.preStartScored(race, brain)
            guard let free, let heading = free.heading else { continue }
            let off = brain.offDesired(b, heading: heading, desired: b.heading)
            guard abs(off) > BotBrain.clearingStep else { continue }
            let other = -(off > 0 ? 1.0 : -1.0)
            guard scores.contains(where: { s in
                s.margin >= 1 && s.heading.map { brain.offDesired(b, heading: $0, desired: b.heading) * other > BotBrain.clearingStep } == true
            }) else { continue }
            brain.keepClearLatch = BotBrain.KeepClearLatch(side: other)
            brain.keepClearLatchTack = b.tack
            let latched = try #require(Self.preStartScored(race, brain).decision)
            let kept = try #require(latched.heading, "ahead \(ahead), across \(across)")
            #expect(brain.offDesired(b, heading: kept, desired: b.heading) * other > 0, "ahead \(ahead), across \(across)")
            #expect(latched.latchHeld && !latched.furthest, "\(latched)")
            found += 1
        }
        #expect(found > 0, "no crossing clears both ways")
    }

    /// #542 acceptance: before the gun, the tack wins on a thin margin, as racing (#531), on the pre-start axis (her
    /// plan's heading, Q5: the tack makes little progress along it, so it wins only when the courses on her tack lose
    /// it too). Of the crossings a port bot at tacking speed meets a starboard boat in where every heading on her tack
    /// that clears does so on a thin margin and the tack she can tap clears wider: she tacks exactly when the tack costs
    /// least; and in some the thin margin's cost is what makes the tack win.
    @Test func preStartTheTackWinsOnAThinMargin() throws {
        var decisive = 0, tapless = 0
        for (angle, share) in [(45.0, 1.0), (45.0, 0.02), (70.0, 1.0), (70.0, 0.02)] {
            for ahead in stride(from: 1.5, through: 5.0, by: 0.25) {
                for across in stride(from: -1.0, through: 4.0, by: 0.25) {
                    let race = try Self.preStartScorerScene([(ahead, across, .starboard, share)], angle: deg2rad(angle),
                                                            toGun: 20, below: 20)
                    let brain = Self.scorerBrain(race)
                    let view = race.seatView(for: 0)
                    guard brain.canTap(view.own, view, byHand: true) else { tapless += 1; continue }
                    let (decision, scores, _) = Self.preStartScored(race, brain, tackable: true)
                    guard let decision, let tack = scores.first(where: { $0.heading == nil }) else { continue }
                    let clearing = scores.filter { $0.heading != nil && $0.margin >= 1 }
                    guard tack.margin >= BotBrain.thinMargin, !tack.early, let best = clearing.min(by: { $0.cost < $1.cost }),
                          clearing.allSatisfy({ $0.margin < BotBrain.thinMargin }) else { continue }
                    #expect(decision.tacks == (tack.cost < best.cost), "\(angle)° share \(share) ahead \(ahead), across \(across): \(decision)")
                    if decision.tacks, best.cost - BotBrain.thinMarginCost < tack.cost { decisive += 1 }
                }
            }
        }
        #expect(decisive > 0, "no crossing where the thin margin makes the tack win (\(tapless) she couldn't tap)")
    }

    /// #542 acceptance: a cluster of parked boats is decided by the tack's cost. A port bot at tacking speed (at a third
    /// of polar `canTap` refuses: #529) meets two starboard boats parked ahead of her: wherever the tack clears and costs
    /// least of the clearing courses, she tacks; and the tack is costed against them, never left out.
    @Test func preStartAClusterOfParkedBoatsIsDecidedByTheTacksCost() throws {
        var found = 0
        for ahead in stride(from: 1.5, through: 4.0, by: 0.5) {
            for across in stride(from: -1.5, through: 1.5, by: 0.5) {
                let race = try Self.preStartScorerScene([(ahead, across, .starboard, 0.02), (ahead + 1.5, across + 1.5, .starboard, 0.02)],
                                                        angle: deg2rad(45))
                let brain = Self.scorerBrain(race)
                let view = race.seatView(for: 0)
                guard brain.canTap(view.own, view, byHand: true) else { continue }
                let (decision, scores, _) = Self.preStartScored(race, brain, tackable: true)
                guard let decision else { continue }
                let tack = try #require(scores.first { $0.heading == nil }, "the tack is a candidate")
                let cheapest = scores.filter { $0.margin >= 1 }.min { $0.cost < $1.cost }
                guard let cheapest, cheapest.heading == nil, tack.margin >= 1 else { continue }
                #expect(decision.tacks, "ahead \(ahead), across \(across): \(decision)")
                found += 1
            }
        }
        #expect(found > 0, "no cluster decided by the tack")
    }

    /// #542 acceptance (Q4): before the gun an early course that clears beats a contact. Close below the line near
    /// the gun, wherever every course that clears a starboard boat is early, she takes a clearing early one, costed
    /// `earlyLineCost`, over the furthest pass that doesn't clear; and a clearing course that isn't early always beats
    /// an early one.
    @Test func preStartAnEarlyCourseThatClearsBeatsAContact() throws {
        var found = 0, ordered = 0
        for toGun in [8, 12] {
            for (ahead, across) in Self.preStartCrossings {
                let race = try Self.preStartScorerScene([(ahead, across, .starboard, 0.8)], angle: deg2rad(70),
                                                        toGun: toGun, below: 1.5)
                let brain = Self.scorerBrain(race)
                let (decision, scores, _) = Self.preStartScored(race, brain)
                guard let decision else { continue }
                let clearing = scores.filter { $0.margin >= 1 }
                if clearing.contains(where: { !$0.early }) {
                    #expect(!decision.early, "toGun \(toGun) ahead \(ahead), across \(across): \(decision)")
                    ordered += 1
                } else if !clearing.isEmpty {
                    #expect(decision.early && !decision.furthest, "toGun \(toGun) ahead \(ahead), across \(across): \(decision)")
                    found += 1
                }
            }
        }
        #expect(found > 0, "no crossing where only early courses clear")
        #expect(ordered > 0)
    }

    /// #542 acceptance: before the gun, a person's port boat is never rolled giving way (#531's rule carries over): the
    /// same boat sailed by a bot is.
    @Test func preStartAPersonsPortBoatIsNotRolledGivingWay() throws {
        let race = try Self.preStartScorerScene([(4, 2, .port, 1)], own: .starboard)
        let view = race.seatView(for: 0)
        let other = try #require(view.others.first)
        #expect(view.own.status == .prestart && view.time < 0)
        #expect(other.rightOfWay?.keepClear == 1)
        var brain = Self.scorerBrain(race)
        guard case .givesWay = brain.reaction(of: other, view.own, view) else {
            Issue.record("a bot owing her gives way: \(brain.reaction(of: other, view.own, view))")
            return
        }
        brain.humanSeats = [false, true]
        #expect(brain.reaction(of: other, view.own, view) == .measured)
    }
}
