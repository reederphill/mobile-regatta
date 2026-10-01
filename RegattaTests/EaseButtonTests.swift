import Testing
import RegattaCore
@testable import Regatta

/// The Ease button (#99, #112): VoiceOver's action toggles it, and each release records your speed for UI tests.
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
