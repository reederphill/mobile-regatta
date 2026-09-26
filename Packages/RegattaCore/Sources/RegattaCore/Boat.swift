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
    /// On the course side at the gun; must return below the line.
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
    /// Rudder the helm is asking for.
    public var desiredRudder = 0.0
    /// Which side the boom is on; her tack is the other side.
    public var boomSide: BoomSide
    /// When set, the tack/gybe tap is steering the boat (#13).
    public var autopilot: Autopilot?

    public var status: BoatStatus = .prestart
    public var legIndex = 0
    public var roundingStage = 0

    public var penaltyTurnsOwed = 0
    /// Signed radians turned since the current penalty was incurred.
    public var penaltyProgress = 0.0
    /// Rule 13: past head to wind but not yet close-hauled.
    public var isTacking = false

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
