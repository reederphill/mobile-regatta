import UIKit
import XCTest

/// The race cues draw the same at every thermal tier (#127, #27): cue fixtures rendered with `-cuesOnly`, which hides
/// what the tiers change (the ripple and whitecaps, the wakes and the sails), at `-thermal nominal`, `serious` and
/// `critical`, agree pixel for pixel. No references: each tier is diffed against the nominal render of the same run.
/// `water-pressure` covers the puff shading and the pressure tone, which stand in for the ticket's upwind edge tint
/// (#224's tint is gone: ADR 0008 moved that cue to the minimap, which the ladder never touches).
extension RenderFixtureUITests {
    @objc @MainActor func testCueLayersIdenticalAcrossThermalTiers() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad,
                      "render fixtures are compared on iPhone 17 only; the iPad run doesn't compare them")
        continueAfterFailure = true
        defer { continueAfterFailure = false }
        for name in ["cues", "rules-call", "rules-penalty", "water-pressure"] {
            let nominal = try renderFixture(name, arguments: ["-cuesOnly", "-thermal", "nominal"])
            for thermal in ["serious", "critical"] {
                let render = try renderFixture(name, arguments: ["-cuesOnly", "-thermal", thermal])
                assertMatches(render.image, nominal.image, named: "\(name)-cues-\(thermal)", tolerance: .exact,
                              ignoringBottomRows: max(render.homeIndicatorRows, nominal.homeIndicatorRows))
            }
        }
    }
}
