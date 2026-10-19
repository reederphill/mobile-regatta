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

    // MARK: The opening's seated ease (#477)

    /// A practice race on fleet-rules@8, whose opening seats every boat eased: 60 s to the gun, as practice sails.
    private static var openingConfig: RaceConfig {
        var config = RaceConfig(opponents: 3, prestartSeconds: 60, seed: 1, windSeed: RaceConfig.windSeed(pinnedTo: 1))
        config.files.rulesConfiguration = try! RulesConfigFile.bundled(id: "fleet-rules", version: 8).ref
        return config
    }

    /// Runs the scene's frames, a tick each, until the race clock reaches `time`: each frame submits the input as the
    /// scene's `update` does, and `check` reads her held input after its tick.
    private static func sail(_ session: GameSession, to time: Double, check: (BoatInput) -> Void = { _ in }) {
        while session.driver.currentFrame.time < time {
            session.scene.submitInput(after: Race.dt)
            session.driver.tick(Race.dt)
            check(session.driver.currentFrame.heldInputs[session.driver.myBoatIndex])
        }
    }

    /// Hands off, she stays eased from seating through T-30: the scene's every-frame input keeps the opening's ease.
    @Test func handsOffStaysEasedThroughTheOpening() {
        let session = GameSession(config: Self.openingConfig)
        let me = session.driver.myBoatIndex
        #expect(session.driver.currentFrame.time == -60)
        #expect(session.driver.currentFrame.heldInputs[me].ease, "the opening seats her eased")
        #expect(session.isSeatedEasing && session.isEasing)
        var frames = 0
        Self.sail(session, to: -30) { held in
            frames += 1
            #expect(held.ease, "eased at \(session.driver.currentFrame.time) s")
        }
        #expect(frames == 30 * Race.tickRate)
        #expect(session.isSeatedEasing && session.easeReleases.count == 0)
        // A pause or Help touches nothing: she is still eased after it.
        session.releaseControls()
        #expect(session.isSeatedEasing)
    }

    /// Her first touch on the water sheets her in, on the next tick, and Ease is the gesture's from then on.
    @Test func firstTouchSheetsHerIn() {
        let session = GameSession(config: Self.openingConfig)
        let me = session.driver.myBoatIndex
        Self.sail(session, to: -50)
        #expect(session.driver.currentFrame.heldInputs[me].ease)
        session.scene.touchBegan(1, at: CGPoint(x: 350, y: 400), midX: 200)
        #expect(!session.isSeatedEasing && !session.isEasing)
        #expect(session.easeReleases.count == 1, "the seated ease let go")
        Self.sail(session, to: -49) { held in #expect(!held.ease) }
        session.scene.steering.touchEnded(1)
        // Two still fingers ease again, as in any race.
        session.scene.touchBegan(2, at: CGPoint(x: 50, y: 400), midX: 200)
        session.scene.touchBegan(3, at: CGPoint(x: 350, y: 400), midX: 200)
        Self.sail(session, to: -48)
        #expect(session.driver.currentFrame.heldInputs[me].ease && session.isGestureEasing)
    }

    /// VoiceOver shows the seated ease on: its first activation lets it go, the next holds Ease as before.
    @Test func voiceOverLetsGoOfTheSeatedEase() {
        let session = GameSession(config: Self.openingConfig)
        session.toggleEase()
        #expect(!session.isSeatedEasing && !session.isEasing)
        session.toggleEase()
        #expect(session.isVoiceOverEasing)
    }

    /// A race that seats her sheeted in (fleet-rules@7 and older, the default) has no seated ease: the first frame
    /// sends no ease, as before #477.
    @Test func noSeatedEaseWithoutAnOpening() {
        let session = GameSession(config: Self.config)
        #expect(!session.driver.currentFrame.heldInputs[session.driver.myBoatIndex].ease)
        #expect(!session.isSeatedEasing && !session.isEasing)
        Self.sail(session, to: session.driver.currentFrame.time + 1) { held in #expect(!held.ease) }
    }
}
