import Foundation
import RegattaCore

/// #376 follow-on A (Debug drawing only; nothing here sails): the turbulence-trail model, copied from the prototype
/// (`Packages/RegattaCore/Tests/RegattaCoreTests/TurbulenceTrailPrototypeTests.swift`, the reference) so the scene can
/// draw it (`TurbulenceTrailLayer`). Every boat sheds samples of disturbed air along her track at 10 Hz, each carried
/// off by the true wind, growing and fading with age. A boat's loss from one caster is the strongest of that caster's
/// samples at her position; casters stack as the cones do (product, floored). The race never reads it: core's cones
/// still slow the boats.
///
/// The changes from the prototype: each sample says whether it is a cone or a backwind sample (`isBackwind`), for the
/// drawing; and `step` can scale each boat's samples by her sail's angle to the wind (`scales`). Unscaled, the loss is
/// the prototype's exactly (`TurbulenceTrailsTests`).
struct TurbulenceTrails {
    struct Sample {
        var position: Vec2
        /// The true wind's velocity at the caster: how the sample drifts (ground frame).
        var drift: Vec2
        var born: Int
        var caster: Int
        var peak: Double
        var radius: Double
        var growth: Double
        var life: Double
        /// A backwind sample (drawn in the backwind's share), else a cone sample.
        var isBackwind = false
    }

    /// Where a boat sheds her backwind samples.
    enum BackwindOrigin {
        /// The prototype's: at the middle of the trapezoid, full size from birth.
        case trapezoidMiddle
        /// At her windward stern corner (`BoatClass.WindShadow.sternCorner`), small at birth and widening as her
        /// apparent wind carries it astern, so her backwind reads as air coming off her windward quarter.
        case windwardStern
    }

    /// A windward-stern backwind sample's radius at birth, a share of the trapezoid's half width; it grows to the
    /// whole half width by the end of its life.
    static let backwindBirthShare = 0.25

    private(set) var samples: [Sample] = []
    let shadow: BoatClass.WindShadow
    let every: Int
    let backwindOrigin: BackwindOrigin

    init(shadow: BoatClass.WindShadow, every: Int = 3, backwindOrigin: BackwindOrigin = .windwardStern) {
        self.shadow = shadow
        self.every = every
        self.backwindOrigin = backwindOrigin
    }

    /// Each seat's shedding level now, 0...1: her sail-angle scale smoothed (`step`'s `buildSeconds`). Empty until the
    /// first step.
    private(set) var levels: [Double] = []

