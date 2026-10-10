import Foundation
import RegattaCore
import Testing
@testable import Regatta

/// A boat's pose (#117) is derived from her sim state only, the same for every boat: heel, sail trim and side,
/// flutter, the roll cues and the ghost look.
@Suite struct BoatPoseTests {
    static let boatClass = Race.defaultBoatClass

    /// A boat on starboard tack (boom to port) at `twaDegrees` off a northerly of `windKnots`, with the given
    /// id, colour and seat kind.
    static func boat(id: Int = 1, isPlayer: Bool = false, colorIndex: Int = 1, twaDegrees: Double = 60,
                     windKnots: Double = 12, shadow: Double = 1, averageKnots: Double? = nil) -> Boat {
        var boat = Boat(id: id, isPlayer: isPlayer, colorIndex: colorIndex, position: Vec2(10, 20),
                        heading: deg2rad(-twaDegrees), speed: 4, boomSide: .port)
        boat.status = .racing
        boat.sailingWind = Wind(direction: 0, speed: metresPerSecond(knots: windKnots))
        boat.windOverGround = boat.sailingWind
        boat.apparentWind = Wind(direction: deg2rad(-twaDegrees * 0.3), speed: metresPerSecond(knots: windKnots * 1.2))
        boat.shadow = shadow
        boat.averagedWindSpeed = averageKnots.map { metresPerSecond(knots: $0) }
        return boat
    }

