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
        let squared = SkiffEight.boatClass
        #expect(squared.steering.rudderDragExponent == 2)
        var dragless = squared
        dragless.steering.rudderDrag = 0
        /// The share of her speed the drag took this tick: the turn differs with the rudder, so the speed it acts on does.
        func dragShare(_ rudder: Double) -> Double {
            let before = tick(dragless, rudder: rudder).speed
            return (before - tick(squared, rudder: rudder).speed) / before
        }
        #expect(abs(dragShare(0.5) / dragShare(1) - 0.25) < 1e-12)
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
/// target, loss in hull lengths against a twin that sails on, the mean of a steady and six gusty winds). #456's
/// figures, with every helm of its sweep: best 0.943, slam 1.029, gentle gap 0.12, light-air bear-off gap 0.27, strong
/// air 0.10. Here the best is of `HandTack.Helm.best` only (full, 75 %, 50 %, smoothed), so it reads 0.971.
@Suite struct HandTackTests {
    let boat = SkiffEight.boatClass

    @Test func bestHandTackLosesLeastAtTenKnots() {
        let best = HandTack.best(boatClass: boat)
        #expect(abs(best - 0.943) <= 0.05, "best tack \(best) L")
        for helm in HandTack.Helm.best + HandTack.Helm.bear {
            #expect(best <= HandTack.loss(helm, boatClass: boat), "\(helm) loses less than the best")
        }
    }

    @Test func slamCostsMoreThanASmoothTurn() {
        let slam = HandTack.loss(.slam, boatClass: boat)
        let three = HandTack.loss(.rudder75, boatClass: boat)
        #expect(abs(slam - 1.029) <= 0.05, "slam \(slam) L")
        #expect(slam - three > 0 && slam - three <= 0.15, "75 % rudder \(three) L against the slam's \(slam)")
        let gentle = HandTack.gentleGap(boatClass: boat)
        #expect(gentle <= 0.7, "a gentle turn loses \(gentle) L beyond the best")
    }

    @Test func bearingOffFirstWinsInLightAirOnly() {
        let light = HandTack.bearOffGap(knots: 6, boatClass: boat)
        let strong = -HandTack.bearOffGap(knots: 14, boatClass: boat)
        #expect(light >= 0.25, "6 kn: bearing off first saves \(light) L")
        #expect(strong > 0, "14 kn: bearing off first costs \(strong) L (#456: 0.10, accepted under 0.15)")
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
}

/// #458 acceptance: irons recovery (`Steering.headToWindFallOffCentredRate`, the owner's ruling): let go in irons with
/// the rudder centred she gets away, and a held rudder never sees it.
///
/// #456 measured 16 s stuck for set (a), but its release helms took full rudder again whenever she fell back short of
/// their release point, holding her at the edge of the no-go (`release25Probe`): a held rudder, which by the ruling the
/// rule never touches (15.6 s with it). A rudder centred for good (`release25`, `release60`) gets her away in 2.5 s on
/// skiff@8 without the rule, 1.2 s with it at 9°/s, against 17.5 s on skiff@7.
@Suite struct IronsRecoveryTests {
    @Test func releasedInIronsGetsAwayInUnderTenSeconds() {
        for helm in [HandTack.Helm.release25, .release60] {
            let stuck = HandTack.stuck([helm], boatClass: SkiffEight.boatClass)
            #expect(stuck < 10, "\(helm): \(stuck) s")
        }
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
        #expect(b.steering.rudderDragExponent == 2 && b.steering.headToWindFallOffCentredRate == deg2rad(9))
        // Set (a): #456's findings.
        #expect(b.steering.rudderDrag == 0.267 && b.steering.topTurnRate == deg2rad(48) && b.steering.minTurnRate == deg2rad(4))
        #expect(b.steering.turnRateCurveSpeeds == [0, metresPerSecond(knots: 4.67)] && b.steering.turnRateCurveFractions == [0, 1])
        #expect(b.steering.headToWindFallOffRate == deg2rad(6) && b.steering.rudderSlew == 2)
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
