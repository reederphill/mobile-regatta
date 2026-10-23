import RegattaCore
import SpriteKit
import Testing
@testable import Regatta

/// The water's depth (#596, #597): the ripple's wave shader and the light's glint band, behind the water's tier.
@MainActor @Suite struct WaterNodeTests {
    /// At the full tier the ripple sways on its wave shader and the glint twinkles; at the cheap tier (serious heat,
    /// frozen ripple) the wave is off and the glint holds still. The glint's strength and band are `WaterStyle`'s.
    /// The scene's water follows the policy's tier, and its glint stands on the camera.
    @Test func glintAndWavesFollowTheQualityTier() throws {
        let water = WaterNode(pointsPerMeter: Double(GameScene.pointsPerMeter))
        #expect(water.quality == .full)
        #expect(water.rippleShader != nil && water.glintTwinkles)
        #expect(water.glintLook.alpha == Float(WaterStyle.standard.glintAlpha))
        #expect(abs(water.glintLook.band - Float(1 - WaterStyle.standard.glintBand)) < 1e-6)

        water.quality = .cheap
        #expect(water.rippleShader == nil && !water.glintTwinkles)
        water.quality = .full
        #expect(water.rippleShader != nil && water.glintTwinkles)
        // `-cuesOnly` hides it with the ripple: the tiers change it.
        water.hidesRipple = true
        #expect(water.glint.isHidden)
        water.hidesRipple = false
        #expect(!water.glint.isHidden)

        var style = WaterStyle.standard
        style.glintAlpha = 0.35
        style.glintBand = 0.5
        water.style = style
        #expect(water.glintLook.alpha == 0.35 && water.glintLook.band == 0.5)

        let (scene, _) = try GameSceneTests.scene(fixture: "cues")
        let sceneWater = try #require(scene.childNode(withName: "//water") as? WaterNode)
        #expect(sceneWater.glint.parent === scene.camera)
        scene.apply(RenderQualityPolicy(thermalState: .serious, lowPower: false, maxFPS: 60))
        #expect(sceneWater.rippleShader == nil && !sceneWater.glintTwinkles)
        scene.apply(RenderQualityPolicy(thermalState: .nominal, lowPower: false, maxFPS: 60))
        #expect(sceneWater.rippleShader != nil && sceneWater.glintTwinkles)
    }

    /// The wave and the glint run on race time (`u_clock`), never SpriteKit's `u_time` (#597): two draws at the same
    /// race time read the same clock, whatever the wall clock did between them, and a later race time moves it. A
    /// frozen render fixture's scene holds its clock still across frames.
    @Test func waveAndGlintRunOnRaceTime() throws {
        let conditions = try ConditionsFile.bundled(id: "gusty-offshore", version: 3).content
        let wind = GroundWind(direction: 0.1, speed: 8)
        func world(at time: Double) -> WaterWorld {
            WaterWorld(wind: { _ in wind }, courseWind: wind, puffs: [], conditions: conditions, time: time)
        }
        let view = WaterView(center: .zero, sceneSize: CGSize(width: 402, height: 874), scale: 1.25)
        let water = WaterNode(pointsPerMeter: Double(GameScene.pointsPerMeter))
        water.update(world(at: 42.25), view: view, dt: 0)
        let first = water.shaderClock
        #expect(first.wave == 42.25 && first.glint == 42.25)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        water.update(world(at: 42.25), view: view, dt: 0)
        #expect(water.shaderClock == first, "the same race time draws the same water")
        water.update(world(at: 43.25), view: view, dt: 1)
        #expect(water.shaderClock.wave == 43.25 && water.shaderClock.glint == 43.25)
        // Wrapped at 600 s, for the shaders' float precision.
        water.update(world(at: 642.25), view: view, dt: 0)
        #expect(water.shaderClock.glint == 42.25)

        let (scene, _) = try GameSceneTests.scene(fixture: "cues")
        let sceneWater = try #require(scene.childNode(withName: "//water") as? WaterNode)
        let frozen = sceneWater.shaderClock
        #expect(!frozen.glint.isNaN)
        for t in [0.5, 1.0, 3.0] {
            scene.update(t)
            #expect(sceneWater.shaderClock == frozen, "a frozen frame holds its water still")
        }
    }
}
