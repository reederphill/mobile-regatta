/// The side opposite the boom (#9): a boat changes tack only by tacking or gybing, never by just
/// sailing by the lee.
public enum Tack: Sendable {
    case port
    case starboard
}

/// Which side of the boat the boom is on (#14). It crosses only when she tacks or gybes
/// (`BoatDynamics.advance`).
public enum BoomSide: Sendable, Hashable {
    case port
    case starboard

    public var opposite: BoomSide { self == .port ? .starboard : .port }

    /// The boom blown to leeward by a wind `relativeWind` off the bow (positive = over the starboard
    /// side, so the boom goes to port). Exactly head to wind or dead downwind counts as over starboard.
    public static func leeward(ofRelativeWind relativeWind: Double) -> BoomSide {
        relativeWind >= 0 ? .port : .starboard
    }

    /// +1 when the boom is to port (starboard tack), −1 to starboard: the sign of the relative wind
    /// when she sails with the boom to leeward.
    var windSign: Double { self == .port ? 1 : -1 }

    /// The wind's angle off the bow as the boom sees it, −π ..< π: positive with the wind on the side
    /// away from the boom (normal sailing), negative with it on the boom's side (near head to wind the
    /// boom is about to cross; near dead downwind she is sailing by the lee).
    public func sailingAngle(relativeWind: Double) -> Double { wrapAngle(windSign * relativeWind) }

    /// Whether a sailing angle is by the lee: the wind on the boom's side and aft of the beam, but
    /// not exactly dead downwind (−π).
    static func isByTheLee(_ sailingAngle: Double) -> Bool { sailingAngle < -.pi / 2 && sailingAngle > -.pi }
}

public enum BoatStatus: Sendable, Equatable {
    /// Before the gun, or after it but not yet started.
    case prestart
    /// Some of her hull on the course side at the gun (#85, rule 29.1); must return until all of it is on
    /// the pre-start side of the line or its extensions. Returning (rule 21.1) while she sails back towards
    /// it: `CourseLayout.isReturning`.
    case ocs
    case racing
    case finished
    /// Finished with an unserved penalty.
    case dsq
    case dnf
}

public struct Boat: Identifiable, Sendable {
    public let id: Int
    public let isPlayer: Bool
    public let colorIndex: Int

    public var position: Vec2
    /// Compass heading in radians.
    public var heading: Double
    /// Metres per second through the water.
    public var speed: Double
    /// Actual rudder, -1 (hard to port) … +1 (hard to starboard).
    public var rudder = 0.0
    /// Rudder the helm is asking for: the held input's off centre, else the autohelm's.
    public var desiredRudder = 0.0
    /// Which side the boom is on; her tack is the other side.
    public var boomSide: BoomSide
    /// What steers her while the held rudder is centred (ADR 0007): the wind angle or groove it holds,
    /// and the tack/gybe tap it may be sailing (#13). Nil while the rudder is held off centre.
    public var autohelm: Autohelm?

    public var status: BoatStatus = .prestart
    public var legIndex = 0
    public var roundingStage = 0

    public var penaltyTurnsOwed = 0
    /// Signed radians turned since the current penalty was incurred.
    public var penaltyProgress = 0.0
    /// Rule 13: past head to wind but not yet close-hauled.
    public var isTacking = false
    /// On the plane (#248, `BoatClass.planing`): set by `BoatDynamics.advance`, never for a class that
    /// doesn't plane. For drawing (#117, #121) as much as for her speed.
    public var isPlaning = false
    /// Her automatic spinnaker (#248, `BoatClass.spinnaker`): down, going up, up or coming down. Always
    /// down for a class without one. For drawing (#120) as much as for her speed.
    public var spinnaker = Spinnaker.down
    /// The class's running average of the wind speed her polar reads (`polarWindSpeed`), m/s: what her
    /// autohelm's grooves follow (#245, `grooveWindSpeed`). Nil until the race first samples her wind.
    /// With no average (`AutohelmTuning.grooveWindAverage` 0, every schema-2 class) it is the wind right now.
    public var averagedWindSpeed: Double?

    /// Wind over the ground at the boat (`BoatWinds`): what readouts show (#15).
    public var windOverGround = Wind.calm
    /// The wind she sails in, over the water (`BoatWinds`): what the polar, her wind angle and her tack read (#14).
    public var sailingWind = Wind.calm
    /// The wind her sails feel (`BoatWinds`): what her wind shadow follows (#10).
    public var apparentWind = Wind.calm
    /// Current at the boat, m/s, the way the water moves: it carries her over the ground whatever she
    /// does (#11). Sampled with the winds at the start of every step.
    public var current = Vec2.zero
    /// Multiplier from other boats' wind shadow and backwind on the sailing wind's speed, 1 = clean air.
    public var shadow = 1.0

