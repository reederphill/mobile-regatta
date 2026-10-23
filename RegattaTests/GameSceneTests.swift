import SpriteKit
import Testing
import RegattaCore
@testable import Regatta

/// The race scene's tilt (#597): the squashed projection every layer draws by.
@MainActor @Suite struct GameSceneTests {
    /// Fixture `name`'s scene at the iPhone's size in a view, drawn once (settled), and its session.
    static func scene(fixture name: String) throws -> (scene: GameScene, session: GameSession) {
        let (fixture, log) = try RenderFixture.load(named: name, in: RenderFixtureTests.fixtures)
        let session = try GameSession(fixture: fixture, log: log)
        let scene = session.scene
        scene.size = CameraRigTests.iPhone
        SKView(frame: CGRect(origin: .zero, size: CameraRigTests.iPhone)).presentScene(scene)
        scene.update(0)
        return (scene, session)
    }

    /// Where world point `v` (metres) draws on screen, read off the node tree as SpriteKit draws it: the world's
    /// transform to the scene (the squash and the camera's turn among its parents), then the camera's.
    static func drawn(_ v: Vec2, in scene: GameScene) throws -> CGPoint {
        let world = try #require(scene.childNode(withName: "//water")?.parent, "no world node")
        let cam = try #require(scene.camera)
        let ppm = GameScene.pointsPerMeter
        let p = world.convert(CGPoint(x: CGFloat(v.x) * ppm, y: CGFloat(v.y) * ppm), to: scene)
        #expect(cam.zRotation == 0)
        return CGPoint(x: (p.x - cam.position.x) / cam.xScale + scene.size.width / 2,
                       y: (p.y - cam.position.y) / cam.yScale + scene.size.height / 2)
    }

    /// At the default 45°, the scene's `screenPoint(of:)` is where the node tree draws a world point; the edge arrow
    /// (a camera child) sits where `EdgeArrow` places the next mark by that squashed projection, not the flat one;
    /// and your wind vane stands on your hull's squashed point.
    @Test func cameraLayersFollowTheSquash() throws {
        let (scene, session) = try Self.scene(fixture: "cues")
        let size = scene.size
        #expect(scene.shownTilt == DeviceSettings.defaultTilt)
        #expect(abs(scene.squash - CGFloat(cos(Double.pi / 4))) < 1e-9)
        let world = session.driver.renderWorld
        for p in world.course.obstacles.map(\.position) + [world.me.position] {
            let drawn = try Self.drawn(p, in: scene), placed = scene.screenPoint(of: p)
            #expect(abs(drawn.x - placed.x) < 0.01 && abs(drawn.y - placed.y) < 0.01, "\(p): drawn \(drawn), placed \(placed)")
        }

        // The next mark is off screen in the cue fixture: the arrow shows, where the squashed projection places it.
        let me = world.me
        let rig = scene.rig
        let targets = EdgeArrow.targets(status: me.status, legIndex: me.legIndex, course: world.course)
        let visible = rig.visibleInsets.visibleRect(sceneSize: size)
        let placed = try #require(EdgeArrow.placement(targets: targets, project: { try! Self.drawn($0, in: scene) },
                                                      visible: visible))
        let arrow = try #require(scene.edgeArrowPlacement, "no edge arrow")
        let onScreen = CGPoint(x: arrow.x + size.width / 2, y: arrow.y + size.height / 2)
        #expect(abs(onScreen.x - placed.position.x) < 0.5 && abs(onScreen.y - placed.position.y) < 0.5,
                "arrow at \(onScreen), placed at \(placed.position)")
        // The flat projection would have put it elsewhere: the check bites.
        let flat = try #require(EdgeArrow.placement(targets: targets, project: { rig.project($0, sceneSize: size) },
                                                    visible: visible))
        #expect(hypot(flat.position.x - placed.position.x, flat.position.y - placed.position.y) > 2,
                "flat \(flat.position) and squashed \(placed.position) agree: the fixture doesn't test the squash")

        let vane = try #require(scene.childNode(withName: "//windVane"))
        let vaneInScene = vane.convert(CGPoint.zero, to: scene)
        let cam = try #require(scene.camera)
        let vaneOnScreen = CGPoint(x: vaneInScene.x / cam.xScale + size.width / 2, y: vaneInScene.y / cam.yScale + size.height / 2)
        let hull = scene.screenPoint(of: me.position)
        #expect(abs(vaneOnScreen.x - hull.x) < 0.01 && abs(vaneOnScreen.y - hull.y) < 0.01,
                "vane at \(vaneOnScreen), hull at \(hull)")
    }

    /// The land's rim is built once (#597): its path is the same object frame after frame, only its copies move, and
    /// they move with the tilt, deeper the steeper the view. (`SKShapeNode.path` hands back a copy, so the scene's own
    /// path is the one compared by identity, and each copy's by value.)
    @Test func landRimIsBuiltOnceAndMovesWithTheTilt() throws {
        let (scene, session) = try Self.scene(fixture: "chart-saltings-reach")
        let layers = scene.landRimLayers
        #expect(layers.count == GameScene.landRimSteps)
        let path = try #require(scene.landRimPath)
        func drawsThePath() -> Bool { layers.allSatisfy { $0.path == path } }
        #expect(drawsThePath(), "every copy draws the rim's path")
        let before = layers.map(\.position)
        #expect(before.allSatisfy { $0 != .zero }, "every copy drops at 45°")

        scene.update(1)
        #expect(scene.landRimPath === path && drawsThePath(), "a second frame rebuilt the rim's path")
        #expect(layers.map(\.position) == before)

        session.controls.tilt = 20
        scene.update(2)
        #expect(scene.shownTilt == 20)
        #expect(scene.landRimPath === path && drawsThePath(), "a tilt change rebuilt the rim's path")
        let after = layers.map(\.position)
        for (a, b) in zip(after, before) {
            #expect(hypot(a.x, a.y) < hypot(b.x, b.y) - 1, "at 20° the rim drops less: \(a) vs \(b)")
        }
    }
}

extension GameSceneTests {
    /// Every node under `node`, itself excluded.
    static func nodeCount(_ node: SKNode) -> Int {
        node.children.reduce(0) { $0 + 1 + nodeCount($1) }
    }

    /// The standing fleet adds one node to the SpriteKit scene, its SK3DNode (#597), whatever the fleet: every boat,
    /// buoy and the committee boat is in its SceneKit scene, at `Boat3D.nodeCount` nodes a boat, a node a buoy and
    /// `Fleet3D.fixedNodeCount` besides.
    @Test func tiltedFleetDrawsWithinBudget() throws {
        let (scene, session) = try Self.scene(fixture: "fleet")
        let boats = session.driver.currentFrame.boats.count
        #expect(boats == 8)
        let fleet = try #require(scene.standingFleet)
        func all(_ node: SKNode) -> [SKNode] { node.children + node.children.flatMap(all) }
        #expect(all(scene).filter { $0 is SK3DNode }.map(ObjectIdentifier.init) == [ObjectIdentifier(fleet.node)],
                "one SK3DNode, the fleet's")
        #expect(Self.nodeCount(fleet.node) == 0, "the SK3DNode holds no SpriteKit nodes")
        let budget = Fleet3D.fixedNodeCount + fleet.buoyTones.count + boats * Boat3D.nodeCount
        #expect(fleet.sceneNodeCount <= budget, "\(fleet.sceneNodeCount) SceneKit nodes, budget \(budget)")
    }
}
