import CoreGraphics

/// Every node the race scene draws has a z of its own. The view ignores sibling order (`RaceView`), and nodes
/// that share a z draw in an order of SpriteKit's choosing, which can change from one launch to the next, so a
/// frozen render fixture (#62) drew differently launch to launch wherever they overlapped: the water's streak
/// tiles blended a level apart (#116), and in the start row (#85) a boat's name drew over another's hull in one
/// launch and under it in the next. So nodes that share a layer take their z's a `step` apart, from a slot of
/// their own: a pool slot (`WaterNode`), a seat (`BoatNode`), or the order the course was built in
/// (`GameScene`).
enum DrawOrder {
    /// A layer holds 10,000 slots below the next one's z. SpriteKit sorts z as a Float: at the scene's largest
    /// z (your sail, about 14) a step is still ~100 of its ulps.
    static let step: CGFloat = 1e-4

    /// The z of `slot` within its layer.
    static func z(_ slot: Int) -> CGFloat {
        CGFloat(slot) * step
    }
}
