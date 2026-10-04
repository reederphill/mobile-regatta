import Foundation
import RegattaCore

/// The outline a boat's backwind is drawn in (#10, #298, #121), from the same numbers core's `ShadowCone` casts it
/// with: the class file's sizes (ADR 0004), never constants of the app's. Pure. (Her wind shadow is the ribbons since
/// #377, drawn by `TurbulenceTrailLayer`.)
///
/// It has a local outline, in metres, which the sprite's texture is drawn from, and a world outline, where that
/// outline lands once the sprite is placed as `BoatEffects` places it.
nonisolated enum ShadowShapes {
    /// The backwind trapezoid (#298) in the boat's frame on starboard tack, metres, its length astern of her stern
    /// line scaled by `scale`: x out to starboard (her windward side on starboard tack), y forward. Its corners, from `BoatClass.WindShadow.backwindSpan(out:)`: P1,
    /// her windward stern corner offset by the span's start on the hull side; P2, `backwindWidth` out along her stern, by
    /// the start there; P3 and P4, the far edge's ends, outboard then hull side. One edge slants: the far one for
    /// skiff@4's shape, the stern one for skiff@5's. Nil for a class with #79's band, which draws no zone.
    ///
    /// For a class whose header's zone is the upwash beside her sail (#377, `BoatClass.WindShadow.upwashExtent`), the
    /// rectangle of it: from her side to its reach out, from her stern forward to her mast, not scaled (it is bound to
    /// her, her speed doesn't stretch it).
    static func backwindLocal(_ shadow: BoatClass.WindShadow, scale: Double = 1) -> [Vec2]? {
        if let zone = shadow.upwashExtent {
            let out = zone.out + zone.reach
            return [Vec2(zone.out, zone.aft), Vec2(out, zone.aft), Vec2(out, zone.fore), Vec2(zone.out, zone.fore)]
        }
        guard let hullSide = shadow.backwindSpan(out: 0), let outboard = shadow.backwindSpan(out: shadow.backwindWidth) else {
            return nil
        }
        let corner = shadow.sternCorner
        let out = corner.x + shadow.backwindWidth
        return [Vec2(corner.x, corner.y - hullSide.start * scale), Vec2(out, corner.y - outboard.start * scale),
                Vec2(out, corner.y - outboard.end * scale), Vec2(corner.x, corner.y - hullSide.end * scale)]
    }

    /// The backwind trapezoid's corners on the water: `backwindLocal`, its length astern scaled by her speed
    /// (`BoatClass.WindShadow.backwindScale(speed:)`), turned to her heading and mirrored to her windward side
    /// (`cone.windward`). Nil for a class with #79's band. The upwash zone (#377) isn't scaled.
    static func backwindCorners(_ cone: ShadowCone) -> [Vec2]? {
        backwindLocal(cone.shadow, scale: backwindScale(cone.shadow, speed: cone.speed))?
            .map { cone.apex + cone.windward * $0.x + cone.forward * $0.y }
    }

    /// The scale `backwindLocal`'s length astern is drawn at for a boat at `speed`: her trapezoid's speed scale
    /// (`BoatClass.WindShadow.backwindScale(speed:)`), or 1 for the upwash zone (#377), which her speed doesn't stretch.
    static func backwindScale(_ shadow: BoatClass.WindShadow, speed: Double?) -> Double {
        shadow.upwashExtent != nil ? 1 : shadow.backwindScale(speed: speed)
    }
}
