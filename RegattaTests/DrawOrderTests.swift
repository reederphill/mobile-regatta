import CoreGraphics
import SpriteKit
import Testing
@testable import Regatta

/// The race scene draws the same every time (#62): every node it draws has a z of its own (`DrawOrder`). Under
/// `.ignoresSiblingOrder` SpriteKit draws nodes that share a z in an order of its own choosing, which changed from
/// launch to launch, and where they overlapped their blends rounded differently: the water's streak tiles did
/// (#116, `WaterTests.waterDrawsTheSameEveryTime`), then the start row's fleet (#85).
@MainActor @Suite struct DrawOrderTests {
    /// Each fixture's scene, drawn settled, draws no two nodes at one z: not the fleet's shadow cones, wakes,
    /// hulls, your hull's outline, names, badges or sails (hidden or not: a badge shows when a penalty is owed), nor the course, the
    /// laylines, the water or its pressure. A second scene from the same fixture, as a second launch makes, draws
    /// the same nodes in the same order, and so does the first drawn again.
    @Test func sceneDrawsTheSameEveryTime() throws {
        for name in ["prestart", "water-gusty-offshore", "water-pressure"] {
            let (scene, boats) = try Self.scene(fixture: name)
            let drawn = DrawnNode.all(in: scene)
            let shared = Dictionary(grouping: drawn, by: \.z).filter { $0.value.count > 1 }
            let layers = Set(shared.values.flatMap { $0.map(\.layer) }).sorted()
            #expect(shared.isEmpty, "\(name): \(shared.count) z's drawn by more than one node, in \(layers)")
            // Each boat's cone and wake, and its hull, sail, name and badge; your hull's outline too.
            #expect(boats > 1, "\(name)")
            #expect(drawn.filter { $0.layer == "effects" }.count == 2 * boats, "\(name)")
            #expect(drawn.filter { $0.layer == "fleet" }.count == 4 * boats + 1, "\(name)")
            #expect(drawn.filter { $0.layer == "course" }.count > 4, "\(name)")
            // The pressure (#289) under the water's puffs, one sprite of its own.
            #expect(drawn.filter { $0.layer == WaterNode.pressureName && !$0.isHidden }.count == 1, "\(name)")
            for layer in ["water", "laylines"] {
                #expect(drawn.contains { $0.layer == layer }, "\(name): nothing drawn in the \(layer)")
            }

            #expect(try DrawnNode.all(in: Self.scene(fixture: name).scene) == drawn, "\(name): a second scene drew differently")
            scene.update(1)
            #expect(DrawnNode.all(in: scene) == drawn, "\(name): redrawn settled, the scene moved")
        }
    }

    /// Fixture `name`'s scene in a view, drawn once, and how many boats it has.
    static func scene(fixture name: String) throws -> (scene: GameScene, boats: Int) {
        let (fixture, log) = try RenderFixture.load(named: name, in: RenderFixtureTests.fixtures)
        let session = try GameSession(fixture: fixture, log: log)
        SKView(frame: CGRect(x: 0, y: 0, width: 402, height: 874)).presentScene(session.scene)
        session.scene.update(0)
        return (session.scene, session.driver.currentFrame.boats.count)
    }
}

/// A node the scene draws, where SpriteKit sorts it: at its z in the scene, its own and its ancestors' summed, as
/// a Float, which is how SpriteKit sorts them.
private struct DrawnNode: Equatable {
    var z: Float
    /// The named scene layer it's in (`GameScene` names them).
    var layer: String
    var kind: String
    var position: CGPoint
    var rotation: CGFloat
    var alpha: CGFloat
    var isHidden: Bool

    /// Every sprite, shape and label under `scene`, hidden or not, in z order.
    @MainActor static func all(in scene: SKScene) -> [DrawnNode] {
        nodes(under: scene, in: scene, z: 0, layer: "scene", hidden: false).sorted { $0.z < $1.z }
    }

    @MainActor private static func nodes(under node: SKNode, in scene: SKScene, z: Float, layer: String,
                                         hidden: Bool) -> [DrawnNode] {
        node.children.flatMap { child -> [DrawnNode] in
            let z = z + Float(child.zPosition)
            let layer = child.name ?? layer
            let hidden = hidden || child.isHidden
            var drawn = nodes(under: child, in: scene, z: z, layer: layer, hidden: hidden)
            if child is SKSpriteNode || child is SKShapeNode || child is SKLabelNode {
                drawn.append(DrawnNode(z: z, layer: layer, kind: "\(type(of: child))",
                                       position: child.convert(.zero, to: scene), rotation: child.zRotation,
                                       alpha: child.alpha, isHidden: hidden))
            }
            return drawn
        }
    }
}
