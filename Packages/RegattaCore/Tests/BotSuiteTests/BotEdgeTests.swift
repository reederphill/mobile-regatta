import BotSuite
import Foundation
import Testing

/// #82: bots keep off the race area's edge. It reaches only a line's length below the start line, and
/// on the first build with a boundary these cells' bots gybed into it in the pre-start or the late start,
/// where they lay pinned for 12–26 s: a boat stopped bow on turns away only at her class's slowest rate.
@Suite struct BotEdgeTests {
    @Test(arguments: [
        (seed: UInt64(3), conditions: "classic-oscillating@3", fleetSize: 10),
        (seed: UInt64(1), conditions: "sea-breeze@3", fleetSize: 2),
        (seed: UInt64(1), conditions: "light-and-patchy@3", fleetSize: 5),
        (seed: UInt64(2), conditions: "gusty-offshore@3", fleetSize: 5),
    ])
    func botsKeepOffTheRaceAreaEdgeThroughTheStart(seed: UInt64, conditions: String, fleetSize: Int) throws {
        let matrix = BotMatrix(seeds: [seed], conditions: [conditions], fleetSizes: [fleetSize], laps: 2,
                               capSecondsAfterGun: 90)
        for cell in matrix.cells {
            let result = try BotRaceHarness.run(cell)
            for seat in result.seats {
                #expect(seat.boundaryContacts == 0 && seat.landContacts == 0, "seat \(seat.seat)")
            }
        }
    }
}
