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
    /// windward side on starboard tack), y forward. Its corners: P1, her windward stern corner; P2, `backwindWidth`
    /// out along her stern; P3, `backwindLength` astern of P2; P4, `backwindInnerLength` astern of P1. Nil for a
    /// class with #79's band, which draws no zone.
    static func backwindLocal(_ shadow: BoatClass.WindShadow) -> [Vec2]? {
        guard let inner = shadow.backwindInnerLength else { return nil }
        let p1 = Vec2(shadow.sternCorner.x, shadow.sternCorner.y)
        let p2 = Vec2(p1.x + shadow.backwindWidth, p1.y)
        return [p1, p2, Vec2(p2.x, p2.y - shadow.backwindLength), Vec2(p1.x, p1.y - inner)]
    }

    /// The backwind trapezoid's corners on the water: `backwindLocal` turned to her heading and mirrored to her
    /// windward side (`cone.windward`). Nil for a class with #79's band.
    static func backwindCorners(_ cone: ShadowCone) -> [Vec2]? {
        backwindLocal(cone.shadow)?.map { cone.apex + cone.windward * $0.x + cone.forward * $0.y }
    }
}
