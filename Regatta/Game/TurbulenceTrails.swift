import Foundation
import RegattaCore

/// #376 follow-on A (Debug drawing only; nothing here sails): the turbulence-trail model, copied from the prototype
/// (`Packages/RegattaCore/Tests/RegattaCoreTests/TurbulenceTrailPrototypeTests.swift`, the reference) so the scene can
/// draw it (`TurbulenceTrailLayer`). Every boat sheds samples of disturbed air along her track at 10 Hz, each carried
/// off by the true wind, growing and fading with age. A boat's loss from one caster is the strongest of that caster's
/// samples at her position; casters stack as the cones do (product, floored). The race never reads it: core's cones
/// still slow the boats.
///
/// The one change from the prototype: each sample says whether it is a cone or a backwind sample (`isBackwind`), for
/// the drawing; the loss is the prototype's exactly (`TurbulenceTrailsTests`).
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

    private(set) var samples: [Sample] = []
    let shadow: BoatClass.WindShadow
    let every: Int

    init(shadow: BoatClass.WindShadow, every: Int = 3) {
        self.shadow = shadow
        self.every = every
    }

    mutating func step(boats: [Boat], tick: Int) {
        samples.removeAll { Double(tick - $0.born) * Race.dt >= $0.life }
        guard tick % every == 0 else { return }
        for (seat, b) in boats.enumerated() where !b.isGhost {
            let apparent = max(b.apparentWind.speed, 0.5)
            let drift = b.windOverGround.velocity
            // Her cone: shed at her centre, reaching `coneLength` in the time her own apparent wind takes to carry
            // air that far astern of her (the trail's length in her frame is her apparent wind × the sample's life).
            let life = shadow.coneLength / apparent
            let r0 = shadow.coneWidthAtBoat / 2, r1 = shadow.coneWidthAtEnd / 2
            samples.append(Sample(position: b.position, drift: drift, born: tick, caster: seat, peak: shadow.lossCloseIn,
                                  radius: r0, growth: (r1 - r0) / life, life: life))
            // Her backwind: shed at the middle of the trapezoid, a short-lived patch.
            let cone = ShadowCone(caster: b, shadow: shadow)
            guard shadow.backwindInnerLength != nil, cone.backwindPresence > 0,
                  let at = Self.backwindCentre(of: cone) else { continue }
            let scale = shadow.backwindScale(speed: b.speedThroughWater)
            guard scale > 0 else { continue }
            samples.append(Sample(position: at, drift: drift, born: tick, caster: seat,
                                  peak: 1 - cone.backwindFactor(at: at), radius: shadow.backwindWidth / 2,
                                  growth: 0, life: shadow.backwindLength * scale / apparent, isBackwind: true))
        }
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

