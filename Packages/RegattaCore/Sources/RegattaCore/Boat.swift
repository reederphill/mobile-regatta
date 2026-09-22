public enum Tack: Sendable {
    case port
    case starboard
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
    public static let length = 4.2
    public static let beam = 1.5

    public let id: Int
    public let name: String
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
    /// When set, the boat steers itself to this heading (auto-tack / gybe).
    public var autopilot: Double?

    public var status: BoatStatus = .prestart
    public var legIndex = 0
    public var roundingStage = 0

    public var penaltyTurnsOwed = 0
    /// Signed radians turned since the current penalty was incurred.
    public var penaltyProgress = 0.0
    /// Rule 13: past head to wind but not yet close-hauled.
    public var isTacking = false

    /// Local true wind at the boat (direction is where it blows from).
    public var windDirection = 0.0
    public var windSpeed = 0.0
    /// Multiplier from other boats' wind shadow, 1 = clean air.
    public var shadow = 1.0

    public var finishTime: Double?
    public var place: Int?

    public init(id: Int, name: String, isPlayer: Bool, colorIndex: Int, position: Vec2, heading: Double, speed: Double) {
        self.id = id
        self.name = name
        self.isPlayer = isPlayer
        self.colorIndex = colorIndex
        self.position = position
        self.heading = heading
        self.speed = speed
    }

    /// Wind direction relative to the bow; positive = wind over the starboard side.
    public var relativeWind: Double { wrapAngle(windDirection - heading) }
    public var twa: Double { abs(relativeWind) }
    public var tack: Tack { relativeWind >= 0 ? .starboard : .port }
    public var forward: Vec2 { .heading(heading) }
    public var velocity: Vec2 { forward * speed }

    public var isOnCourse: Bool {
        status == .prestart || status == .ocs || status == .racing
    }

    public var isTakingPenalty: Bool {
        penaltyTurnsOwed > 0 && abs(penaltyProgress) > deg2rad(30)
    }

    /// Hull outline in world coordinates (convex).
    public func hull() -> [Vec2] {
        let f = forward
        let r = f.rightPerp
        let l = Boat.length, b = Boat.beam
        let local: [Vec2] = [
            Vec2(0, l / 2),
            Vec2(b / 2, l * 0.05),
            Vec2(b * 0.42, -l / 2),
            Vec2(-b * 0.42, -l / 2),
            Vec2(-b / 2, l * 0.05),
        ]
        return local.map { position + r * $0.x + f * $0.y }
    }
}
