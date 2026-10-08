import Testing

/// #404: the seed and tick choice the scenario tests use (`firstSeed`, `firstTick`).
@Suite struct SeedChoiceTests {
    @Test func firstSeedMeetingAConditionIsChosenAndNoneFailsLoudly() throws {
        var asked: [UInt64] = []
        let seed = try firstSeed(in: 3...20) { seed in
            asked.append(seed)
            return seed % 5 == 0
        }
        #expect(seed == 5, "the first seed meeting it")
        #expect(asked == [3, 4, 5], "earlier seeds tried in order and skipped, none after the first match")

        #expect(try firstTick(in: -100...100, step: 30) { $0 > 0 } == 20, "ticks every 30 from the lower bound")

        let none = #expect(throws: NoChoiceMeetsTheCondition.self) { try firstSeed(in: 1...12) { _ in false } }
        #expect(none?.description == "no seed in 1...12 meets the condition (12 tried)")
        let noTick = #expect(throws: NoChoiceMeetsTheCondition.self) { try firstTick(in: 0...90, step: 30) { _ in false } }
        #expect(noTick?.description == "no tick in 0...90 meets the condition (4 tried)")
    }
}
