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
    /// Crossed the finish line (#86: a ghost from that tick).
    case finished
    /// Disqualified: at a penalty turn's missed deadline (#89). A ghost from the call (#86).
    case dsq
}

/// A roll tack (#222, #263, `BoatClass.RollTackTuning`): the second tack/gybe tap of a tack, and how it went.
/// One a tack; cleared once she is close-hauled on the new tack.
public enum RollTack: Sendable, Equatable {
    /// Tapped at `tapTick`, not yet timed: a hit if the boom crosses within the window of it, either side, else a miss.
    case pending(tapTick: Int)
    /// Within the window of the crossing: until close-hauled she takes the class's share of each tick's speed loss.
    case hit
    /// Outside it: her speed took the class's miss factor once.
    case missed
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

    /// Penalty turns she owes (#9, #89): one a call, a foul's or a mark touch's (rule 31). They add up with no
    /// cap and are served in order: the first is the current turn, the rest are queued behind it.
    public var penaltyTurnsOwed = 0
    /// Signed radians turned in the current penalty turn, positive to starboard. A turn goes one way only, so
    /// the sign is its direction; 0 before she has turned it either way. A full turn (2π) serves it, and any
    /// turning past that carries into the next one (`Race`).
    public var penaltyProgress = 0.0
    /// The tick the current penalty turn's clock started: its start and complete deadlines run from here
    /// (`Race.owedPenalty(ofSeat:)`). Nil while she owes none.
    public var penaltyClockTick: Int?
    /// The call tick of each owed turn queued behind the current one, oldest first: under `fromCall` stacking
    /// a queued turn's clock starts at its call (`RulesConfig.StackedPenaltyDeadlines`). At most
    /// `penaltyTurnsOwed − 1` of them; a queued turn with none listed (a wire snapshot's, which carries only
    /// the current turn's clock) starts its clock when it becomes current.
    public var queuedPenaltyCallTicks: [Int] = []
    /// Rule 13: past head to wind but not yet close-hauled.
    public var isTacking = false
    /// The tick the boom crossed on the tack she is in (#263): set with `isTacking`, cleared with it. What a roll
    /// tap after the crossing is timed against (`RollTack`).
    public var tackCrossingTick: Int?
    /// Her roll of the tack she is in (#222, #263), or nil: none tapped yet, or not in a tack.
    public var roll: RollTack?
    /// On the plane (#248, `BoatClass.planing`): set by `BoatDynamics.advance`, never for a class that
    /// doesn't plane. For drawing (#117, #121) as much as for her speed.
    public var isPlaning = false
    /// Her automatic spinnaker (#248, `BoatClass.spinnaker`): down, going up, up or coming down. Always
    /// down for a class without one. For drawing (#120) as much as for her speed.
    public var spinnaker = Spinnaker.down
    /// Heel from being overpowered, 0…1 (#429 prototype): set by `BoatDynamics.advance`.
    public var heel = 0.0
    /// Ticks left of a wipeout (#429 prototype), or nil.
    public var wipeoutTicksLeft: Int?
    /// Wiped out (#429 prototype).
    public var isWipedOut: Bool { wipeoutTicksLeft != nil }
    /// The class's running average of the wind speed her polar reads (`polarWindSpeed(in:)`), m/s: what her
    /// autohelm's grooves follow (#245, `grooveWindSpeed(in:)`). Nil until the race first samples her wind.
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
    /// Multiplier from other boats' wind shadow and backwind, 1 = clean air: on the sailing wind's speed, or on her
    /// target speed for a class whose shadow is a speed loss (`BoatClass.WindShadow.isSpeedLoss`, #263).
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
    /// The wind speed her polar reads in `boatClass`, m/s: the sailing wind's, slowed by any shadow (#10, #14)
    /// unless the class's shadow slows the boat instead (`BoatClass.WindShadow.isSpeedLoss`, #263).
    public func polarWindSpeed(in boatClass: BoatClass) -> Double {
        boatClass.windShadow.isSpeedLoss ? sailingWind.speed : sailingWind.speed * shadow
    }
    /// The shadow's multiplier on her target speed in `boatClass` (#220, #263): `shadow` for a class whose shadow
    /// slows the boat, 1 for one whose shadow slows the wind (`polarWindSpeed(in:)` has it).
    public func speedShadow(in boatClass: BoatClass) -> Double {
        boatClass.windShadow.isSpeedLoss ? shadow : 1
    }
    /// The wind speed her autohelm's grooves read in `boatClass`, m/s: the class's average of
    /// `polarWindSpeed(in:)` (`averagedWindSpeed`), or the wind right now before the race has sampled it.
    public func grooveWindSpeed(in boatClass: BoatClass) -> Double { averagedWindSpeed ?? polarWindSpeed(in: boatClass) }

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

    /// Still racing, or still able to: before the gun, OCS, not yet started or racing. Exactly `!isGhost`,
    /// kept for the app and the bots, which ask it that way round.
    public var isOnCourse: Bool { !isGhost }

    /// A boat that has stopped racing (CONTEXT.md, "Ghost"; #30, #86): finished, from the tick she crosses
    /// the line, or DSQ, from the call. She casts and takes no wind shadow or backwind, can't be touched and
    /// has no rights or obligations under the rules, but the current still carries her (#11). Decided by
    /// status alone, and what the step's checks read.
    ///
    /// An OCS boat, or one that never started, becomes a ghost only at the close, since she can return and
    /// start until then (#30). Nothing steps after the close, so the boat can't see it and the race says it:
    /// `Race.isGhost(seat:)`, which is what a display reads. No field, wire bit or digest input of its own.
    public var isGhost: Bool { status == .finished || status == .dsq }

    /// How far she sails by the lee, radians, or nil when she isn't.
    public var byTheLeeAngle: Double? { isByTheLee ? .pi + sailingAngle : nil }

    /// Whether her spinnaker is up but collapsed: more than the class's `byTheLee.spinnakerCollapse` by the
    /// lee (#248). It draws nothing, and she sails at two-sail speed (`BoatDynamics.polarTarget`).
    public func isSpinnakerCollapsed(in boatClass: BoatClass) -> Bool {
        guard spinnaker.isUp, let angle = byTheLeeAngle, let collapse = boatClass.byTheLee?.spinnakerCollapse else { return false }
        return angle > collapse
    }

    /// Moves `averagedWindSpeed` on by `dt` seconds towards `polarWindSpeed(in:)`, the class's exponential
    /// average with its `grooveWindAverage` time constant; with none, or before the first sample, it takes
    /// the wind right now.
    mutating func averageWind(dt: Double, in boatClass: BoatClass) {
        let now = polarWindSpeed(in: boatClass)
        let timeConstant = boatClass.steering.autohelm.grooveWindAverage
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
