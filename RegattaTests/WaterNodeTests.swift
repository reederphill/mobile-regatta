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
}
