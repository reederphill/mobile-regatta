/// #404: a test that needs a scenario precondition (a scene that holds her tack, a race your boat finishes) chooses its
/// seed or tick by that condition instead of pinning the value a probe sweep found, so a sim change that moves the
/// outcome moves the choice, not the test. The first value in a bounded range meeting the condition, in order; none
/// meeting it throws, naming the range and how many were tried. Deterministic: no clock, no randomness.
/// (The app tests keep a twin of this in `RegattaTests/SeedChoice.swift`: they can't import a core test target.)
struct NoChoiceMeetsTheCondition: Error, CustomStringConvertible {
    var description: String
}

/// The first seed in `range` that `meets`, trying them in order.
func firstSeed(in range: ClosedRange<UInt64>, where meets: (UInt64) throws -> Bool) throws -> UInt64 {
    try firstChoice(stride(from: range.lowerBound, through: range.upperBound, by: 1), "seed", range, where: meets)
}

/// The first tick in `range`, every `step` ticks from its lower bound, that `meets`, trying them in order.
func firstTick(in range: ClosedRange<Int>, step: Int = 1, where meets: (Int) throws -> Bool) throws -> Int {
    precondition(step > 0, "firstTick steps forward through the range")
    return try firstChoice(stride(from: range.lowerBound, through: range.upperBound, by: step), "tick", range, where: meets)
}

private func firstChoice<S: Sequence, R>(_ values: S, _ what: String, _ range: R,
                                         where meets: (S.Element) throws -> Bool) throws -> S.Element {
    var tried = 0
    for value in values {
        tried += 1
        if try meets(value) { return value }
    }
    throw NoChoiceMeetsTheCondition(description: "no \(what) in \(range) meets the condition (\(tried) tried)")
}
