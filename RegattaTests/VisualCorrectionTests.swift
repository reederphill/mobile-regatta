import Testing
import RegattaCore
@testable import Regatta

@MainActor @Suite struct VisualCorrectionTests {
    private let hull = Race.defaultBoatClass.hull.length

    private func boat(at position: Vec2, heading: Double = 0) -> Boat {
        Boat(id: 0, isPlayer: false, colorIndex: 0, position: position, heading: heading, speed: 0)
    }

    /// A correction halves in about 50 ms, and is down to an eighth by 150 ms (#18, ADR 0005).
    @Test func halvesAnErrorInAboutFiftyMilliseconds() {
        var correction = VisualCorrection(snapDistance: hull)
        let corrected = boat(at: Vec2(10, 10), heading: deg2rad(90))
        correction.correct(shown: boat(at: Vec2(12, 10), heading: deg2rad(80)), corrected: corrected)
        #expect(correction.applied(to: corrected).position == Vec2(12, 10), "it starts where the boat was drawn")

        // In 60 Hz frames: 3 frames is 50 ms.
        for _ in 0..<3 { correction.advance(by: 1.0 / 60) }
        #expect(abs(correction.positionError.x - 1) < 0.01)
        #expect(abs(correction.headingError - deg2rad(-5)) < 0.001)

        for _ in 0..<6 { correction.advance(by: 1.0 / 60) }
        #expect(abs(correction.positionError.x - 0.25) < 0.01, "an eighth of the error left at 150 ms")
        let drawn = correction.applied(to: corrected)
        #expect(abs(drawn.position.x - 10.25) < 0.01)
    }

    @Test func snapsAnErrorLongerThanAHull() {
        var correction = VisualCorrection(snapDistance: hull)
        let corrected = boat(at: Vec2(0, 0))
        correction.correct(shown: boat(at: Vec2(hull + 0.01, 0), heading: 1), corrected: corrected)
        #expect(correction.positionError == .zero)
        #expect(correction.headingError == 0)
        #expect(correction.applied(to: corrected).position == corrected.position)

        correction.correct(shown: boat(at: Vec2(hull - 0.01, 0)), corrected: corrected)
        #expect(correction.positionError.x == hull - 0.01, "one hull length or less eases")
    }

    /// The heading eases the short way round the wrap.
    @Test func headingErrorWrapsTheShortWay() {
        var correction = VisualCorrection(snapDistance: hull)
        let corrected = boat(at: .zero, heading: deg2rad(-179))
        correction.correct(shown: boat(at: .zero, heading: deg2rad(179)), corrected: corrected)
        #expect(abs(correction.headingError - deg2rad(-2)) < 1e-9)
    }
}
