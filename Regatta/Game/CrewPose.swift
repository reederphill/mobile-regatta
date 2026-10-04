import Foundation
import RegattaCore

/// The sailors' tier (#127's far-boat seam): every sailor drawn, or none. `reduced` also stills the sail's flutter,
/// flap and luff shiver (the cheaper of the two: its belly still follows a ghost, a pinch or a foot, only without
/// the flap's pulse); heel, the drop shadow and the boom's side and trim stay, so a far boat still reads her tack,
/// her heel and how she is trimmed. Which boats count as far is #127's.
nonisolated enum CrewDetail: Sendable {
    case full
    case reduced
}

/// What a boat's crew is doing (#120), as `CrewTimer` reads it from her sim state.
nonisolated enum CrewPosture: Equatable, Sendable {
    /// Out on the wire, 0 (just out) to 1 (flat out).
    case out(extent: Double)
    /// Sitting in on her side: light air, eased, head to wind, or a ghost.
    case sittingIn
    /// A gybe (#22): crouched under the boom as it crosses, still on the old side, 0 to 1 of the duck.
    case ducking(progress: Double)
    /// Crossing the boat to the new side on a tack or gybe, 0 to 1 of the crossing.
    case crossing(progress: Double)
}

/// How a boat's two sailors (#120, #245) are drawn this frame: the side they sail on and their posture.
nonisolated struct CrewPose: Equatable, Sendable {
    /// Her windward side, opposite the boom (`Boat.boomSide`): where they hike. Ducking or crossing, the side they
    /// are going to.
    var side: BoomSide
    var posture: CrewPosture
}

/// What a boat's crew reads from her sim state (#120, #248), the same for every boat: her boom's side, whether
/// she tacks and when her boom crossed, and her power, her heel or her planing. Nothing else: no livery, seat or
/// setting, no wind shadow term of its own (the heel reads the shadowed felt wind, "shadow is turbulence"), and no
/// backwind state. Presentation only: nothing here reaches the race (ADR 0002).
nonisolated struct CrewTarget: Equatable, Sendable {
    var side: BoomSide
    var boomSide: BoomSide
    /// How powered she is, 0 to 1: her heel (`BoatPose.heel`, nothing eased or head to wind), or on the plane
    /// `BoatStyle.crewPlaningPower` scaled by her clean air (`cleanAir`), whichever is more. Planing counts for
    /// nothing head to wind or while she tacks (`Boat.isTacking`, from her boom's crossing until close-hauled).
    var power: Double
    /// Eased or a ghost: the crew sits in whatever her power.
    var sitsIn: Bool
    var isTacking: Bool
    /// When her boom crossed on the tack she is in, race seconds (`Boat.tackCrossingTick`).
    var crossingTime: Double?

    init(_ boat: Boat, pose: BoatPose, style: BoatStyle) {
        boomSide = boat.boomSide
        side = boat.boomSide.opposite
        let planes = boat.isPlaning && !pose.isGhost && !pose.isHeadToWind && !boat.isTacking
        power = max(pose.heel, planes ? style.crewPlaningPower * Self.cleanAir(boat, style: style) : 0)
        sitsIn = pose.isEased || pose.isGhost
        isTacking = boat.isTacking
        crossingTime = boat.tackCrossingTick.map { Double($0) / Double(Race.tickRate) }
    }

    /// How clean her air is for the planing power, 0 to 1: the shadowed felt wind (`BoatPose.feltWind`, ruling 1:
    /// shadow is turbulence) as a share of her sailing wind, nothing at or under `BoatStyle.crewDirtyAirShare` and
    /// all of it in clean air. A planing boat in someone's air sits in.
    static func cleanAir(_ boat: Boat, style: BoatStyle) -> Double {
        let wind = boat.sailingWind.speed
        guard wind > 0.01 else { return 0 }
        let floor = style.crewDirtyAirShare.clamped(to: 0...0.99)
        return ((BoatPose.feltWind(boat) / wind - floor) / (1 - floor)).clamped(to: 0...1)
    }

    /// Whether they are out on the wire, `wasOut` whether they were: out at `crewOutPower`, back in under
    /// `crewInPower`, so a power between the two never flickers them.
    func isOut(wasOut: Bool, style: BoatStyle) -> Bool {
        guard !sitsIn else { return false }
        return power >= (wasOut ? min(style.crewInPower, style.crewOutPower) : style.crewOutPower)
    }

    /// How far out they are, out on the wire: their power as a share of `crewFullPower`.
    func extent(style: BoatStyle) -> Double {
        (power / max(style.crewFullPower, 0.001)).clamped(to: 0...1)
    }
}