    public var finishTime: Double?
    public var place: Int?

    public init(id: Int, isPlayer: Bool, colorIndex: Int, position: Vec2, heading: Double, speed: Double,
                boomSide: BoomSide = .port) {
        self.id = id
        self.isPlayer = isPlayer
        self.colorIndex = colorIndex
        self.position = position
        self.heading = heading
        self.speed = speed
        self.boomSide = boomSide
    }

    /// Where the sailing wind blows from, radians.
    public var windDirection: Double {
        get { sailingWind.direction }
        set { sailingWind.direction = newValue }
    }
    /// The sailing wind's speed, m/s, before any shadow.
    public var windSpeed: Double {
        get { sailingWind.speed }
        set { sailingWind.speed = newValue }
    }
    /// The wind speed her polar reads, m/s: the sailing wind's, slowed by any shadow (#10, #14).
    public var polarWindSpeed: Double { sailingWind.speed * shadow }
    /// The wind speed her autohelm's grooves read, m/s: the class's average of `polarWindSpeed`
    /// (`averagedWindSpeed`), or the wind right now before the race has sampled it.
    public var grooveWindSpeed: Double { averagedWindSpeed ?? polarWindSpeed }

    /// Sailing wind direction relative to the bow; positive = wind over the starboard side.
    public var relativeWind: Double { wrapAngle(windDirection - heading) }
    public var twa: Double { abs(relativeWind) }
    /// The side opposite the boom.
    public var tack: Tack { boomSide == .port ? .starboard : .port }
    /// The wind's angle off the bow as the boom sees it (`BoomSide.sailingAngle(relativeWind:)`).
    public var sailingAngle: Double { boomSide.sailingAngle(relativeWind: relativeWind) }
    /// Sailing downwind with the wind past dead astern on the boom's side, short of the gybe.
    public var isByTheLee: Bool { BoomSide.isByTheLee(sailingAngle) }
    public var forward: Vec2 { .heading(heading) }
    /// Metres per second through the water: the same as `speed`, named for readouts (#15: the wake).
    public var speedThroughWater: Double { speed }
    /// Velocity through the water, m/s.
    public var velocity: Vec2 { forward * speed }
    /// Velocity over the ground, m/s: through the water plus the current, always (#11).
    public var velocityOverGround: Vec2 { velocity + current }

    public var isOnCourse: Bool {
        status == .prestart || status == .ocs || status == .racing
    }

    /// A boat that has stopped racing: still drawn, but with no rights or obligations under Part 2
    /// (CONTEXT.md). Decided by status alone; for now every status off the course (finished, dsq, dnf).
    /// #86 owns the final semantics (OCS at the close).
    public var isGhost: Bool { !isOnCourse }

    /// How far she sails by the lee, radians, or nil when she isn't.
    public var byTheLeeAngle: Double? { isByTheLee ? .pi + sailingAngle : nil }

    /// Whether her spinnaker is up but collapsed: more than the class's `byTheLee.spinnakerCollapse` by the
    /// lee (#248). It draws nothing, and she sails at two-sail speed (`BoatDynamics.polarTarget`).
    public func isSpinnakerCollapsed(in boatClass: BoatClass) -> Bool {
        guard spinnaker.isUp, let angle = byTheLeeAngle, let collapse = boatClass.byTheLee?.spinnakerCollapse else { return false }
        return angle > collapse
    }

    /// Moves `averagedWindSpeed` on by `dt` seconds towards `polarWindSpeed`, the class's exponential
    /// average with its `grooveWindAverage` time constant; with none, or before the first sample, it takes
    /// the wind right now.
    mutating func averageWind(dt: Double, timeConstant: Double) {
        let now = polarWindSpeed
        guard let average = averagedWindSpeed, timeConstant > 0 else {
            averagedWindSpeed = now
            return
        }
        averagedWindSpeed = average + (now - average) * min(1, dt / timeConstant)
    }

    public var isTakingPenalty: Bool {
        penaltyTurnsOwed > 0 && abs(penaltyProgress) > deg2rad(30)
    }

    /// The boat class's hull `outline` (`BoatClass.Hull.outline`, boat frame) in world coordinates. Convex.
    public func hull(outline: [Vec2]) -> [Vec2] {
        let f = forward
        let r = f.rightPerp
        return outline.map { position + r * $0.x + f * $0.y }
    }
}
