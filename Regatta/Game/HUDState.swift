import CoreGraphics
import Foundation
import RegattaCore

/// A boat on the minimap (#114). Extensible: the rival marker (#235) adds to it.
struct MiniBoat: Identifiable, Equatable {
    let id: Int
    let position: Vec2
    let colorIndex: Int
    let isPlayer: Bool
    /// Marked by shape, not a new hue (#19): a diamond in her livery colour.
    let isBot: Bool
    /// Finished, DSQ, or still OCS or unstarted at the close (`RenderWorld.isGhost(ofSeat:)`, #30): drawn faded.
    let isGhost: Bool
}

/// A throttled snapshot of the race for the SwiftUI overlay (#114): the clock, place, the ground wind at your boat
/// and the minimap's fleet and marks. What it shows and how is `HUDModel`'s.
struct HUDState {
    /// Race clock in ticks (`Race.tick`); `clock` is the same in seconds.
    var tick = 0
    var clock = 0.0
    var status: BoatStatus = .prestart
    /// The tick the race closes on once a boat has finished, else nil (`TickFrame.closeTick`, #30).
    var closeTick: Int?
    var place = 1
    var fleet = 1
    var legNumber = 1
    var legCount = 1
    /// The wind angle she sails at (the sailing wind's); the HUD doesn't show it.
    var twaDegrees = 0.0
    /// The turn the tack button's tap will sail (#437): the sim's own choice (`Autohelm.tackOrGybe`), through the wind
    /// with it forward of the beam, through the stern abaft it, so the button's word never disagrees with the turn.
    var tapTurn: TapTurn = .tack
    /// The wind over the ground at your boat (#15): knots, and the compass direction it blows from, radians. Nobody
    /// else's shadow is in it: you read the shadow from the wakes, not the HUD (#15).
    var windKnots = 0.0
    var windDirection = 0.0
    var boats: [MiniBoat] = []
    var course: CourseLayout?
    /// The marks of the leg you're sailing, drawn orange on the minimap; the rest are grey (#22, G7).
    var activeMarks: [Vec2] = []
    /// The start (or finish) line is where you're going: before you've started, and on the finish leg.
    var lineIsActive = false
    /// The pressure over the minimap's chart, cached by `MinimapField` (#289); nil until the race holds the key.
    var pressureImage: CGImage?
    /// The live leaderboard (#268), from the latest tick's standings and gaps.
    var leaderboard = LeaderboardState()

    enum TapTurn: Equatable {
        case tack, gybe

        /// The turn a tap sails at `sailingAngle` (`Boat.sailingAngle`).
        init(sailingAngle: Double) {
            self = Autohelm.tackOrGybe(sailingAngle: sailingAngle).target == .groove(.upwind) ? .tack : .gybe
        }

        /// The tack button's word.
        var label: String { self == .tack ? "TACK" : "GYBE" }
    }

    init() {}

    /// The HUD for `world`'s latest tick, from your seat. `isBot` marks the bots on the minimap (#19): the roster's,
    /// which the simulation doesn't hold (#60).
    init(world: RenderWorld, isBot: (Int) -> Bool = { _ in false }) {
        let frame = world.frame
        let me = world.myBoatIndex
        let p = frame.boats[me]
        let course = world.course
        self.course = course
        tick = frame.tick
        clock = frame.time
        status = p.status
        closeTick = frame.closeTick
        twaDegrees = rad2deg(p.twa)
        tapTurn = TapTurn(sailingAngle: p.sailingAngle)
        // `windOverGround` is the wind at her before anyone's shadow: the HUD shows that (#15).
        windKnots = knots(metresPerSecond: p.windOverGround.speed)
        windDirection = p.windOverGround.direction
        fleet = frame.boats.count
        place = frame.place(of: me)
        leaderboard = LeaderboardState(frame: frame, me: me)
        legCount = course.legs.count
        legNumber = min(p.legIndex + 1, legCount)

        let leg = course.legSailed(status: p.status, legIndex: p.legIndex)
        if p.status == .prestart || p.status == .ocs || leg == .finish {
            lineIsActive = true
        } else {
            activeMarks = course.marksOfLeg(leg).map(\.position)
        }

        boats = frame.boats.indices.map { i in
            let boat = frame.boats[i]
            return MiniBoat(id: boat.id, position: boat.position, colorIndex: boat.colorIndex, isPlayer: i == me,
                            isBot: isBot(i), isGhost: world.isGhost(ofSeat: i))
        }
    }
}
