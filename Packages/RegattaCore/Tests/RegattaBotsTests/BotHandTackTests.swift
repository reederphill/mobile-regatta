import Foundation
import Testing
@testable import RegattaCore
@testable import RegattaBots

/// #459: bots steer their tacks and gybes by hand on a class whose tap sails nothing (`AutohelmTuning.sailsTap` false,
/// skiff@8), as well as their handling draw lets them; every older class keeps the tap and the roll, to the bit.
@Suite struct BotHandTackTests {
    /// An all-bot race's digest after `seconds` on `boatClass`: eight seats, the fleet's normal draw.
    static func digest(seed: UInt64, boatClass: BoatClassFile, seconds: Int = 200) throws -> UInt64 {
        let race = try BotHelmTests.race(seed: seed, boatClass: boatClass)
        var controllers = allBots(race)
        sail(race, &controllers, ticks: seconds * Race.tickRate)
        return race.digest()
    }

    /// Old classes sail the tap and the roll exactly as before #459: an all-bot race on skiff@7 (the default class, the
    /// autohelm off, a roll tack) and on skiff@6 (the autohelm on), pinned on #458's tip before any bot code changed.
    @Test func skiffSevenBotsAreBitIdentical() throws {
        let seven = try Self.digest(seed: 459, boatClass: BoatClassFile.bundled(id: "skiff", version: 7))
        let six = try Self.digest(seed: 459, boatClass: BoatClassFile.bundled(id: "skiff", version: 6))
        #expect(hex64(seven) == "0xa802fd2cfe1d943f")
        #expect(hex64(six) == "0x3c5c84c4afc4054b")
    }
}
