import CoreGraphics
import SpriteKit
import Testing
@testable import Regatta

/// The race scene draws the same every time (#62): every node it draws has a z of its own (`DrawOrder`). Under
/// `.ignoresSiblingOrder` SpriteKit draws nodes that share a z in an order of its own choosing, which changed from
/// launch to launch, and where they overlapped their blends rounded differently: the water's streak tiles did
/// (#116, `WaterTests.waterDrawsTheSameEveryTime`), then the start row's fleet (#85).
@MainActor @Suite struct DrawOrderTests {
    /// Each fixture's scene, drawn settled, draws no two nodes at one z: not the fleet's shadow cones, backwinds,
    /// wakes, heel shadows, right-of-way glows (#348), hulls, outlines or sails, nor your glow (#117), nor the course, the cues (#122: laylines, ladder
    /// lines, your vane, its tick and arc, and the edge arrow on the camera), the water or its pressure. A second scene from the same fixture, as a second launch makes, draws
    /// the same nodes in the same order, and so does the first drawn again.
    @Test func sceneDrawsTheSameEveryTime() throws {
        for name in ["prestart", "water-gusty-offshore", "water-pressure", "fleet", "cues", "chart-saltings-reach",
                     "rules-call", "rules-penalty"] {
            let (scene, boats) = try Self.scene(fixture: name)
            let drawn = DrawnNode.all(in: scene)
            let shared = Dictionary(grouping: drawn, by: \.z).filter { $0.value.count > 1 }
            let layers = Set(shared.values.flatMap { $0.map(\.layer) }).sorted()
            #expect(shared.isEmpty, "\(name): \(shared.count) z's drawn by more than one node, in \(layers)")
            // Each boat's backwind and wake string (#121), hidden ones too, and the cones' one sheet (each
            // cone is a mask in it, not drawn itself); each boat's heel shadow, right-of-way glow (#348, drawn hidden or
            // not), hull, outline and sail, and the skiff's two sailors' aids and helmets (#120); your glow and roll
            // ring too.
            #expect(boats > 1, "\(name)")
            #expect(drawn.filter { $0.layer == "effects" }.count == 2 * boats + 1, "\(name)")
            #expect(drawn.filter { $0.layer == "fleet" }.count == 9 * boats + 2, "\(name)")
            #expect(drawn.filter { $0.layer == "course" }.count > 4, "\(name)")
            // The chart (#115): the boundary's band and line, the land and its relief, a landmark; shallows where
            // the venue has a current.
            #expect(drawn.filter { $0.layer == ChartLayer.boundaryName }.count == 2, "\(name)")
            #expect(drawn.contains { $0.layer == ChartLayer.landName } && drawn.contains { $0.layer == ChartLayer.landmarksName },
                    "\(name)")
            #expect(drawn.filter { $0.layer == ChartLayer.shallowsName }.count == (name.hasPrefix("chart-saltings") ? 2 : 0),
                    "\(name)")
            // The pressure (#289) under the water's puffs, one sprite of its own.
            #expect(drawn.filter { $0.layer == WaterNode.pressureName && !$0.isHidden }.count == 1, "\(name)")
            for layer in ["water", "laylines", "ladderLines", "windVane", "grooveTick", "vaneArc", "edgeArrow"] {
                #expect(drawn.contains { $0.layer == layer }, "\(name): nothing drawn in the \(layer)")
            }
            // The cues (#122) over the chart and its marks and line (#115), under the fleet; the edge arrow over all.
            let charted = [ChartLayer.shallowsName, ChartLayer.boundaryName, ChartLayer.landName, ChartLayer.landmarksName,
                           "course"]
            let cues = drawn.filter { ["laylines", "ladderLines", "windVane", "grooveTick", "vaneArc"].contains($0.layer) }
            let chartTop = try #require(drawn.filter { charted.contains($0.layer) }.map(\.z).max())
            let fleetBottom = try #require(drawn.filter { $0.layer == "fleet" }.map(\.z).min())
            let arrow = try #require(drawn.first { $0.layer == "edgeArrow" })
            #expect(cues.allSatisfy { $0.z > chartTop && $0.z < fleetBottom }, "\(name)")
            #expect(drawn.allSatisfy { $0.layer == "edgeArrow" || $0.z < arrow.z }, "\(name)")

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
