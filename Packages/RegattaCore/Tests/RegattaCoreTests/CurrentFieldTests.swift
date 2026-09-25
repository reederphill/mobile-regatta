import Foundation
import Testing
@testable import RegattaCore

/// `CurrentField` and `TideForecast` (#78) over the test venue: tidal at 19×, peak 1.5 kn, a 5 × 6 grid
/// 200 m apart from (−400, −300), deepest (8 m) down column 2, a 20° shallows lead, and one eddy
/// (flood centre (300, 400), ebb centre (300, 0), core 40 m, outer 150 m, clockwise on the flood).
@Suite struct CurrentFieldTests {
    static let tickRate = Double(Race.tickRate)

    static func current() throws -> Venue.Current { try #require(try VenueFixtures.testVenue().current) }

    static func field(tideStateAtGun: Double) throws -> CurrentField {
        CurrentField(current: try current(), tideStateAtGun: tideStateAtGun)
    }

    /// Deepest node (column 2, row 0): 8 m, no phase lead.
    static let deep = Vec2(0, -300)
    /// Shallow node (column 1, row 0): 2 m, lead 15°.
    static let shallow = Vec2(-200, -300)

    /// Every node of the current grid, and the middle of every cell.
    static func probes(_ current: Venue.Current) -> [Vec2] {
        let grid = current.grid
        var points: [Vec2] = []
        for row in 0..<grid.rows {
            for column in 0..<grid.columns {
                let node = grid.position(column: column, row: row)
                points.append(node)
                if row + 1 < grid.rows && column + 1 < grid.columns {
                    points.append(node + (grid.rowAxis + grid.columnAxis) * grid.cellSize / 2)
                }
            }
        }
        return points
    }

    /// Whether `p` is outside every eddy centre's outer radius.
    static func clearOfEddies(_ p: Vec2, _ current: Venue.Current) -> Bool {
        current.eddies.allSatisfy { ($0.floodCentre - p).length >= $0.outerRadius && ($0.ebbCentre - p).length >= $0.outerRadius }
    }

    // MARK: Acceptance

    @Test func noCurrentVenueIsZeroForAllPositionsAndTimes() throws {
        for version in [1, 2] {
            let venue = try VenueFile.bundled(id: VenueFixtures.devID, version: version).content
            #expect(!venue.hasCurrent)
            #expect(CurrentField.tideStateAtGun(for: venue, raceSeed: RaceSeed(7)) == nil)
            for field in [CurrentField(venue: venue, raceSeed: RaceSeed(7)), CurrentField(venue: venue, tideStateAtGun: 1.2)] {
                #expect(field.phaseRate == 0)
                var nonZero = 0
                for x in stride(from: -3000.0, through: 3000, by: 250) {
                    for y in stride(from: -3000.0, through: 3000, by: 250) {
                        for tick in stride(from: -30 * Race.tickRate, through: 30 * 60 * Race.tickRate, by: 997)
                        where field.sample(Vec2(x, y), tick: tick) != .zero {
                            nonZero += 1
                        }
                    }
                }
                #expect(nonZero == 0)
                let forecast = TideForecast(field: field, window: 0...(1200 * Race.tickRate), points: [Vec2(0, 0)])
                #expect(forecast.locations.isEmpty && forecast.turnsFirst == nil && forecast.peak == 0)
            }
        }
    }

    @Test func channelSlackToPeakTakesAboutTenMinutesAtTheAuthoredClockRate() throws {
        let field = try Self.field(tideStateAtGun: 0)
        #expect(field.current?.tideClockRate == 19)
        #expect(field.channel(Self.deep, tick: 0) == .zero)  // slack at the gun at the deepest node
        var peakTick = 0
        var strongest = 0.0
        for tick in 0...(900 * Race.tickRate) {
            let speed = field.channel(Self.deep, tick: tick).length
            if speed > strongest { (peakTick, strongest) = (tick, speed) }
        }
        let seconds = Double(peakTick) / Self.tickRate
        #expect(abs(seconds - 600) <= 30, "slack to peak \(seconds) s")
        // The forecast agrees.
        let forecast = TideForecast(field: field, window: 0...(900 * Race.tickRate), points: [Self.deep])
        #expect(forecast.locations[0].events.map(\.turn) == [.slackBeforeFlood, .peakFlood])
        #expect(forecast.locations[0].peaks == [peakTick])
    }

    @Test func shallowCellReachesSlackBeforeChannelCell() throws {
        let current = try Self.current()
        let field = try Self.field(tideStateAtGun: deg2rad(330))  // ebbing everywhere at the gun
        func firstSlack(_ p: Vec2) throws -> Int? {
            let flood = try #require(field.floodDirection(at: p))
            #expect(field.channel(p, tick: 0).dot(flood) < 0)
            return (1...(900 * Race.tickRate)).first { field.channel(p, tick: $0).dot(flood) >= 0 }
        }
        let shallow = try #require(try firstSlack(Self.shallow))
        let deep = try #require(try firstSlack(Self.deep))
        #expect(shallow < deep)
        // 15° of lead at 19× is 15/360 of the cycle / 19 ≈ 98 s.
        let lead = current.phaseLead(depth: 2) / field.phaseRate
        #expect(abs(Double(deep - shallow) / Self.tickRate - lead) <= 1.01 / Self.tickRate)
        // The forecast's first turn is at the shallowest wet node.
        let forecast = TideForecast(field: field, window: 0...(900 * Race.tickRate))
        let first = try #require(forecast.turnsFirst)
        let shallowest = forecast.locations.map(\.depth).min()
        #expect(first.depth == shallowest && first.depth < current.maxDepth)
    }

    @Test func currentReversesNeverRotatesAtEveryCell() throws {
        let current = try Self.current()
        let field = try Self.field(tideStateAtGun: 0.3)
        let ticks = [-60, 0, 150, 300, 600, 900, 1500, 2400].map { $0 * Race.tickRate }
        var checked = 0
        // Cells clear of the eddies, where only the channel current runs (#72 heads-up).
        for p in Self.probes(current) where Self.clearOfEddies(p, current) {
            for t1 in ticks {
                for t2 in ticks where t2 > t1 {
                    let a = field.sample(p, tick: t1), b = field.sample(p, tick: t2)
                    guard a.length > 1e-9 && b.length > 1e-9 else { continue }
                    #expect(abs(a.normalized.cross(b.normalized)) < 1e-9, "\(p) between ticks \(t1) and \(t2)")
                    checked += 1
                }
            }
        }
        #expect(checked > 100)
        // It does reverse: flood and ebb run opposite ways at the deepest node.
        let flood = field.sample(Self.deep, tick: 0), ebb = field.sample(Self.deep, tick: 1500 * Race.tickRate)
        #expect(flood.dot(ebb) < 0)
    }

    @Test func channelCurrentIsAtMostPeakEverywhereAndPeakAtTheDeepestCellAtPeakTide() throws {
        let current = try Self.current()
        // The bound is on the channel term: an eddy can add to it (docs/venue-file.md, #72 heads-up).
        let field = try Self.field(tideStateAtGun: 0)
        let cycle = Venue.Current.tidalCycle / current.tideClockRate
        let grid = current.grid
        var strongest = 0.0
        for tick in stride(from: 0, through: Int(cycle * Self.tickRate), by: 20 * Race.tickRate) {
            for x in stride(from: -450.0, through: 450, by: 25) {
                for y in stride(from: -350.0, through: 750, by: 25) {
                    strongest = max(strongest, field.channel(Vec2(x, y), tick: tick).length)
                }
            }
        }
        #expect(strongest <= current.peak + 1e-12 && strongest > 0.99 * current.peak)
        let peakTide = try Self.field(tideStateAtGun: .pi / 2)
        var deepest = 0
        for row in 0..<grid.rows {
            for column in 0..<grid.columns where current.depth(column: column, row: row) == current.maxDepth {
                let node = grid.position(column: column, row: row)
                #expect(abs(peakTide.channel(node, tick: 0).length - current.peak) < 1e-12)
                deepest += 1
            }
        }
        #expect(deepest == 3)
    }

    @Test func eddyCentreSideFlipsAcrossSlack() throws {
        let current = try Self.current()
        let eddy = try #require(current.eddies.first)
        let field = try Self.field(tideStateAtGun: 0)
        // East of each centre, on its core radius.
        let floodProbe = eddy.floodCentre + Vec2(eddy.coreRadius, 0)
        let ebbProbe = eddy.ebbCentre + Vec2(eddy.coreRadius, 0)
        func tick(ofLocalPhase phase: Double, at centre: Vec2) -> Int {
            Int(((phase - field.localPhase(at: centre, tick: 0)) / field.phaseRate * Self.tickRate).rounded())
        }
        for (slack, floodBefore) in [(Double.pi, true), (2 * .pi, false)] {
            let slacks = [tick(ofLocalPhase: slack, at: eddy.floodCentre), tick(ofLocalPhase: slack, at: eddy.ebbCentre)]
            let before = slacks.min()! - 60 * Race.tickRate
            let after = slacks.max()! + 60 * Race.tickRate
            for (when, flooding) in [(before, floodBefore), (after, !floodBefore)] {
                let atFlood = field.eddies(floodProbe, tick: when)
                let atEbb = field.eddies(ebbProbe, tick: when)
                if flooding {
                    // Clockwise about the flood centre: south on its east side.
                    #expect(atFlood.y < -1e-3 && abs(atFlood.x) < 1e-9 && atEbb == .zero, "tick \(when)")
                } else {
                    // Anticlockwise about the ebb centre: north on its east side.
                    #expect(atEbb.y > 1e-3 && abs(atEbb.x) < 1e-9 && atFlood == .zero, "tick \(when)")
                }
            }
        }
    }

    @Test func forecastSlackTimeMatchesFieldZeroCrossingWithinOneTick() throws {
        let field = try Self.field(tideStateAtGun: deg2rad(330))
        let window = (-60 * Race.tickRate)...(3000 * Race.tickRate)
        let points = [Vec2(100, 100), Vec2(-150, 250), Vec2(37, 611)]
        let forecast = TideForecast(field: field, window: window, points: points)
        #expect(Array(forecast.locations.prefix(3).map(\.position)) == points)
        var slacks = 0
        for location in forecast.locations {
            #expect(location.peak > 0)
            let flood = try #require(field.floodDirection(at: location.position))
            let flows = window.map { field.channel(location.position, tick: $0).dot(flood) }
            func flow(_ tick: Int) -> Double { flows[tick - window.lowerBound] }
            // Every sign change of the field is a forecast slack within a tick, and the other way round.
            var crossings: [Int] = []
            for tick in window.dropLast() where flow(tick) == 0 || flow(tick) * flow(tick + 1) < 0 {
                crossings.append(flow(tick) == 0 ? tick : tick + 1)
            }
            #expect(crossings.count == location.slacks.count, "\(location.position)")
            for (crossing, slack) in zip(crossings, location.slacks) {
                #expect(abs(crossing - slack) <= 1, "\(location.position): field \(crossing), forecast \(slack)")
            }
            // Slacks alternate with peaks, and the forecast turn matches the flow's sign after it.
            for event in location.events where window.contains(event.tick + 1) && window.contains(event.tick - 1) {
                switch event.turn {
                case .slackBeforeFlood: #expect(flow(event.tick - 1) <= 0 && flow(event.tick + 1) >= 0)
                case .slackBeforeEbb: #expect(flow(event.tick - 1) >= 0 && flow(event.tick + 1) <= 0)
                case .peakFlood, .peakEbb:
                    #expect(abs(flow(event.tick)) >= abs(flow(event.tick - 1)) && abs(flow(event.tick)) >= abs(flow(event.tick + 1)))
                }
            }
            slacks += location.slacks.count
        }
        #expect(slacks >= 2 * forecast.locations.count)
    }

    // MARK: Tide clock and tide state at the gun

    @Test func nonTidalClockRunsAtOneToOne() throws {
        let tidal = try Self.current()
        let steady = Venue.Current(
            peak: tidal.peak, isTidal: false, tideClockRate: 1, allowedTideStatesAtGun: tidal.allowedTideStatesAtGun,
            grid: tidal.grid, depths: tidal.depths, floodDirections: tidal.floodDirections,
            strengthExponent: tidal.strengthExponent, shallowsLead: tidal.shallowsLead, eddies: [], maxDepth: tidal.maxDepth)
        let field = CurrentField(current: steady, tideStateAtGun: .pi / 2)
        let twentyMinutes = 1200 * Race.tickRate
        #expect(abs(field.tideState(atTick: twentyMinutes) - .pi / 2 - 2 * .pi * 1200 / Venue.Current.tidalCycle) < 1e-12)
        let tidalRate = try Self.field(tideStateAtGun: 0).phaseRate
        #expect(abs(tidalRate - 19 * field.phaseRate) < 1e-15)
        // Steady within a race: the peak-flood current barely changes in 20 minutes.
        let start = field.sample(Self.deep, tick: 0), end = field.sample(Self.deep, tick: twentyMinutes)
        #expect((end - start).length < 0.02 * start.length)
        #expect(start.dot(end) > 0)
    }

    @Test func tideStateAtGunIsDrawnFromTheRaceSeedWithinTheAllowedRange() throws {
        let venue = try VenueFixtures.testVenue()
        let range = try Self.current().allowedTideStatesAtGun
        var draws: [Double] = []
        for seed in UInt64(1)...500 {
            let phase = try #require(CurrentField.tideStateAtGun(for: venue, raceSeed: RaceSeed(seed)))
            #expect(phase >= 0 && phase < 2 * .pi && range.contains(phase), "seed \(seed): \(rad2deg(phase))°")
            #expect(CurrentField.tideStateAtGun(for: venue, raceSeed: RaceSeed(seed)) == phase)
            draws.append(phase)
        }
        // Wraps through 0: both sides of it come up.
        #expect(draws.contains { $0 > .pi } && draws.contains { $0 < .pi })
        // Its own stream, first value.
        var rng = SplitMix64(seed: 42, stream: CurrentField.seedStream)
        let expected = fmod(range.from + rng.range(0, range.width), 2 * .pi)
        #expect(CurrentField.tideStateAtGun(for: venue, raceSeed: RaceSeed(42)) == expected)
        #expect(CurrentField(venue: venue, raceSeed: RaceSeed(42)).tideStateAtGun == expected)

        // The whole cycle means any tide state.
        let data = try VenueFixtures.edited([(of: #""fromDegrees": 330, "toDegrees": 30"#, with: #""fromDegrees": 0, "toDegrees": 360"#)])
        let whole = try VenueFile(data: data).content
        var quadrants = Set<Int>()
        for seed in UInt64(1)...200 {
            let phase = try #require(CurrentField.tideStateAtGun(for: whole, raceSeed: RaceSeed(seed)))
            #expect(phase >= 0 && phase < 2 * .pi)
            quadrants.insert(Int(phase / (.pi / 2)))
        }
        #expect(quadrants == [0, 1, 2, 3])
    }

    @Test func fieldIsBilinearBetweenNodesAndZeroBeyondTheGrid() throws {
        let current = try Self.current()
        let field = try Self.field(tideStateAtGun: .pi / 2)
        // Halfway between the 8 m and 3 m nodes of row 0, flood 0° and 355°.
        let mid = Vec2(100, -300)
        #expect(abs(field.depth(at: mid) - 5.5) < 1e-12)
        let flood = try #require(field.floodDirection(at: mid))
        #expect(abs(wrapAngle(flood.bearing - deg2rad(-2.5))) < 1e-12)
        let expected = current.peak * current.relativeStrength(depth: 5.5) * RegattaCore.sin(.pi / 2 + current.phaseLead(depth: 5.5))
        #expect(abs(field.channel(mid, tick: 0).length - expected) < 1e-12)
        // Beyond the outer nodes the channel current is zero; dry nodes have none.
        #expect(field.channel(Vec2(0, -301), tick: 0) == .zero && field.floodDirection(at: Vec2(0, -301)) == nil)
        #expect(field.channel(Vec2(-400, 0), tick: 0) == .zero)
        // Deterministic: the same inputs give the same bits.
        #expect(field.sample(Vec2(310, 380), tick: 12345) == field.sample(Vec2(310, 380), tick: 12345))
    }
}
