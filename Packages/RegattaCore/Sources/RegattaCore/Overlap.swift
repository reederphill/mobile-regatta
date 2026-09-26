/// Clear astern, clear ahead and overlap (RRS definitions, #9): two boats overlap when neither is clear
/// astern of the other, or when a boat between them overlaps both. The terms always apply on the same
/// tack; on opposite tacks only when both are sailing more than 90° from the true wind, or rule 18
/// applies between them (#91 adds that clause).
extension Rules {
    /// Whether the overlap terms apply between `a` and `b` (see above; no rule 18 clause yet).
    public static func overlapTermsApply(_ a: Boat, _ b: Boat) -> Bool {
        a.tack == b.tack || (a.twa > .pi / 2 && b.twa > .pi / 2)
    }

    /// How far the foremost point of `aHull` (world coordinates) is ahead of a line abeam of `b`'s stern,
    /// along `b`'s heading: negative when `a` is clear astern of `b`.
    static func aftness(_ aHull: [Vec2], of b: Boat, hullLength: Double) -> Double {
        let stern = b.position - b.forward * hullLength / 2
        var foremost = -Double.infinity
        for point in aHull { foremost = max(foremost, (point - stern).dot(b.forward)) }
        return foremost
    }

    /// Whether `c` is between `a` and `b`: it projects strictly inside the segment joining them.
    static func isBetween(_ c: Vec2, _ a: Vec2, _ b: Vec2) -> Bool {
        let ab = b - a
        let along = (c - a).dot(ab)
        return along > 0 && along < ab.lengthSquared
    }

    /// Every pair's overlap as the hulls show it now, including through boats between them, by
    /// `OverlapTracker.index`. Ghosts overlap nobody and are never between.
    ///
    /// A boat is between two others when her centre projects strictly between theirs on the line joining
    /// them. Chains close: the test repeats until no pair changes, so boats overlap through any number
    /// of boats between them, each between the pair it joins. Seat order throughout, so it is deterministic.
    public static func geometricOverlaps(_ boats: [Boat], hull: BoatClass.Hull) -> [Bool] {
        let n = boats.count
        let hulls = boats.map { $0.hull(outline: hull.outline) }
        var applies = [Bool](repeating: false, count: OverlapTracker.pairCount(seats: n))
        var overlapped = applies
        for a in 0..<n where !boats[a].isGhost {
            for b in (a + 1)..<n where !boats[b].isGhost && overlapTermsApply(boats[a], boats[b]) {
                let p = OverlapTracker.index(a, b, seats: n)
                applies[p] = true
                overlapped[p] = aftness(hulls[a], of: boats[b], hullLength: hull.length) >= 0
                    && aftness(hulls[b], of: boats[a], hullLength: hull.length) >= 0
            }
        }
        var changed = true
        while changed {
            changed = false
            for a in 0..<n {
                for b in (a + 1)..<n {
                    let p = OverlapTracker.index(a, b, seats: n)
                    guard applies[p], !overlapped[p] else { continue }
                    for c in 0..<n where c != a && c != b && !boats[c].isGhost {
                        guard overlapped[OverlapTracker.index(min(a, c), max(a, c), seats: n)],
                              overlapped[OverlapTracker.index(min(b, c), max(b, c), seats: n)],
                              isBetween(boats[c].position, boats[a].position, boats[b].position)
                        else { continue }
                        overlapped[p] = true
                        changed = true
                        break
                    }
                }
            }
        }
        return overlapped
    }
}

/// Which pairs of boats are overlapped as of their last point of certainty (#9, CONTEXT.md): a change
/// in a pair's overlap counts only once the hulls have shown it for `margin` ticks in a row, the rules
/// configuration's last point of certainty (15 ticks), so a flickering overlap never changes who has
/// right of way (ADR 0005).
///
/// Array-backed (ADR 0002): one entry per pair `a < b`, at `index(a, b, seats:)`, in seat order.
public struct OverlapTracker: Sendable, Equatable {
    public let seats: Int
    /// By pair: overlapped as of the last point of certainty.
    private var overlapped: [Bool]
    /// By pair: ticks in a row the hulls have shown the other state, 0 ..< margin.
    private var ticksChanging: [Int]

    /// No boat overlapped and nothing changing.
    public init(seats: Int) {
        self.seats = seats
        overlapped = Array(repeating: false, count: Self.pairCount(seats: seats))
        ticksChanging = Array(repeating: 0, count: overlapped.count)
    }

    static func pairCount(seats: Int) -> Int { seats * (seats - 1) / 2 }

    /// The pair `a < b`'s slot: row by row of the upper triangle.
    static func index(_ a: Int, _ b: Int, seats: Int) -> Int {
        a * (2 * seats - a - 1) / 2 + (b - a - 1)
    }

    private func index(_ a: Int, _ b: Int) -> Int { Self.index(min(a, b), max(a, b), seats: seats) }

    /// Whether seats `a` and `b` are overlapped as of their last point of certainty.
    public func isOverlapped(_ a: Int, _ b: Int) -> Bool {
        a != b && overlapped[index(a, b)]
    }

    /// Ticks in a row the hulls of `a` and `b` have shown the state `isOverlapped` doesn't yet report.
    public func changeTicks(_ a: Int, _ b: Int) -> Int {
        a == b ? 0 : ticksChanging[index(a, b)]
    }

    /// One tick: each pair's overlap as its hulls show it now (`Rules.geometricOverlaps`) counts once it
    /// has held for `margin` ticks in a row. A pair with a ghost forgets its overlap at once: a ghost has
    /// no rights or obligations.
    public mutating func update(_ boats: [Boat], hull: BoatClass.Hull, margin: Int) {
        precondition(boats.count == seats, "the tracker has \(seats) seats, not \(boats.count)")
        let now = Rules.geometricOverlaps(boats, hull: hull)
        for a in 0..<seats {
            for b in (a + 1)..<seats {
                let p = Self.index(a, b, seats: seats)
                if boats[a].isGhost || boats[b].isGhost {
                    overlapped[p] = false
                    ticksChanging[p] = 0
                } else if now[p] == overlapped[p] {
                    ticksChanging[p] = 0
                } else {
                    ticksChanging[p] += 1
                    if ticksChanging[p] >= margin {
                        overlapped[p] = now[p]
                        ticksChanging[p] = 0
                    }
                }
            }
        }
    }

    /// The pairs that are overlapped or changing, by `a` then `b`: all a snapshot needs to rebuild it.
    var memory: [WorldSnapshot.OverlapMemory] {
        var entries: [WorldSnapshot.OverlapMemory] = []
        for a in 0..<seats {
            for b in (a + 1)..<seats {
                let p = Self.index(a, b, seats: seats)
                guard overlapped[p] || ticksChanging[p] > 0 else { continue }
                entries.append(.init(pair: .init(a, b), isOverlapped: overlapped[p], changeTicks: ticksChanging[p]))
            }
        }
        return entries
    }

    /// Rebuilt from `memory`, which must name valid pairs (`a < b < seats`); every other pair is not
    /// overlapped and not changing.
    init(seats: Int, memory: [WorldSnapshot.OverlapMemory]) {
        self.init(seats: seats)
        for entry in memory {
            let p = Self.index(entry.pair.a, entry.pair.b, seats: seats)
            overlapped[p] = entry.isOverlapped
            ticksChanging[p] = entry.changeTicks
        }
    }

    /// Adds every pair's state to a digest, in seat order.
    func combine(into h: inout FNV1a) {
        for p in overlapped.indices {
            h.combine(overlapped[p])
            h.combine(ticksChanging[p])
        }
    }
}
