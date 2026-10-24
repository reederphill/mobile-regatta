import RegattaCore
import SpriteKit
import Testing
@testable import Regatta

/// The water's depth (#596, #597): the ripple's wave shader, behind the water's tier. The light's glint band went
/// in #602: a screen-fixed band of sparkles that read as a dirty-air field with no cause.
@MainActor @Suite struct WaterNodeTests {
    /// At the full tier the ripple sways on its wave shader; at the cheap tier (serious heat, frozen ripple) the
    /// wave is off. The scene's water follows the policy's tier.
    @Test func wavesFollowTheQualityTier() throws {
        let water = WaterNode(pointsPerMeter: Double(GameScene.pointsPerMeter))
        #expect(water.quality == .full)
        #expect(water.rippleShader != nil)
        water.quality = .cheap
        #expect(water.rippleShader == nil)
        water.quality = .full
        #expect(water.rippleShader != nil)

        let (scene, _) = try GameSceneTests.scene(fixture: "cues")
        let sceneWater = try #require(scene.childNode(withName: "//water") as? WaterNode)
        scene.apply(RenderQualityPolicy(thermalState: .serious, lowPower: false, maxFPS: 60))
        #expect(sceneWater.rippleShader == nil)
        scene.apply(RenderQualityPolicy(thermalState: .nominal, lowPower: false, maxFPS: 60))
        #expect(sceneWater.rippleShader != nil)
    }

    /// #602: nothing the water draws is fixed to the screen: no sparkle band on the camera.
    @Test func noScreenFixedGlint() throws {
        let (scene, _) = try GameSceneTests.scene(fixture: "cues")
        let cam = try #require(scene.camera)
        #expect(scene.childNode(withName: "//glint") == nil)
        let additive = cam.children.compactMap { $0 as? SKSpriteNode }.filter { $0.blendMode == .add && $0.zPosition < 0 }
        #expect(additive.isEmpty, "a sprite on the camera under the water's cues: \(additive.map(\.name))")
    }

    /// The wave runs on race time (`u_clock`), never SpriteKit's `u_time` (#597): two draws at the same race time
    /// read the same clock, whatever the wall clock did between them, and a later race time moves it. A frozen
    /// render fixture's scene holds its clock still across frames.
    @Test func waveRunsOnRaceTime() throws {
        let conditions = try ConditionsFile.bundled(id: "gusty-offshore", version: 3).content
        let wind = GroundWind(direction: 0.1, speed: 8)
        func world(at time: Double) -> WaterWorld {
            WaterWorld(wind: { _ in wind }, courseWind: wind, puffs: [], conditions: conditions, time: time)
        }
        let view = WaterView(center: .zero, sceneSize: CGSize(width: 402, height: 874), scale: 1.25)
        let water = WaterNode(pointsPerMeter: Double(GameScene.pointsPerMeter))
        water.update(world(at: 42.25), view: view, dt: 0)
        let first = water.shaderClock
        #expect(first == 42.25)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        water.update(world(at: 42.25), view: view, dt: 0)
        #expect(water.shaderClock == first, "the same race time draws the same water")
        water.update(world(at: 43.25), view: view, dt: 1)
        #expect(water.shaderClock == 43.25)
        // Wrapped at 600 s, for the shader's float precision.
        water.update(world(at: 642.25), view: view, dt: 0)
        #expect(water.shaderClock == 42.25)

        let (scene, _) = try GameSceneTests.scene(fixture: "cues")
        let sceneWater = try #require(scene.childNode(withName: "//water") as? WaterNode)
        let frozen = sceneWater.shaderClock
        for t in [0.5, 1.0, 3.0] {
            scene.update(t)
            #expect(sceneWater.shaderClock == frozen, "a frozen frame holds its water still")
        }
    }
}
