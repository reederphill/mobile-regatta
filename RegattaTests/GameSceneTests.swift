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
}