/// A boat's crew as she is drawn, one per boat (#120): what posture they are in, from her sim state over race
/// time. Her boom crossing over is a tack while she is tacking (`Boat.isTacking`, set at the crossing) and a gybe
/// otherwise: on a tack they cross; on a gybe they duck under the boom, then cross. Race seconds only, never the
/// wall clock or a frame count. Presentation state, like `FlogTimer`.
nonisolated struct CrewTimer: Equatable, Sendable {
    enum Manoeuvre: Equatable, Sendable {
        case tack
        case gybe
    }

    /// The boom's side when last drawn; nil before the first frame.
    private(set) var boomSide: BoomSide?
    private(set) var isOut = false
    /// The tack or gybe under way and when it began, race seconds.
    private(set) var manoeuvre: Manoeuvre?
    private(set) var start = 0.0
    private var lastTime: Double?

    /// The crew at race time `time`. A first frame, or time that runs backwards (an online re-prediction, a
    /// correction, a fixture drawn again, ADR 0005), snaps to `settled(_:time:style:)` without animating.
    mutating func advance(_ target: CrewTarget, time: Double, style: BoatStyle) -> CrewPose {
        defer { lastTime = time }
        guard let lastTime, time >= lastTime, let boomSide else {
            snap(target, time: time, style: style)
            return pose(target, time: time, style: style)
        }
        if target.boomSide != boomSide {
            if target.isTacking {
                manoeuvre = .tack
                start = min(target.crossingTime ?? time, time)
            } else {
                manoeuvre = .gybe
                start = time
            }
        }
        self.boomSide = target.boomSide
        isOut = target.isOut(wasOut: isOut, style: style)
        return pose(target, time: time, style: style)
    }

    /// The crew at `time` with no memory of earlier frames: a frozen render fixture's, or the first frame's. A
    /// tack's crossing is drawn from her boom's crossing tick, so it shows as it would live; a gybe leaves no
    /// trace in her state, so it doesn't. The power reads the stricter, out, threshold.
    static func settled(_ target: CrewTarget, time: Double, style: BoatStyle) -> CrewPose {
        var timer = CrewTimer()
        timer.snap(target, time: time, style: style)
        return timer.pose(target, time: time, style: style)
    }

    private mutating func snap(_ target: CrewTarget, time: Double, style: BoatStyle) {
        boomSide = target.boomSide
        isOut = target.isOut(wasOut: false, style: style)
        if target.isTacking, let crossing = target.crossingTime, crossing <= time {
            manoeuvre = .tack
            start = crossing
        } else {
            manoeuvre = nil
        }
    }

    private mutating func pose(_ target: CrewTarget, time: Double, style: BoatStyle) -> CrewPose {
        let elapsed = max(time - start, 0)
        let duck = manoeuvre == .gybe ? max(style.crewDuckSeconds, 0) : 0
        let cross = max(style.crewCrossSeconds, 0)
        if manoeuvre != nil {
            if elapsed < duck {
                return CrewPose(side: target.side, posture: .ducking(progress: elapsed / duck))
            }
            if elapsed - duck < cross {
                return CrewPose(side: target.side, posture: .crossing(progress: (elapsed - duck) / cross))
            }
            manoeuvre = nil
        }
        return CrewPose(side: target.side, posture: isOut ? .out(extent: target.extent(style: style)) : .sittingIn)
    }
}

