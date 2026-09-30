import Testing
import RegattaCore
@testable import Regatta

/// The Tack/Gybe button is hold and release (#222): the press is the tack, a release after a hold the roll, which
/// the sim times against the boom crossing (#263).
@MainActor @Suite struct TackButtonTests {
    private static let config = RaceConfig(opponents: 1, prestartSeconds: 60, seed: 1, windSeed: RaceConfig.windSeed(pinnedTo: 1))

    private func tackTaps(_ session: GameSession) throws -> [InputRecord] {
        try #require(session.driver as? PracticeDriver).log.inputs
            .filter { $0.seat == session.driver.myBoatIndex && $0.kind == .tap(.tackGybe) }
    }

    private func me(_ session: GameSession) -> Boat {
        session.driver.currentFrame.boats[session.driver.myBoatIndex]
    }

    @Test func quickTapSendsOneInput() throws {
        let session = GameSession(config: Self.config)
        session.pressTack(at: 100)
        session.driver.tick(Race.dt)
        #expect(TackHold.isInTack(me(session)), "the press started a tack")
        session.releaseTack(at: 100.1)
        session.driver.tick(1)
        #expect(try tackTaps(session).count == 1)

        // Pure: a release under 0.3 s is a plain tack, even in the tack.
        var hold = TackHold()
        let r1 = hold.press(at: 0, inManoeuvre: false)
        #expect(r1)
        let r2 = hold.release(at: 0.29, inTack: true)
        #expect(!r2)
    }

    @Test func releaseAfterHoldSendsTheRollInput() throws {
        let session = GameSession(config: Self.config)
        session.pressTack(at: 100)
        session.driver.tick(Race.dt * 3)
        #expect(TackHold.isInTack(me(session)))
        session.releaseTack(at: 100.4)
        session.driver.tick(Race.dt)
        #expect(try tackTaps(session).count == 2, "the tack, then the roll")
        #expect(me(session).roll != nil, "the sim took the second tap as the roll")

        // A press while she's in the tack is ignored, and so is its release: rolling is the first press's release.
        let pressedTwice = GameSession(config: Self.config)
        pressedTwice.pressTack(at: 100)
        pressedTwice.driver.tick(Race.dt)
        #expect(TackHold.isInTack(me(pressedTwice)))
        pressedTwice.pressTack(at: 100.1)
        pressedTwice.releaseTack(at: 100.5)
        pressedTwice.driver.tick(Race.dt)
        #expect(try tackTaps(pressedTwice).count == 1)
        #expect(me(pressedTwice).roll == nil)

        // Pure: held long enough, but the tack is over (or it was a gybe): nothing.
        var hold = TackHold()
        let r3 = hold.press(at: 0, inManoeuvre: false)
        #expect(r3)
        let r4 = hold.release(at: 2, inTack: false)
        #expect(!r4)
        let r5 = hold.press(at: 5, inManoeuvre: false)
        #expect(r5)
        let r6 = hold.release(at: 5.35, inTack: true)
        #expect(r6)
        // A press while in a tack or gybe sends nothing, and neither does its release.
        let r7 = hold.press(at: 10, inManoeuvre: true)
        #expect(!r7)
        let r8 = hold.release(at: 11, inTack: true)
        #expect(!r8)
        // A refused press (`-demo`) never rolls.
        let r9 = hold.press(at: 20, inManoeuvre: false)
        #expect(r9)
        hold.pressRefused()
        let r10 = hold.release(at: 21, inTack: true)
        #expect(!r10)
    }
}
