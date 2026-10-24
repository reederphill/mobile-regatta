import SpriteKit
import RegattaCore

/// The near-miss reach (#344, a debug overlay prototype): on each boat holding right of way in a keep-clear relation
/// with yours, the water her hull sweeps over the umpire's near-miss sweep (#88: ±10° of heading over 0.5 s), a faint
/// white patch on the water. The geometry is the umpire's own (`RulesConfig.NearMissSweep.swept`, from the race's rules
/// configuration via `TickFrame.nearMissSweep`), never worked out here. A keep-clear boat whose hull would lie in it at
/// a check of the sweep is a near miss. Off by default: the tuning panel's Boat toggle or `-nearMissReach` (Debug).
enum NearMissReach {
    /// The seats holding right of way in a relation with `me` (`TickFrame.keepClear`) within `rangeHulls` of her, as
    /// the glows pick them (#123): the other boat where `me` must keep clear, `me` where the other must. None when the
    /// frame carries no relations or `me` is a ghost; a ghost holds none.
    static func rightOfWaySeats(keepClear: [RightOfWay?]?, positions: [Vec2], me: Int, isGhost: (Int) -> Bool,
                                rangeHulls: Double, hullLength: Double) -> Set<Int> {
        guard let keepClear, positions.indices.contains(me), !isGhost(me) else { return [] }
        var seats: Set<Int> = []
        for seat in positions.indices where seat != me && keepClear.indices.contains(seat) && !isGhost(seat) {
            guard let relation = keepClear[seat],
                  RightOfWayGlyph.isInRange(positions[me], positions[seat], rangeHulls: rangeHulls, hullLength: hullLength)
            else { continue }
            seats.insert(relation.keepClear == me ? seat : me)
        }
        return seats
    }

    /// The patch's fill and rim alphas, white: apart from the glyphs and the rule-call line (orange is obligation, #15).
    static let fillAlpha: CGFloat = 0.16
    static let rimAlpha: CGFloat = 0.45
    /// The rim's width in screen points, whatever the zoom.
    static let rimWidth: CGFloat = 1
    /// Its z (`DrawOrder`): over the cues (2), under every boat's flat shadow and glows (5…14) and the standing fleet.
    static let z: CGFloat = 4.5
}

/// `NearMissReach` drawn flat on the water, as the scene draws everything that lies on it (the heel shadows, glows and
/// wakes, `BoatNode`): one shape a right-of-way boat, a child of the world, so the tilt's squash lays it where the
/// standing hull floats (#597). Shapes are added only while the overlay is on and a boat holds right of way, and
/// removed otherwise: off, the scene holds no node for it.
final class NearMissReachOverlay {
    private var shapes: [Int: SKShapeNode] = [:]
    private let ppm: CGFloat

    init(pointsPerMeter: CGFloat) {
        ppm = pointsPerMeter
    }

    /// The seats whose reach draws, ascending, for tests.
    var seats: [Int] { shapes.keys.sorted() }

    /// Draws the reach of `seats`' boats in `world` under `sweep`, as children of `parent` (the scene's world, in world
    /// points), its rim `px` scene points a screen point.
    func update(seats: Set<Int>, world: RenderWorld, sweep: RulesConfig.NearMissSweep, parent: SKNode, px: CGFloat) {
        for (seat, shape) in shapes where !seats.contains(seat) {
            shape.removeFromParent()
            shapes[seat] = nil
        }
        for seat in seats.sorted() where world.boats.indices.contains(seat) {
            let outline = sweep.swept(world.boats[seat], hull: world.boatClass.hull).outline
            guard outline.count >= 3 else {
                shapes[seat]?.removeFromParent()
                shapes[seat] = nil
                continue
            }
            let shape = shapes[seat] ?? {
                let shape = SKShapeNode()
                shape.name = "nearMissReach"
                shape.fillColor = CuePalette.cueWhite.uiColor.withAlphaComponent(NearMissReach.fillAlpha)
                shape.strokeColor = CuePalette.cueWhite.uiColor.withAlphaComponent(NearMissReach.rimAlpha)
                shape.lineJoin = .round
                shape.zPosition = NearMissReach.z + DrawOrder.z(seat)
                parent.addChild(shape)
                shapes[seat] = shape
                return shape
            }()
            let path = CGMutablePath()
            path.addLines(between: outline.map { CGPoint(x: CGFloat($0.x) * ppm, y: CGFloat($0.y) * ppm) })
            path.closeSubpath()
            shape.path = path
            shape.lineWidth = NearMissReach.rimWidth * px
        }
    }

    /// Removes every shape it added.
    func clear() {
        shapes.values.forEach { $0.removeFromParent() }
        shapes = [:]
    }
}