    /// Sheds this tick's samples; call it every tick. `scales`, by seat (nil = 1 for all), is how much turbulence each
    /// boat's sail sheds now, 0...1 (`scale(of:ease:boatClass:style:)`, drawn only), smoothed into `levels`: a level falls
    /// to its scale at once (an ease drops the trail) and rises towards it linearly, 0 to 1 over `buildSeconds` (0 = at
    /// once), so after an ease, a tack or a gybe the trail builds back from nothing. A seat's first level is its scale.
    /// The level multiplies a sample's peak, radius and growth, so a sail along the wind sheds none and a half-angle sail
    /// a half-strength, half-size sample.
    mutating func step(boats: [Boat], tick: Int, scales: [Double]? = nil, buildSeconds: Double = 0) {
        samples.removeAll { Double(tick - $0.born) * Race.dt >= $0.life }
        let rise = buildSeconds > 0 ? Race.dt / buildSeconds : 1
        for seat in boats.indices {
            let target = (scales.map { seat < $0.count ? $0[seat] : 1 } ?? 1).clamped(to: 0...1)
            if seat >= levels.count {
                levels.append(target)
            } else {
                levels[seat] = target < levels[seat] ? target : min(target, levels[seat] + rise)
            }
        }
        guard tick % every == 0 else { return }
        for (seat, b) in boats.enumerated() where !b.isGhost {
            let k = levels[seat]
            guard k > 0 else { continue }
            let apparent = max(b.apparentWind.speed, 0.5)
            let drift = b.windOverGround.velocity
            // Her cone: shed at her centre, reaching `coneLength` in the time her own apparent wind takes to carry
            // air that far astern of her (the trail's length in her frame is her apparent wind × the sample's life).
            let life = shadow.coneLength / apparent
            let r0 = shadow.coneWidthAtBoat / 2, r1 = shadow.coneWidthAtEnd / 2
            samples.append(Sample(position: b.position, drift: drift, born: tick, caster: seat, peak: shadow.lossCloseIn * k,
                                  radius: r0 * k, growth: (r1 - r0) / life * k, life: life))
            // Her backwind: reaching the trapezoid's far edge in the time her apparent wind carries air that far
            // astern, as strong as the box at the trapezoid's middle. Shed at her windward stern corner, small and
            // widening to the trapezoid's width (the app's), or at the trapezoid's middle full size (the prototype's).
            let cone = ShadowCone(caster: b, shadow: shadow)
            guard shadow.backwindInnerLength != nil, cone.backwindPresence > 0,
                  let middle = Self.backwindCentre(of: cone) else { continue }
            let scale = shadow.backwindScale(speed: b.speedThroughWater)
            guard scale > 0 else { continue }
            let backLife = shadow.backwindLength * scale / apparent
            let peak = (1 - cone.backwindFactor(at: middle)) * k, full = shadow.backwindWidth / 2 * k
            switch backwindOrigin {
            case .trapezoidMiddle:
                samples.append(Sample(position: middle, drift: drift, born: tick, caster: seat, peak: peak, radius: full,
                                      growth: 0, life: backLife, isBackwind: true))
            case .windwardStern:
                let birth = Self.backwindBirthShare * full
                samples.append(Sample(position: Self.windwardStern(of: cone), drift: drift, born: tick, caster: seat,
                                      peak: peak, radius: birth, growth: (full - birth) / backLife, life: backLife,
                                      isBackwind: true))
            }
        }
    }

    /// How much turbulence `boat`'s sail sheds now, 0...1: the angle between her drawn sail and her apparent wind
    /// (`BoatPose.angleOfAttack`) over `BoatStyle.trailFullAngleDegrees`, capped at 1 (a stalled or running sail).
    static func scale(of boat: Boat, ease: Bool, boatClass: BoatClass, style: BoatStyle) -> Double {
        let full = deg2rad(max(style.trailFullAngleDegrees, 0.1))
        return (BoatPose.angleOfAttack(boat, ease: ease, boatClass: boatClass, style: style) / full).clamped(to: 0...1)
    }

    /// Her windward stern corner, where the trapezoid (#298) hangs from (`ShadowCone`'s P1).
    static func windwardStern(of cone: ShadowCone) -> Vec2 {
        cone.apex + cone.windward * cone.shadow.sternCorner.x + cone.forward * cone.shadow.sternCorner.y
    }

    /// The middle of the trapezoid (#298) the box casts now.
    static func backwindCentre(of cone: ShadowCone) -> Vec2? {
        let s = cone.shadow
        let out = s.backwindWidth / 2
        guard let span = s.backwindSpan(out: out) else { return nil }
        let scale = s.backwindScale(speed: cone.speed)
        let astern = (span.start + span.end) / 2 * scale
        return cone.apex + cone.windward * (s.sternCorner.x + out) + cone.forward * (s.sternCorner.y - astern)
    }

    /// The loss (0...1) each caster's trail leaves at `p` at `tick`, by caster seat.
    func losses(at p: Vec2, tick: Int, casters: Int) -> [Double] {
        var best = [Double](repeating: 0, count: casters)
        for s in samples {
            let age = Double(tick - s.born) * Race.dt
            guard age < s.life else { continue }
            let d = (p - (s.position + s.drift * age)).length
            let r = s.radius + s.growth * age
            guard d < r else { continue }
            let loss = s.peak * (1 - age / s.life) * (1 - d / r)
            if loss > best[s.caster] { best[s.caster] = loss }
        }
        return best
    }

    func factor(at p: Vec2, tick: Int, receiver: Int, casters: Int) -> Double {
        var f = 1.0
        for (c, loss) in losses(at: p, tick: tick, casters: casters).enumerated() where c != receiver { f *= 1 - loss }
        return max(f, shadow.stackingFloor)
    }
}

