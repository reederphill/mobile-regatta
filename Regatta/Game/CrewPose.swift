import Foundation
import RegattaCore

/// The sailors' tier (#127's far-boat seam): every sailor drawn, or none. `reduced` also stills the sail's flutter,
/// luff and belly; heel, the drop shadow and the boom's side and trim stay, so a far boat still reads her tack,
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
    /// How powered she is, 0 to 1: her heel (`BoatPose.heel`, nothing eased or head to wind), or
    /// `BoatStyle.crewPlaningPower` on the plane, whichever is more.
    var power: Double
    /// Eased or a ghost: the crew sits in whatever her power.
    var sitsIn: Bool
    var isTacking: Bool
    /// When her boom crossed on the tack she is in, race seconds (`Boat.tackCrossingTick`).
    var crossingTime: Double?

    init(_ boat: Boat, pose: BoatPose, style: BoatStyle) {
        boomSide = boat.boomSide
        side = boat.boomSide.opposite
        power = max(pose.heel, boat.isPlaning && !pose.isGhost ? style.crewPlaningPower : 0)
        sitsIn = pose.isEased || pose.isGhost
        isTacking = boat.isTacking
        crossingTime = boat.tackCrossingTick.map { Double($0) / Double(Race.tickRate) }
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
/// outline. Her hips sit at `hip`; her body reaches out `facing` (+1 to starboard, -1 to port) by `reach` of a
/// body flat out on the wire (`BoatStyle.crewBodyMetres`), her helmet at its end.
nonisolated struct SailorPlacement: Equatable, Sendable {
    var hip: Vec2
    var facing: Double
    var reach: Double

    /// The two sailors, the helm then the crew, for `crew` on a hull `beam` and `length` metres heeled `heel`
    /// (the hull drawn narrower by `BoatStyle.heelNarrowing`, so they stay on her rail).
    static func placements(_ crew: CrewPose, beam: Double, length: Double, heel: Double,
                           style: BoatStyle) -> [SailorPlacement] {
        let rail = beam / 2 * (1 - style.heelNarrowing * heel)
        let side = crew.side == .starboard ? 1.0 : -1.0
        let sit = rail * style.crewSitShare
        let stagger = style.crewStagger.clamped(to: 0...0.9)
        return [style.crewHelmFore, style.crewForwardFore].enumerated().map { index, fore in
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
                // The helm goes first, the crew a `crewStagger` behind; each eases across the boat.
                let own = ((progress - Double(index) * stagger) / (1 - stagger)).clamped(to: 0...1)
                let eased = own * own * (3 - 2 * own)
                let x = -side * sit + 2 * side * sit * eased
                return SailorPlacement(hip: Vec2(x, y), facing: eased < 0.5 ? -side : side, reach: style.crewDuckReach)
            }
        }
    }
}

/// Which classes carry sailors and how many (#120): app-side, by the class's name, as the class files hold no
/// art. The skiff's two on trapezes (#245); every other class draws none, as before.
nonisolated enum CrewTable {
    static let sailorsByClassName: [String: Int] = ["Skiff": 2]

    static func sailors(in boatClass: BoatClass) -> Int { sailorsByClassName[boatClass.name] ?? 0 }
}
