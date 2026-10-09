import CoreGraphics
import Testing
import RegattaCore
@testable import Regatta

/// Ease (#99, #112, #453): a gesture, with VoiceOver's `race-ease` toggle beside it; Ease is on while either is, and
/// each release records your speed for UI tests.
@MainActor @Suite struct EaseButtonTests {
    private static let config = RaceConfig(opponents: 1, prestartSeconds: 60, seed: 1, windSeed: RaceConfig.windSeed(pinnedTo: 1))

    @Test func voiceOverActionTogglesEase() {
        let session = GameSession(config: Self.config)
        #expect(!session.isEasing)
        session.toggleEase()
        #expect(session.isEasing, "the first activation holds Ease")
        session.toggleEase()
        #expect(!session.isEasing, "the second lets it go")
        #expect(session.easeReleases.count == 1)
    }

    /// The gesture's ease and VoiceOver's combine as OR: Ease goes off, and counts a release, only when both are off.
    @Test func gestureAndVoiceOverEaseCombine() {
        let session = GameSession(config: Self.config)
        session.setGestureEase(true)
        #expect(session.isEasing)
        session.toggleEase()
        #expect(session.isEasing && session.isVoiceOverEasing)
        session.setGestureEase(false)
        #expect(session.isEasing, "VoiceOver's still holds it")
        #expect(session.easeReleases.count == 0)
        session.toggleEase()
        #expect(!session.isEasing)
        #expect(session.easeReleases.count == 1)

        session.setGestureEase(true)
        session.setGestureEase(true)
        session.setGestureEase(false)
        #expect(session.easeReleases.count == 2, "a gesture's release counts too")
    }

    /// Releasing the controls (a pause, Help) lets go of a held gesture ease in the interpreter too.
    @Test func releasingTheControlsLetsGoOfTheGesture() {
        let session = GameSession(config: Self.config)
        session.scene.steering.touchBegan(1, at: CGPoint(x: 50, y: 400), midX: 200)
        session.scene.steering.touchBegan(2, at: CGPoint(x: 350, y: 400), midX: 200)
        for _ in 0..<15 { _ = session.scene.steering.advance(by: 1.0 / 60) }
        #expect(session.scene.steering.isEasing)
        session.releaseControls()
        #expect(!session.scene.steering.isEasing && !session.isEasing, "a pause or Help lets go of the gesture")
    }

    @Test func releaseRecordsTheSpeedAtThatMoment() {
        let session = GameSession(config: Self.config)
        session.setEase(false)
        #expect(session.easeReleases.count == 0, "letting go of an Ease not held isn't a release")
        session.driver.tick(5)
        session.setEase(true)
        session.driver.tick(1)
        session.setEase(false)
        let boat = session.driver.currentFrame.boats[session.driver.myBoatIndex]
        #expect(session.easeReleases.count == 1)
        #expect(session.easeReleases.knots == knots(metresPerSecond: boat.speed))
    }
}