    /// Two boats in the same state take the same pose whatever their id, colour (livery) or whether one is yours:
    /// nothing a livery or setting holds reaches it (#22).
    @Test func sameBoatSamePoseNoLiveryInput() {
        for twa in [20.0, 45, 90, 150, 175] {
            for ease in [false, true] {
                let mine = BoatPose(Self.boat(id: 0, isPlayer: true, colorIndex: 0, twaDegrees: twa), ease: ease,
                                    isGhost: false, boatClass: Self.boatClass)
                let theirs = BoatPose(Self.boat(id: 7, isPlayer: false, colorIndex: 9, twaDegrees: twa), ease: ease,
                                      isGhost: false, boatClass: Self.boatClass)
                #expect(mine == theirs, "twa \(twa), ease \(ease)")
            }
        }
        // Ghosts too, and the roll cues.
        var a = Self.boat(id: 2, colorIndex: 3), b = Self.boat(id: 5, isPlayer: true, colorIndex: 6)
        a.roll = .missed
        b.roll = .missed
        #expect(BoatPose(a, ease: false, isGhost: false, boatClass: Self.boatClass)
                == BoatPose(b, ease: false, isGhost: false, boatClass: Self.boatClass))
        #expect(BoatPose(a, ease: false, isGhost: true, boatClass: Self.boatClass)
                == BoatPose(b, ease: false, isGhost: true, boatClass: Self.boatClass))
    }

    /// Heel never falls as the pressure rises, at any angle she sails, reaches full when overpowered on a reach,
    /// and is nothing at all while she eases (#22).
    @Test func heelMonotonicInWindZeroWhenEased() {
        for twa in [45.0, 60, 90, 120, 150] {
            var last = 0.0
            for knots in stride(from: 0.0, through: 35, by: 0.5) {
                let heel = BoatPose(Self.boat(twaDegrees: twa, windKnots: knots), ease: false, isGhost: false,
                                    boatClass: Self.boatClass).heel
                #expect(heel >= last, "twa \(twa): \(heel) at \(knots) kn after \(last)")
                #expect((0...1).contains(heel))
                last = heel
                let eased = BoatPose(Self.boat(twaDegrees: twa, windKnots: knots), ease: true, isGhost: false,
                                     boatClass: Self.boatClass)
                #expect(eased.heel == 0, "twa \(twa), \(knots) kn eased")
            }
            #expect(last > 0.4, "twa \(twa): overpowered heel \(last)")
        }
        let calm = BoatPose(Self.boat(windKnots: 2), ease: false, isGhost: false, boatClass: Self.boatClass)
        #expect(calm.heel == 0)
        let reach = BoatPose(Self.boat(twaDegrees: 90, windKnots: 30), ease: false, isGhost: false, boatClass: Self.boatClass)
        #expect(reach.heel == 1)
    }

    /// The sail sits on the boom's side, flutters eased and head to wind, not while drawing; a ghost's hangs limp
    /// amidships.
    @Test func sailFlutterSideAndGhost() {
        let drawing = BoatPose(Self.boat(twaDegrees: 60), ease: false, isGhost: false, boatClass: Self.boatClass)
        #expect(drawing.sailSide == .port && drawing.flutter == 0 && drawing.sailTrim > 0)
        #expect(BoatPose(Self.boat(twaDegrees: 60), ease: true, isGhost: false, boatClass: Self.boatClass).flutter == 1)
        #expect(BoatPose(Self.boat(twaDegrees: 20), ease: false, isGhost: false, boatClass: Self.boatClass).flutter == 1)
        let ghost = BoatPose(Self.boat(twaDegrees: 60, windKnots: 25), ease: false, isGhost: true, boatClass: Self.boatClass)
        #expect(ghost.isGhost && ghost.heel == 0 && ghost.flutter == 0 && ghost.sailTrim == 0)
        // Further off the wind, further out.
        let run = BoatPose(Self.boat(twaDegrees: 150), ease: false, isGhost: false, boatClass: Self.boatClass)
        #expect(run.sailTrim > drawing.sailTrim)
    }

    /// Starved (#220): the sail flutters when the pressure she feels is well under her own recent average, not in
    /// clean air at her average. An older class's roll (a bot's, an old log's) changes nothing drawn (#460).
    @Test func starvedFlutter() {
        let clean = BoatPose(Self.boat(averageKnots: 12), ease: false, isGhost: false, boatClass: Self.boatClass)
        #expect(clean.flutter == 0)
        let shadowed = BoatPose(Self.boat(shadow: 0.6, averageKnots: 12), ease: false, isGhost: false, boatClass: Self.boatClass)
        #expect(shadowed.flutter > 0.5)
        for roll in [RollTack.hit, .missed, .pending(tapTick: 3)] {
            var rolled = Self.boat(shadow: 0.6, averageKnots: 12)
            rolled.roll = roll
            #expect(BoatPose(rolled, ease: false, isGhost: false, boatClass: Self.boatClass) == shadowed, "\(roll)")
        }
    }

    /// By the lee the boom is to windward: the sail stays on the boom's side, out as far as it goes with a small
    /// flutter, while her heel and drop shadow go to leeward, the other side.
    @Test func byTheLeeSailOnTheBoomHeelToLeeward() {
        let style = BoatStyle.standard
        // Running on starboard (wind over starboard, 170° off the bow), boom to port: not by the lee.
        let running = BoatPose(Self.boat(twaDegrees: 170, windKnots: 20), ease: false, isGhost: false,
                               boatClass: Self.boatClass)
        #expect(running.sailSide == .port && running.leeSide == .port)
        // The same wind with the boom to starboard: 10° by the lee.
        var lee = Self.boat(twaDegrees: 170, windKnots: 20)
        lee.boomSide = .starboard
        #expect(lee.isByTheLee)
        let pose = BoatPose(lee, ease: false, isGhost: false, boatClass: Self.boatClass)
        #expect(pose.sailSide == .starboard, "the sail is on the boom's side")
        #expect(pose.leeSide == .port, "the heel shadow falls to leeward, away from the boom")
        #expect(pose.flutter == style.byTheLeeFlutter)
        #expect(pose.sailTrim == deg2rad(style.maxTrimDegrees))
        #expect(pose.heel > 0)
        // Normal sailing, the lee side is the boom's.
        let reach = BoatPose(Self.boat(twaDegrees: 90), ease: false, isGhost: false, boatClass: Self.boatClass)
        #expect(reach.leeSide == reach.sailSide)
    }

    /// The heel gain acts past 1: heel is capped after it, so close-hauled, where `sin(twa)` keeps her under full
    /// heel, a gain of 2 heels her more (why its slider runs to 2).
    @Test func heelScaleAboveOneStillHeelsMore() {
        var double = BoatStyle.standard
        double.heelScale = 2
        let boat = Self.boat(twaDegrees: 45, windKnots: 16)
        let one = BoatPose(boat, ease: false, isGhost: false, boatClass: Self.boatClass).heel
        let two = BoatPose(boat, ease: false, isGhost: false, boatClass: Self.boatClass, style: double).heel
        #expect(one > 0 && one < 1 && two > one)
    }

    /// A saved style missing fields keeps the rest (the tuning panel's lenient decode).
    @Test func styleDecodesLeniently() throws {
        let style = try JSONDecoder().decode(BoatStyle.self, from: Data(#"{"heelScale":1.5}"#.utf8))
        var expected = BoatStyle.standard
        expected.heelScale = 1.5
        #expect(style == expected)
        #expect(try JSONDecoder().decode(BoatStyle.self, from: JSONEncoder().encode(expected)) == expected)

        // Every field is in the decoder's list (#121's wake, cone and art values too): a style with every value
        // moved off its standard comes back whole.
        let standard = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(BoatStyle.standard)) as? [String: Double])
        let moved = standard.mapValues { $0 + 0.25 }
        let decoded = try JSONDecoder().decode(BoatStyle.self, from: JSONSerialization.data(withJSONObject: moved))
        let back = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Double])
        #expect(back == moved, "fields the lenient decoder drops: \(moved.keys.filter { back[$0] != moved[$0] }.sorted())")
    }
}