/// Where one sailor is drawn in the boat's own frame (#120), metres: x to starboard, y to the bow, as her hull
/// outline. Her hips sit at `hip`; her body reaches out `facing` (+1 to starboard, -1 to port, between the two
/// standing up as she crosses, foreshortened from above) by `reach` of a body flat out on the wire
/// (`BoatStyle.crewBodyMetres`), her helmet at its end.
nonisolated struct SailorPlacement: Equatable, Sendable {
    var hip: Vec2
    var facing: Double
    var reach: Double

    /// `self` moved `share` (0 to 1) of the way to `other`.
    func mixed(_ other: SailorPlacement, _ share: Double) -> SailorPlacement {
        SailorPlacement(hip: Vec2(hip.x + (other.hip.x - hip.x) * share, hip.y + (other.hip.y - hip.y) * share),
                        facing: facing + (other.facing - facing) * share, reach: reach + (other.reach - reach) * share)
    }

    /// The two sailors, the helm then the crew, for `crew` on a hull `beam` and `length` metres heeled `heel`
    /// (the hull drawn narrower by `BoatStyle.heelNarrowing`, so they stay on her rail). Fixed storage: nothing
    /// is allocated per boat per frame.
    static func placements(_ crew: CrewPose, beam: Double, length: Double, heel: Double,
                           style: BoatStyle) -> SailorPair {
        SailorPair(helm: placement(crew, index: 0, fore: style.crewHelmFore, beam: beam, length: length, heel: heel,
                                   style: style),
                   crew: placement(crew, index: 1, fore: style.crewForwardFore, beam: beam, length: length,
                                   heel: heel, style: style))
    }

    private static func placement(_ crew: CrewPose, index: Int, fore: Double, beam: Double, length: Double,
                                  heel: Double, style: BoatStyle) -> SailorPlacement {
        let rail = beam / 2 * (1 - style.heelNarrowing * heel)
        let side = crew.side == .starboard ? 1.0 : -1.0
        let sit = rail * style.crewSitShare
        let stagger = style.crewStagger.clamped(to: 0...0.9)
        let y = fore * length
        switch crew.posture {
        case .out(let extent):
            let reach = style.crewSitReach + (1 - style.crewSitReach) * extent
            return SailorPlacement(hip: Vec2(side * rail, y), facing: side, reach: reach)
        case .sittingIn:
            return SailorPlacement(hip: Vec2(side * sit, y), facing: side, reach: style.crewSitReach)
        case .ducking(let progress):
            // Crouched on the old side, edging in as the boom comes over.
            let x = -side * sit * (1 - 0.5 * progress.clamped(to: 0...1))
            return SailorPlacement(hip: Vec2(x, y), facing: -side, reach: style.crewDuckReach)
        case .crossing(let progress):
            // The helm goes first, the crew a `crewStagger` behind; each eases across the boat, turning to face
            // the new side as they go (upright, foreshortened, mid-boat), never flipping over in one frame.
            let own = ((progress - Double(index) * stagger) / (1 - stagger)).clamped(to: 0...1)
            let eased = own * own * (3 - 2 * own)
            let x = -side * sit + 2 * side * sit * eased
            return SailorPlacement(hip: Vec2(x, y), facing: side * (2 * eased - 1), reach: style.crewDuckReach)
        }
    }
}

/// A boat's two sailors' placements (#120), the helm then the crew, in fixed storage (no array per frame).
nonisolated struct SailorPair: Equatable, Sendable {
    var helm: SailorPlacement
    var crew: SailorPlacement

    /// 0 the helm, 1 the crew.
    subscript(index: Int) -> SailorPlacement { index == 0 ? helm : crew }

    func mixed(_ other: SailorPair, _ share: Double) -> SailorPair {
        SailorPair(helm: helm.mixed(other.helm, share), crew: crew.mixed(other.crew, share))
    }
}

/// The sailors as drawn live (#120): at a posture's boundary (out to ducking or crossing, ducking to crossing,
/// crossing to settled, in to out, or a change of side) they move from where they were drawn to the new posture's
/// place over `BoatStyle.crewBlendSeconds` of race time, never jumping in one frame. A settled frame (a frozen
/// fixture), a first frame or time running backwards draws the target as is, so fixtures stay deterministic.
/// Presentation state, one per boat, like `CrewTimer`.
nonisolated struct CrewBlend: Equatable, Sendable {
    /// A posture's kind and side: a change of either is a boundary.
    private struct Phase: Equatable, Sendable {
        var kind: Int
        var side: BoomSide

        init(_ crew: CrewPose) {
            side = crew.side
            switch crew.posture {
            case .out: kind = 0
            case .sittingIn: kind = 1
            case .ducking: kind = 2
            case .crossing: kind = 3
            }
        }
    }

    private var phase: Phase?
    private var last: SailorPair?
    private var lastTime: Double?
    /// Where the blend under way began and when, race seconds.
    private var from: SailorPair?
    private var start = 0.0

    /// Where to draw them at race time `time`, `target` their place for `crew`.
    mutating func drawn(_ target: SailorPair, crew: CrewPose, time: Double, settled: Bool,
                        style: BoatStyle) -> SailorPair {
        let phase = Phase(crew)
        guard !settled, let last, let lastTime, time >= lastTime, let previous = self.phase else {
            self = CrewBlend()
            self.phase = phase
            self.last = target
            self.lastTime = time
            return target
        }
        if phase != previous {
            from = last
            start = time
        }
        var drawn = target
        if let from {
            let span = max(style.crewBlendSeconds, 0)
            let share = span > 0 ? (time - start) / span : 1
            if share >= 1 {
                self.from = nil
            } else {
                drawn = from.mixed(target, share * share * (3 - 2 * share))
            }
        }
        self.phase = phase
        self.last = drawn
        self.lastTime = time
        return drawn
    }
}

/// Which classes carry sailors and how many (#120): app-side, by the class's name, as the class files hold no
/// art. The skiff's two on trapezes (#245); every other class draws none, as before.
nonisolated enum CrewTable {
    static let sailorsByClassName: [String: Int] = ["Skiff": 2]

    static func sailors(in boatClass: BoatClass) -> Int { sailorsByClassName[boatClass.name] ?? 0 }
}
