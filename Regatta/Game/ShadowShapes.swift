import Foundation
import RegattaCore

/// The outlines a boat's wind shadow and backwind are drawn in (#10, #298, #121), from the same numbers core's
/// `ShadowCone` slows boats with: the class file's sizes (ADR 0004), never constants of the app's. Pure.
///
/// Each has a local outline, in metres, which the sprite's texture is drawn from, and a world outline, where that
/// outline lands once the sprite is placed as `BoatEffects` places it.
nonisolated enum ShadowShapes {
    /// The cone in its own frame, metres: x across it, y down its axis from the apex. Its corners: the apex's
    /// two, then the far end's two.
    static func coneLocal(_ shadow: BoatClass.WindShadow) -> [Vec2] {
        let near = shadow.coneWidthAtBoat / 2, far = shadow.coneWidthAtEnd / 2
        return [Vec2(-near, 0), Vec2(near, 0), Vec2(far, shadow.coneLength), Vec2(-far, shadow.coneLength)]
    }

    /// The cone's four corners on the water: `coneLocal` along `cone.axis` from `cone.apex`.
    static func coneCorners(_ cone: ShadowCone) -> [Vec2] {
        let across = cone.axis.rightPerp
        return coneLocal(cone.shadow).map { cone.apex + across * $0.x + cone.axis * $0.y }
    }

    /// The backwind trapezoid (#298) in the boat's frame on starboard tack, metres: x out to starboard (her
    /// windward side on starboard tack), y forward. Its corners, from `BoatClass.WindShadow.backwindSpan(out:)`: P1,
    /// her windward stern corner offset by the span's start on the hull side; P2, `backwindWidth` out along her stern, by
    /// the start there; P3 and P4, the far edge's ends, outboard then hull side. One edge slants: the far one for
    /// skiff@4's shape, the stern one for skiff@5's. Nil for a class with #79's band, which draws no zone.
    static func backwindLocal(_ shadow: BoatClass.WindShadow) -> [Vec2]? {
        guard let hullSide = shadow.backwindSpan(out: 0), let outboard = shadow.backwindSpan(out: shadow.backwindWidth) else {
            return nil
        }
        let corner = shadow.sternCorner
        let out = corner.x + shadow.backwindWidth
        return [Vec2(corner.x, corner.y - hullSide.start), Vec2(out, corner.y - outboard.start),
                Vec2(out, corner.y - outboard.end), Vec2(corner.x, corner.y - hullSide.end)]
    }

    /// The backwind trapezoid's corners on the water: `backwindLocal` turned to her heading and mirrored to her
    /// windward side (`cone.windward`). Nil for a class with #79's band.
    static func backwindCorners(_ cone: ShadowCone) -> [Vec2]? {
        backwindLocal(cone.shadow)?.map { cone.apex + cone.windward * $0.x + cone.forward * $0.y }
    }
}
