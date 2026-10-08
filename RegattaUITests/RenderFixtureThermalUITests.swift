import UIKit
import XCTest

/// The race cues draw the same at every thermal tier (#127, #27): cue fixtures rendered with `-cuesOnly`, which hides
/// what the tiers change (the ripple and whitecaps, the wakes and the sails), at `-thermal nominal`, `serious` and
/// `critical`, agree pixel for pixel. No references: each tier is diffed against the nominal render of the same run.
/// `water-pressure` covers the puff shading and the pressure tone, which stand in for the ticket's upwind edge tint
/// (#224's tint is gone: ADR 0008 moved that cue to the minimap, which the ladder never touches).
/// One test per fixture: each renders three times (~70 s on CI), well inside the 5 min per-test allowance that the
/// four fixtures together ran into. Each tier is its own launch: `-thermal` is a launch argument, so the tiers can't
/// share one (`renderFixtures` shares a launch only between fixtures of the same arguments).
///
/// A class of its own so that CI can leave it out of a pull request (`-skip-testing`) when the change can't reach
/// what it guards: the race's drawing and the render quality ladder (ci.yml's `sweeps` filter). Main and nightly runs
/// always run it.
final class RenderFixtureThermalUITests: RenderFixtureTestCase {
    @MainActor func testCueLayersIdenticalAcrossThermalTiers() throws { try assertCuesIdenticalAcrossTiers("cues") }
    @MainActor func testRuleCallCuesIdenticalAcrossThermalTiers() throws { try assertCuesIdenticalAcrossTiers("rules-call") }
    @MainActor func testPenaltyCuesIdenticalAcrossThermalTiers() throws { try assertCuesIdenticalAcrossTiers("rules-penalty") }
    @MainActor func testPressureCuesIdenticalAcrossThermalTiers() throws { try assertCuesIdenticalAcrossTiers("water-pressure") }

    @MainActor private func assertCuesIdenticalAcrossTiers(_ name: String) throws {
        try skipOnIPad()
        continueAfterFailure = true
        defer { continueAfterFailure = false }
        let nominal = try renderFixture(name, arguments: ["-cuesOnly", "-thermal", "nominal"])
        for thermal in ["serious", "critical"] {
            let render = try renderFixture(name, arguments: ["-cuesOnly", "-thermal", thermal])
            assertMatches(render.image, nominal.image, named: "\(name)-cues-\(thermal)", tolerance: .exact,
                          ignoringBottomRows: max(render.homeIndicatorRows, nominal.homeIndicatorRows))
        }
    }
}
