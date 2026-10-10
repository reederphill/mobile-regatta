import Foundation
import Testing
@testable import RegattaCore

/// skiff@8 (#458) and the files before it.
enum SkiffEight {
    static let file = try! BoatClassFile.bundled(id: "skiff", version: 8)
    static var boatClass: BoatClass { file.content }
    static let seven = try! BoatClassFile.bundled(id: "skiff", version: 7)
}

/// #458 acceptance: M1, the rudder drag as a power of the rudder (`Steering.rudderDragExponent`).
@Suite struct RudderDragExponentTests {
    /// One tick from close-hauled with the rudder already at `rudder` and held there: no slew, the same turn.
    func tick(_ boatClass: BoatClass, rudder: Double) -> BoatDynamics.State {
        let tws = metresPerSecond(knots: 10)
        let angle = boatClass.polar.bestUpwind(tws: tws).twa
        let state = BoatDynamics.State(heading: -angle, speed: boatClass.polar.bestUpwind(tws: tws).speed, rudder: rudder)
        return BoatDynamics.advance(state, control: .init(rudder: rudder), env: .constant(windDirection: 0, windSpeed: tws),
                                    boatClass: boatClass, dt: Race.dt)
    }

    @Test func exponentOneIsTheLinearDragBitForBit() throws {
        let stock = SkiffEight.seven.content
        let written = try BoatClassFile(data: SkiffFixtures.edited(
            [(of: #""rudderDragPerSecond": 0.25,"#, with: #""rudderDragPerSecond": 0.25, "rudderDragExponent": 1,"#)], version: 7),
            tune: 1).content
        #expect(written.steering.rudderDragExponent == 1 && written == stock)
        for rudder in [0.0, 0.3, -0.5, 0.75, 1] {
            #expect(tick(written, rudder: rudder) == tick(stock, rudder: rudder))
        }
        // Over a whole slam, too.
        #expect(HandTack.run(.slam, .init(knots: 10, entry: 1), boatClass: written).loss25
                == HandTack.run(.slam, .init(knots: 10, entry: 1), boatClass: stock).loss25)
    }

    @Test func exponentTwoQuartersHalfRudderDrag() throws {
        let cubed = SkiffEight.boatClass
        #expect(cubed.steering.rudderDragExponent == 3)
        var squared = cubed
        squared.steering.rudderDragExponent = 2
        var dragless = squared
        dragless.steering.rudderDrag = 0
        /// The share of her speed the drag took this tick: the turn differs with the rudder, so the speed it acts on does.
        func dragShare(_ rudder: Double, _ boat: BoatClass? = nil) -> Double {
            let before = tick(dragless, rudder: rudder).speed
            return (before - tick(boat ?? squared, rudder: rudder).speed) / before
        }
        #expect(abs(dragShare(0.5) / dragShare(1) - 0.25) < 1e-12)
        // skiff@8's cube: an eighth.
        #expect(abs(dragShare(0.5, cubed) / dragShare(1, cubed) - 0.125) < 1e-12)
        var linear = squared
        linear.steering.rudderDragExponent = 1
        #expect(tick(squared, rudder: 1) == tick(linear, rudder: 1))
        #expect(tick(squared, rudder: -1) == tick(linear, rudder: -1))
    }

    @Test func exponentBelowOneIsRejected() throws {
        for bad in ["0.5", "0", "-1"] {
            let data = try SkiffFixtures.edited(
                [(of: #""rudderDragPerSecond": 0.25,"#, with: #""rudderDragPerSecond": 0.25, "rudderDragExponent": \#(bad),"#)],
                version: 7)
            #expect(throws: DataFileError.self, "\(bad)") { try BoatClassFile(data: data, tune: 1) }
        }
    }
}

/// #458 acceptance: tacking by hand on skiff@8, measured as #456 did (`HandTack`: 10 kn unless said, entry at the groove
/// target, loss in hull lengths against a twin that sails on, the mean of a steady and six gusty winds), on the owner's
/// rulings of 2026-10-09 (rudder drag 0.416 with the cube of the rudder, an 8°/s turn-rate floor) and 2026-10-10 (#461:
/// fall-off 2°/s, the turn-rate curve's knee at 1.15 kn): the best tack is a moderate rudder, 0.951 L at 50 % (0.954 at
/// 60 %), and a slam loses 1.504, 0.55 more; 75 % rudder 1.083, 25 % 1.96. Before the second ruling: 0.950, 1.481, 1.075
/// and 1.83.
@Suite struct HandTackTests {
    let boat = SkiffEight.boatClass

    @Test func bestHandTackLosesLeastAtTenKnots() {
        let best = HandTack.best(boatClass: boat)
        #expect(abs(best - 0.95) <= 0.05, "best tack \(best) L")
        for helm in HandTack.Helm.best + HandTack.Helm.bear + [.rudder60, .rudder25] {
            #expect(best <= HandTack.loss(helm, boatClass: boat), "\(helm) loses less than the best")
        }
        // The best helm is a moderate rudder: half, with 60 % as good to a few hundredths.
        let half = HandTack.loss(.rudder50, boatClass: boat), sixty = HandTack.loss(.rudder60, boatClass: boat)
        #expect(abs(half - best) <= 0.02 && abs(sixty - best) <= 0.03, "50 % \(half) L, 60 % \(sixty) L, best \(best)")
    }

    @Test func slamCostsHalfALengthMoreThanTheBestTack() {
        let best = HandTack.best(boatClass: boat)
        let slam = HandTack.loss(.slam, boatClass: boat)
        let three = HandTack.loss(.rudder75, boatClass: boat)
        let quarter = HandTack.loss(.rudder25, boatClass: boat)
        #expect((0.4...0.65).contains(slam - best), "slam \(slam) L against the best's \(best)")
        #expect(abs(slam - 1.504) <= 0.05, "slam \(slam) L")
        // 75 % rudder sits between the two, and a very gentle turn is no answer either.
        #expect(three > best + 0.05 && three < slam - 0.2, "75 % rudder \(three) L between \(best) and \(slam)")
        #expect(abs(three - 1.083) <= 0.05, "75 % rudder \(three) L")
        #expect(quarter > best + 0.4, "25 % rudder \(quarter) L against the best's \(best)")
        let gentle = HandTack.gentleGap(boatClass: boat)
        #expect(gentle <= 0.7, "a gentle turn loses \(gentle) L beyond the best")
    }

    @Test func bearingOffFirstWinsInLightAirOnly() {
        let light = HandTack.bearOffGap(knots: 6, boatClass: boat)
        let strong = -HandTack.bearOffGap(knots: 14, boatClass: boat)
        #expect(light >= 0.25, "6 kn: bearing off first saves \(light) L")
        #expect(strong > 0, "14 kn: bearing off first costs \(strong) L (0.10; #456: 0.10, accepted under 0.15)")
        #expect(strong < 0.15, "14 kn: bearing off first costs \(strong) L")
    }

    /// The longest a slam leaves her under 30 % of her target inside the no-go, over 6, 10 and 14 kn, `entries` of her
    /// groove speed and the seven winds.
    func worstSlamStuck(_ boat: BoatClass, entries: [Double] = [0.7, 0.75, 1]) -> Double {
        var worst = 0.0
        for knots in [6.0, 10, 14] {
            for entry in entries {
                for cell in HandTack.Cell.all(knots: knots, entry: entry) {
                    worst = max(worst, HandTack.run(.slam, cell, boatClass: boat).stuck)
                }
            }
        }
        return worst
    }

    @Test func hardTurnNeverStallsInIrons() {
        for knots in [6.0, 10, 14] {
            for entry in [0.7, 1] {
                for cell in HandTack.Cell.all(knots: knots, entry: entry) {
                    let stuck = HandTack.run(.slam, cell, boatClass: boat).stuck
                    #expect(stuck <= 5, "\(cell): \(stuck) s under 30 % of target in the no-go")
                }
            }
        }
    }

    /// The stall cliff's margin. A slam's drag takes her way off before she is through the wind; past a point she
    /// stops short of it and sits there (23 s of the 25: on the first ruling's values, drag 0.44 on set (a)'s 4°/s floor).
    /// Since #461's retune (fall-off 2°/s, the turn-rate curve's knee) no slam is near it: the worst sticks 2.8 s (3.4
    /// before), 5 % more drag 3.1 s, the 4°/s floor with it 4.2 s, half as much drag again 4.6 s. The hang the measure
    /// still sees is too little rudder in light air (a quarter rudder in 4 kn: 17.6 s), which the owner accepts.
    @Test func slamStaysClearOfTheStallCliff() {
        let worst = worstSlamStuck(boat)
        #expect(worst <= 5, "worst slam: \(worst) s stuck")
        #expect(abs(worst - 2.83) <= 0.5, "worst slam: \(worst) s stuck (re-pin: the margin moved)")
        var more = boat
        more.steering.rudderDrag *= 1.05
        #expect(worstSlamStuck(more) <= 5, "5 % more rudder drag: \(worstSlamStuck(more)) s stuck")
        var steeper = boat
        steeper.steering.rudderDragExponent = 3.25
        #expect(worstSlamStuck(steeper) <= 5, "exponent 3.25: \(worstSlamStuck(steeper)) s stuck")
        // Where the cliff was before the retune (23 s), and well past it.
        var low = more
        low.steering.minTurnRate = deg2rad(4)
        #expect(worstSlamStuck(low) <= 5, "drag 0.44 on a 4°/s floor: \(worstSlamStuck(low)) s stuck")
        var draggy = boat
        draggy.steering.rudderDrag *= 1.5
        #expect(worstSlamStuck(draggy) <= 5, "half as much drag again: \(worstSlamStuck(draggy)) s stuck")
        // A hang itself, so the guard is known to see one: a quarter rudder in 4 kn.
        let hung = HandTack.Cell.all(knots: 4, entry: 0.75).map {
            HandTack.turn(gybe: false, fraction: 0.25, cell: $0, boatClass: boat).stuck
        }.max()!
        #expect(hung > 10, "25 % rudder in 4 kn: \(hung) s stuck")
    }
}

/// #461, the owner's ruling of 2026-10-10 (fall-off 2°/s against a held rudder, the turn-rate curve's knee at 1.15 kn):
/// about 2 kn of boat speed is enough to complete a tack, and a penalty turn from a standstill is no death knell.
@Suite struct FallOffRetuneTests {
    let boat = SkiffEight.boatClass
    static let twoKnots = metresPerSecond(knots: 2)

    /// Seconds until she is out on the new tack from `speed` at the edge of the no-go, the worst of 6 and 10 kn's
    /// seven winds, and whether every one carried her through without falling back out first.
    func carry(_ fraction: Double, speed: Double) -> (out: Double, clean: Bool) {
        let runs = [6.0, 10].flatMap { HandTack.Cell.all(knots: $0) }.map {
            HandTack.carry(fraction: fraction, cell: $0, speed: speed, boatClass: boat)
        }
        return (runs.map(\.out).max()!, runs.allSatisfy(\.clean))
    }

    /// From 2 kn at the edge of the no-go a held rudder of 40 % and up completes the tack: 19.7 s at 40 %, 9.4 s at
    /// 60 %, 6.3 s hard over (before the retune: never, never, 11.1 s).
    @Test func twoKnotsAtTheNoGoEdgeCompletesTheTack() {
        for (fraction, limit, pinned) in [(0.4, 25.0, 19.7), (0.5, 20, nil), (0.6, 12, 9.4), (0.75, 10, nil), (1, 8, 6.3)] {
            let run = carry(fraction, speed: Self.twoKnots)
            #expect(run.clean && run.out <= limit, "\(fraction) rudder from 2 kn: out in \(run.out) s, clean \(run.clean)")
            if let pinned { #expect(abs(run.out - pinned) <= 1, "\(fraction) rudder from 2 kn: \(run.out) s (re-pin)") }
        }
    }

    /// Below 2 kn the same tack is slower, not failed: from 1 kn 37 s at 40 %, 17 s at 60 %, 8.7 s hard over.
    @Test func oneKnotAtTheNoGoEdgeIsSlowNotStuck() {
        let one = metresPerSecond(knots: 1)
        for (fraction, limit) in [(0.4, 45.0), (0.6, 22), (1, 11)] {
            let slow = carry(fraction, speed: one), enough = carry(fraction, speed: Self.twoKnots)
            #expect(slow.out <= limit, "\(fraction) rudder from 1 kn: out in \(slow.out) s")
            #expect(slow.out > enough.out, "\(fraction) rudder: 1 kn \(slow.out) s against 2 kn's \(enough.out)")
        }
    }

    /// A penalty-style circle, tack first at 70 % rudder (`HandTackTable.penaltyFraction`): in 6 kn 15.3 s from the
    /// groove, 21.3 s from 2 kn and 25.3 s from a standstill (before the retune 15.1 / 44.9 / 51.8); in 10 kn 21.6 s
    /// from a standstill (44.7). Every one of the seven winds inside 30 s.
    @Test func penaltyTurnFromAStandstillCompletes() {
        for knots in [6.0, 10] {
            for (speed, name) in [(nil, "the groove"), (Self.twoKnots, "2 kn"), (0.0, "a standstill")] as [(Double?, String)] {
                let times = HandTack.Cell.all(knots: knots).map {
                    HandTack.circle(fraction: 0.7, cell: $0, speed: speed, boatClass: boat)
                }
                #expect(times.max()! <= 30, "\(knots) kn from \(name): worst \(times.max()!) s")
            }
        }
        func mean(_ knots: Double, _ speed: Double?) -> Double {
            HandTack.mean(HandTack.Cell.all(knots: knots)) { HandTack.circle(fraction: 0.7, cell: $0, speed: speed, boatClass: boat) }
        }
        for (knots, speed, pinned) in [(6.0, nil, 15.3), (6, Self.twoKnots, 21.3), (6, 0, 25.3), (10, 0, 21.6)] as [(Double, Double?, Double)] {
            let seconds = mean(knots, speed)
            #expect(abs(seconds - pinned) <= 1.5, "\(knots) kn from \(speed.map { "\($0) m/s" } ?? "the groove"): \(seconds) s (re-pin)")
        }
    }
}

/// #458 acceptance: irons recovery (`Steering.headToWindFallOffCentredRate`, the owner's ruling): let go in irons with
/// the rudder centred she gets away, and a held rudder never sees it.
///
/// #456 measured 16 s stuck for set (a), but its release helms took full rudder again whenever she fell back short of
/// their release point, holding her at the edge of the no-go (`release25Probe`): a held rudder, which by the ruling the
/// rule never touches. A rudder centred for good (`release25`, `release60`) gets her away in 1.4 s on skiff@8 with the
/// rule at 9°/s (2.3 s let go a quarter of the way round, 0.4 s at 60 %), against 17.5 s on skiff@7.
@Suite struct IronsRecoveryTests {
    @Test func releasedInIronsGetsAwayInUnderTenSeconds() {
        for helm in [HandTack.Helm.release25, .release60] {
            let stuck = HandTack.stuck([helm], boatClass: SkiffEight.boatClass)
            #expect(stuck < 10, "\(helm): \(stuck) s")
        }
        let mean = HandTack.stuck(boatClass: SkiffEight.boatClass)
        #expect(abs(mean - 1.36) <= 0.3, "released in irons: \(mean) s (re-pin)")
        // skiff@7 sails as before #458.
        let before = HandTack.stuck(boatClass: SkiffEight.seven.content)
        #expect(abs(before - 17.466666666667) < 1e-9, "skiff@7: \(before) s")
    }

    @Test func heldRudderTackTermsUnchanged() {
        let on = SkiffEight.boatClass
        var off = on
        off.steering.headToWindFallOffCentredRate = nil
        #expect(on.steering.headToWindFallOffCentredRate == deg2rad(9))
        #expect(HandTack.best(boatClass: on) == HandTack.best(boatClass: off))
        #expect(HandTack.loss(.slam, boatClass: on) == HandTack.loss(.slam, boatClass: off))
        #expect(HandTack.gentleGap(boatClass: on) == HandTack.gentleGap(boatClass: off))
        #expect(HandTack.bearOffGap(knots: 6, boatClass: on) == HandTack.bearOffGap(knots: 6, boatClass: off))
    }
}

/// #458: skiff@8, tacking and gybing by hand, and the files before it unchanged.
@Suite struct SkiffEightTests {
    @Test func skiffEightHasNoRollTack() throws {
        let file = SkiffEight.file
        let (a, b) = (SkiffEight.seven.content, file.content)
        #expect(file.schemaVersion == 4 && file.id == "skiff" && file.version == 8)
        #expect(b.rollTack == nil && a.rollTack != nil)
        #expect(!file.header.placeholders.contains("/rollTack"))
        #expect(!b.steering.autohelm.sailsTap && !b.steering.autohelm.holdsWhenCentred)
        #expect(b.steering.rudderDragExponent == 3 && b.steering.headToWindFallOffCentredRate == deg2rad(9))
        // Set (a), #456's findings, with the owner's ruling of 2026-10-09: drag 0.416 cubed, an 8°/s floor.
        #expect(b.steering.rudderDrag == 0.416 && b.steering.topTurnRate == deg2rad(48) && b.steering.minTurnRate == deg2rad(8))
        // #461, the owner's ruling of 2026-10-10: fall-off 2°/s (6), and the turn-rate curve's knee at 1.15 kn (a line
        // from 0 to 4.67 kn before); above 2 kn it is that line still.
        #expect(b.steering.turnRateCurveSpeeds == [0, 0.9, 1.15, 2, 4.67].map { metresPerSecond(knots: $0) })
        #expect(b.steering.turnRateCurveFractions == [0, 0.1667, 0.428, 0.428, 1])
        #expect(abs(b.steering.turnRate(speed: metresPerSecond(knots: 3.3)) - deg2rad(48) * 3.3 / 4.67) < deg2rad(0.02))
        #expect(b.steering.headToWindFallOffRate == deg2rad(2) && b.steering.rudderSlew == 2)
        #expect(b.momentum.speedingUp == 4.5 && b.momentum.slowingDown == 14 && b.momentum.noGo == 5.79)
        // Everything else is skiff@7's.
        #expect(b.name == a.name && b.hull == a.hull && b.polar == a.polar && b.windShadow == a.windShadow)
        #expect(b.contact == a.contact && b.ease == a.ease && b.planing == a.planing && b.spinnaker == a.spinnaker)
        #expect(b.byTheLee == a.byTheLee)
        var autohelm = b.steering.autohelm
        autohelm.sailsTap = true
        #expect(autohelm == a.steering.autohelm)
    }

    @Test func olderClassesLoadUnchanged() throws {
        let files = try (1...7).map { try BoatClassFile.bundled(id: "skiff", version: $0) }
            + (3...5).map { try BoatClassFile.bundled(id: "ilca-dinghy", version: $0) } // 1 and 2 are schema 1: not sailed
        for file in files {
            let steering = file.content.steering
            #expect(steering.rudderDragExponent == 1, "\(file.id)@\(file.version)")
            #expect(steering.autohelm.sailsTap, "\(file.id)@\(file.version)")
            #expect(steering.headToWindFallOffCentredRate == nil && steering.ironsFallOffRate == steering.headToWindFallOffRate,
                    "\(file.id)@\(file.version)")
        }
    }

    @Test func newValuesDecodeAndValidate() throws {
        func load(_ members: String) throws -> BoatClass {
            try BoatClassFile(data: SkiffFixtures.edited(
                [(of: #""holdsWhenCentred": false"#, with: #""holdsWhenCentred": false, \#(members)"#)], version: 7), tune: 1).content
        }
        #expect(try load(#""sailsTap": 0"#).steering.autohelm.sailsTap == false)
        #expect(try load(#""sailsTap": true"#).steering.autohelm.sailsTap)
        #expect(throws: DataFileError.self) { try load(#""sailsTap": 2"#) }
        let base = try SkiffFixtures.edited(
            [(of: #""rudderDragPerSecond": 0.25,"#, with: #""rudderDragPerSecond": 0.25, "headToWindFallOffCentredDegreesPerSecond": -1,"#)],
            version: 7)
        #expect(throws: DataFileError.self) { try BoatClassFile(data: base, tune: 1) }
        // A tuned copy writes numbers.
        let readied = TunedCopy.readyingFlag(at: "/steering/autohelm/sailsTap", in: try SkiffFixtures.bytes(version: 8),
                                             absent: 1, schemaVersion: 4)
        let tuned = try TunedCopy.make(BoatClass.self, base: readied,
                                       values: ["/steering/headToWindFallOffCentredDegreesPerSecond": 15,
                                                "/steering/rudderDragExponent": 1.5,
                                                "/steering/autohelm/sailsTap": 1], tune: 2)
        let content = tuned.file.content
        #expect(content.steering.headToWindFallOffCentredRate == deg2rad(15) && content.steering.rudderDragExponent == 1.5)
        #expect(content.steering.autohelm.sailsTap)
    }
}

/// #458 acceptance: on skiff@8 the tack/gybe tap is logged and does nothing else.
@Suite struct TapOnSkiffEightTests {
    /// Two twin races on `file`, one tapped 1 s in; both sailed 4 s. The tapped race, and both races' events.
    func twins(_ file: BoatClassFile) throws -> (tapped: Race, plain: Race, tappedEvents: [RaceEvent.Kind], plainEvents: [RaceEvent.Kind]) {
        let tapped = try OpenWater.race(knots: 10, boatClassFile: file)
        let plain = try OpenWater.race(knots: 10, boatClassFile: file)
        var tappedEvents: [RaceEvent.Kind] = [], plainEvents: [RaceEvent.Kind] = []
        for race in [tapped, plain] { for _ in 0..<Race.tickRate { race.step() } }
        _ = tapped.drainEvents()
        _ = plain.drainEvents()
        tapped.tap(.tackGybe, seat: 0, atTick: tapped.tick + 1)
        for _ in 0..<(3 * Race.tickRate) {
            tapped.step()
            plain.step()
            tappedEvents += tapped.drainEvents().map(\.kind)
            plainEvents += plain.drainEvents().map(\.kind)
        }
        return (tapped, plain, tappedEvents, plainEvents)
    }

    @Test func tackGybeTapIsLoggedAndIgnored() throws {
        let eight = try twins(SkiffEight.file)
        #expect(eight.tapped.boats[0].heading == eight.plain.boats[0].heading)
        #expect(eight.tapped.boats[0].rudder == eight.plain.boats[0].rudder)
        #expect(eight.tapped.boats[0].autohelm == nil && eight.tapped.boats[0].roll == nil)
        #expect(eight.tappedEvents == eight.plainEvents)
        let inputs = try #require(eight.tapped.log).inputs
        #expect(inputs.contains { $0.seat == 0 && $0.kind == .tap(.tackGybe) })

        // On skiff@7 the same tap still sails the autohelm's turn.
        let seven = try twins(SkiffEight.seven)
        #expect(seven.tapped.boats[0].boomSide != seven.plain.boats[0].boomSide)
        #expect(seven.tappedEvents.contains(.tacked(seat: 0)))
    }
}

/// #459: the hand turn a bot steers (`BotBrain.handTurning`, its rudder from `HandTackTable` in RegattaBots), measured
/// on skiff@8 as #458 measured the tack (`HandTack.turn`): the anchors that table's placeholders stand on, on the
/// owner's rulings of 2026-10-09 (#458: the rudder drag cubed) and 2026-10-10 (#461: fall-off 2°/s, the turn-rate
/// curve's knee at 1.15 kn).
@Suite struct HandTurnProfileTests {
    let boat = SkiffEight.boatClass

    func loss(gybe: Bool = false, _ fraction: Double, ease: Double = 0, over: Double = 0, knots: Double = 10,
              entry: Double = 1) -> Double {
        HandTack.mean(HandTack.Cell.all(knots: knots, entry: entry)) {
            HandTack.turn(gybe: gybe, fraction: fraction, ease: ease, over: over, cell: $0, boatClass: boat).loss
        }
    }

    func stuck(_ fraction: Double, over: Double = 0, knots: Double, entry: Double) -> Double {
        HandTack.Cell.all(knots: knots, entry: entry).map {
            HandTack.turn(gybe: false, fraction: fraction, over: over, cell: $0, boatClass: boat).stuck
        }.max()!
    }

    /// The good helm's tack (60 % rudder, eased over the last 20°) is #458's best to 0.01 L, Club's centre's (77 %)
    /// a tenth more, and a slam half a length more: means over the seven winds, whose six gusty ones shift under her.
    /// In the steady wind alone, as a bot's tack measured against a twin from each tack in turn reads
    /// (`BotHandTackTests.tackLossFallsWithHandlingOnSkiffEight`), the good turn loses about 1.30 L at 10 kn.
    @Test func goodTackIsTheBestAndASlamCostsMore() {
        let good = loss(0.6, ease: 20), club = loss(0.77, ease: 8), slam = loss(1)
        #expect(abs(good - 0.96) <= 0.05, "60 % eased: \(good) L")
        #expect(abs(slam - 1.50) <= 0.05, "slam: \(slam) L")
        #expect(good < club && club < slam - 0.2, "Club's centre: \(club) L")
        #expect((0.4...0.65).contains(slam - good))
        let steady = HandTack.turn(gybe: false, fraction: 0.6, ease: 20, cell: .init(knots: 10, entry: 1, seed: nil), boatClass: boat).loss
        #expect(abs(steady - 1.30) <= 0.05, "60 % eased in the steady wind: \(steady) L")
    }

    /// A gybe is cheaper the less rudder she holds: 0.33 L at 30 %, 1.17 at full (10 kn).
    @Test func gentleGybeCostsLeast() {
        let gentle = loss(gybe: true, 0.3), half = loss(gybe: true, 0.5), slam = loss(gybe: true, 1)
        #expect(abs(gentle - 0.33) <= 0.1, "30 %: \(gentle) L")
        #expect(abs(slam - 1.17) <= 0.1, "full: \(slam) L")
        #expect(gentle < half && half < slam)
    }

    /// A flubbed turn costs lengths, never a stall. Over-steered 20° to 30°, a good helm's tack loses about 1.14 to
    /// 1.53 L (0.95 clean) and a slam 1.95 to 2.32 (1.50); a cranked gybe 1.63 to 1.96. Under-steered at 35 % rudder, in the breeze she
    /// under-steers in (over 8 kn; `HandTackTable.underSteer`), a tack loses about 1.25 L. From the slowest she tacks at, none of them leaves her
    /// stuck 5 s. Before #461's retune 35 % in light air did (19 s in 6 kn), which is why she never under-steers there;
    /// since it 35 % in 6 kn is 2.8 s and the hang is a quarter rudder in 4 kn (17.6 s).
    @Test func flubbedTurnCostsLengthsNeverAStall() {
        let good = loss(0.6), slam = loss(1)
        for (fraction, over, range) in [(0.6, 20.0, 1.0...1.3), (0.6, 30, 1.4...1.65), (1, 20, 1.8...2.05), (1, 30, 2.2...2.45)] {
            let lost = loss(fraction, over: over)
            #expect(range.contains(lost), "tack at \(fraction) over \(over)°: \(lost) L")
            #expect(lost > (fraction < 1 ? good : slam) + 0.15)
        }
        for (over, range) in [(20.0, 1.5...1.75), (30, 1.85...2.1)] {
            let gybe = loss(gybe: true, 1, over: over)
            #expect(range.contains(gybe), "gybe cranked \(over)° past: \(gybe) L")
        }
        let under = loss(0.35)
        #expect((1.1...1.35).contains(under) && under > good + 0.2, "under-steered: \(under) L against \(good)")
        for knots in [6.0, 10, 14] {
            for (fraction, over) in [(0.6, 0.0), (0.6, 30), (1, 30)] {
                let spell = stuck(fraction, over: over, knots: knots, entry: 0.75)
                #expect(spell <= 5, "\(knots) kn at \(fraction) over \(over)°: \(spell) s stuck")
            }
        }
        for knots in [8.0, 10, 14] {
            let spell = stuck(0.35, knots: knots, entry: 0.75)
            #expect(spell <= 5, "\(knots) kn under-steered: \(spell) s stuck")
        }
        // The cliff she kept off before #461's retune is gone (19 s); too little rudder in less wind still hangs her.
        #expect(stuck(0.35, knots: 6, entry: 0.75) <= 5)
        #expect(stuck(0.25, knots: 4, entry: 0.75) > 10)
    }
}
