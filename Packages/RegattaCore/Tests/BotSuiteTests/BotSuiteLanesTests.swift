@testable import BotSuite
import Foundation
import RegattaBots
import RegattaCore
import Testing

/// #379 PR 1: the lanes rows, each as the #379 brief's `lanes.py` and `chances.py` define it: the episodes, crossings,
/// line-ups, splits and passes (`LaneTally.lanes`) on two boats' tracks written out by hand, a second at a time after the
/// gun; and the rows pooled from them (`LanesSummary`) on records written out by hand.
@Suite struct BotSuiteLanesTests {
    // MARK: - Tracks

    /// The wind comes from up the course (+y).
    private static let wind = (x: 0.0, y: 1.0)
    /// Close-hauled on starboard and port, and running on each gybe (unit headings, x across, y up the course).
    private static let starboardBeat = (x: 0.6, y: 0.8), portBeat = (x: -0.6, y: 0.8)
    private static let starboardRun = (x: 0.6, y: -0.8), portRun = (x: -0.6, y: -0.8)

    private func boat(_ mode: LaneMode?, x: Double, y: Double, heading: (x: Double, y: Double), starboard: Bool,
                      toMark: Double, leg: Int = 0, vmg: Double = 2) -> LaneSample {
        LaneSample(leg: leg, mode: mode, x: x, y: y, forwardX: heading.x, forwardY: heading.y, windX: Self.wind.x,
                   windY: Self.wind.y, starboard: starboard, vmg: vmg, toMark: toMark)
    }

    /// Two boats a second at a time for `seconds`, seat 0 then seat 1, a pair each second both race: `distance` apart
    /// (hull lengths), with seat 0's air at seat 1 (`air0`: ribbon loss, backwind degrees) and seat 1's at seat 0.
    private func lanes(seconds: Int = 120, _ seat0: (Int) -> LaneSample?, _ seat1: (Int) -> LaneSample?,
                       distance: @escaping (Int) -> Double = { _ in 2 },
                       air0: (Int) -> (Double, Double) = { _ in (0, 0) }, air1: (Int) -> (Double, Double) = { _ in (0, 0) },
                       reactionDelays: [Double] = [0, 0]) -> RaceLanes {
        let samples = (0..<seconds).map { [seat0($0), seat1($0)] }
        let pairs = (0..<seconds).map { t -> [LanePair] in
            guard samples[t][0] != nil, samples[t][1] != nil else { return [] }
            let (r0, b0) = air0(t), (r1, b1) = air1(t)
            return [LanePair(first: 0, second: 1, distance: distance(t), firstRibbons: r0, firstBackwind: b0,
                             secondRibbons: r1, secondBackwind: b1)]
        }
        return LaneTally.lanes(samples: samples, pairs: pairs, reactionDelays: reactionDelays, hullMetres: 4.9,
                               headerDegrees: 8)
    }

    /// Ribbons at `loss` over `seconds`, nothing else.
    private func ribbons(_ seconds: Set<Int>, _ loss: Double = 0.2) -> (Int) -> (Double, Double) {
        { seconds.contains($0) ? (loss, 0) : (0, 0) }
    }

    /// Beating up the course side by side on starboard: seat 0 (the caster) 0.4 L a second, 1.5 L to windward of seat 1
    /// (across her heading) and 1 L nearer the mark.
    private func caster(tackAt: Int? = nil) -> (Int) -> LaneSample? {
        { t in
            let tacked = tackAt.map { t >= $0 } ?? false
            return self.boat(.upwind, x: 0, y: 0.4 * Double(t), heading: tacked ? Self.portBeat : Self.starboardBeat,
                             starboard: !tacked, toMark: 100 - 0.4 * Double(t))
        }
    }

    private func victim(slowFrom: Int = .max, footsAfter: Int = .max, tackAt: Int? = nil) -> (Int) -> LaneSample? {
        { t in
            let slow = Double(max(0, t - slowFrom)) * 0.1
            let foot = Double(max(0, t - footsAfter)) * 0.1
            let tacked = tackAt.map { t >= $0 } ?? false
            // 1.5 L to leeward of her track: (0.8, -0.6) is to leeward of a starboard beat.
            return self.boat(.upwind, x: 1.2 + 0.8 * foot, y: 0.4 * Double(t) - 0.9 - 0.6 * foot,
                             heading: tacked ? Self.portBeat : Self.starboardBeat, starboard: !tacked,
                             toMark: 101 - 0.4 * Double(t) + slow)
        }
    }

    // MARK: - Episodes

    /// An episode is a run of seconds in her air with gaps of 2 s or less, 2 s long or longer: a 3 s gap splits it,
    /// a lone second is none.
    @Test func episodesJoinGapsOfTwoSecondsAndDropALoneSecond() {
        let joined = lanes(caster(), victim(), air0: ribbons([30, 31, 34, 35]))
        #expect(joined.episodes.map(\.start) == [30] && joined.episodes.map(\.seconds) == [6])
        let split = lanes(caster(), victim(), air0: ribbons([30, 31, 35, 36]))
        #expect(split.episodes.map(\.start) == [30, 35])
        let lone = lanes(caster(), victim(), air0: ribbons([30, 40]))
        #expect(lone.episodes.isEmpty)
        // Either boat not sailing the same way (a reach) in a second drops it from the run.
        let reaching = lanes(caster(), { t in t == 31 ? self.boat(nil, x: 1.2, y: 0, heading: Self.starboardBeat,
                                                                   starboard: true, toMark: 90) : self.victim()(t) },
                             air0: ribbons([30, 31]))
        #expect(reaching.episodes.isEmpty)
    }

    /// U1 against U1b: mostly her ribbons, or mostly her backwind (its degrees over the class's header against the loss).
    @Test func upwindEpisodesAreRibbonsOrBackwindByWhichIsMore() {
        let u1 = lanes(caster(), victim(), air0: { (30..<40).contains($0) ? (0.2, 1) : (0, 0) })
        #expect(u1.episodes.map(\.kind) == [.ribbons])
        let u1b = lanes(caster(), victim(), air0: { (30..<40).contains($0) ? (0.1, 3) : (0, 0) })
        #expect(u1b.episodes.map(\.kind) == [.backwind])
        // Opposite tacks upwind count in no row.
        let crossing = lanes(caster(), victim(tackAt: 0), air0: ribbons(Set(30..<40)))
        #expect(crossing.episodes.isEmpty)
    }

    /// The end, the first that holds: her tack up to 3 s after the last second (U1's let go), the victim's, a mark,
    /// either boat's race ending within a second of it, or it sailed out.
    @Test func anEpisodeEndsByTheFirstReasonThatHolds() {
        let air = ribbons(Set(30..<40))
        #expect(lanes(caster(tackAt: 42), victim(), air0: air).episodes.map(\.end) == [.casterTurned])
        #expect(lanes(caster(tackAt: 43), victim(), air0: air).episodes.map(\.end) == [.sailedOut], "past 3 s after")
        #expect(lanes(caster(tackAt: 41), victim(tackAt: 41), air0: air).episodes.map(\.end) == [.casterTurned], "with hers")
        #expect(lanes(caster(), victim(tackAt: 40), air0: air).episodes.map(\.end) == [.victimTurned])
        let rounding = lanes(caster(), { t in self.victim()(t).map { var b = $0; b.leg = t >= 41 ? 1 : 0; return b } }, air0: air)
        #expect(rounding.episodes.map(\.end) == [.mark])
        #expect(lanes(seconds: 41, caster(), victim(), air0: air).episodes.map(\.end) == [.raceEnd])
    }

    /// Sailed out: how the victim left, from her offset a second after against the start, in the caster's frame
    /// (U3's footed out to leeward).
    @Test func sailedOutIsSplitByHowTheVictimLeft() {
        let air = ribbons(Set(30..<40))
        #expect(lanes(caster(), victim(), air0: air).episodes.map(\.exit) == [.other])
        #expect(lanes(caster(), victim(footsAfter: 35), air0: air).episodes.map(\.exit) == [.footedOut])
        #expect(lanes(caster(), victim(slowFrom: 0), air0: air).episodes.first?.exit == .other, "toMark is not the frame")
        let astern = lanes(caster(), { t in self.victim()(t).map { var b = $0; if t > 36 { b.y -= 2 }; return b } }, air0: air)
        #expect(astern.episodes.map(\.exit) == [.droppedAstern])
        let windward = lanes(caster(), { t in self.victim()(t).map { var b = $0; if t > 36 { b.x -= 0.8; b.y += 0.6 }; return b } },
                             air0: air)
        #expect(windward.episodes.map(\.exit) == [.pinchedOut])
        #expect(lanes(caster(tackAt: 41), victim(), air0: air).episodes.first?.exit == nil, "only when sailed out")
    }

    /// Her gain over the episode to a second after it, less the pair's own rate over the 20 s before; as seconds at
    /// her mean VMG; and whether she led at its start and 60 s after.
    @Test func theValueIsTheGainLessThePairsOwnRate() throws {
        // The victim loses 0.1 L a second from the episode's start: 1.0 L over its 10 s, and her rate before was even.
        let episode = try #require(lanes(caster(), victim(slowFrom: 30), air0: ribbons(Set(30..<40))).episodes.first)
        #expect(abs((episode.excessLengths ?? .nan) - 1.0) < 1e-9)
        #expect(abs((episode.excessSeconds ?? .nan) - 1.0 * 4.9 / 2) < 1e-9)
        #expect(episode.aheadAtStart == true && episode.aheadAfter == true)
        // Slower from 20 s before as well: that rate comes out.
        let even = try #require(lanes(caster(), victim(slowFrom: 10), air0: ribbons(Set(30..<40))).episodes.first)
        #expect(abs(even.excessLengths ?? .nan) < 1e-9)
        // From the gun there is no rate before: no value.
        #expect(lanes(caster(), victim(), air0: ribbons([0, 1, 2])).episodes.first?.excessLengths == nil)
    }

    /// U3': the victim was more than 0.5 L ahead of her 15 s before (she came from astern).
    @Test func safeLeewardFromBehindReadsWhereTheVictimWas() {
        let backwind: (Int) -> (Double, Double) = { (30..<40).contains($0) ? (0, 4) : (0, 0) }
        let from = lanes(caster(), { t in self.victim()(t).map { var b = $0; if t < 20 { b.x += 0.6; b.y += 0.8 }; return b } },
                         air0: backwind)
        #expect(from.episodes.map(\.kind) == [.backwind] && from.episodes.map(\.victimWasAhead) == [true])
        #expect(lanes(caster(), victim(), air0: backwind).episodes.map(\.victimWasAhead) == [false])
    }

    // MARK: - Downwind

    /// Running down the course on port, seat 0 `gap` L dead upwind of seat 1 (the leader), both 0.5 L a second.
    private func trailer(gybeAt: Int? = nil) -> (Int) -> LaneSample? {
        { t in
            let gybed = gybeAt.map { t >= $0 } ?? false
            return self.boat(.downwind, x: 0, y: 10 - 0.5 * Double(t), heading: gybed ? Self.starboardRun : Self.portRun,
                             starboard: gybed, toMark: 50 - 0.5 * Double(t))
        }
    }

    private func leader(gap: Double = 5, gybeAt: Int? = nil, starboardFrom: Int? = nil) -> (Int) -> LaneSample? {
        { t in
            let gybed = gybeAt.map { t >= $0 } ?? false
            return self.boat(.downwind, x: 0, y: 10 - gap - 0.5 * Double(t), heading: gybed ? Self.starboardRun : Self.portRun,
                             starboard: gybed, toMark: 50 - gap - 0.5 * Double(t))
        }
    }

    /// D1: a boat ahead along her heading in her air downwind; the line-up its chance: within 8 L, within 30° of dead
    /// downwind of the trailer and not in her air, 3 s or more, taken when an episode on it starts within it or 20 s
    /// after; split at 4 L by its first second's range.
    @Test func lineUpsAreTakenByAnEpisodeWithinTwentySeconds() throws {
        let d1 = lanes(trailer(), leader(), distance: { _ in 5 }, air0: ribbons(Set(20..<30)))
        #expect(d1.episodes.map(\.kind) == [.downwind] && d1.episodes.map(\.start) == [20])
        #expect(d1.lineUps.map(\.start) == [0, 30] && d1.lineUps.map(\.seconds) == [20, 90])
        #expect(d1.lineUps.map(\.taken) == [true, false])
        #expect(d1.lineUps.allSatisfy { $0.rangeLengths == 5 })
        // A boat abeam (more than 30° off dead downwind) is no line-up; one 9 L off is beyond the range.
        let abeam = lanes(trailer(), { t in self.leader()(t).map { var b = $0; b.x += 3; return b } }, distance: { _ in 5.8 })
        #expect(abeam.lineUps.isEmpty)
        #expect(lanes(trailer(), leader(gap: 9), distance: { _ in 9 }).lineUps.isEmpty)
        // A 2 s spell is too short.
        let short = lanes(seconds: 2, trailer(), leader(), distance: { _ in 5 })
        #expect(short.lineUps.isEmpty)
        let summary = try #require(LanesSummary([race([seat(0), seat(1)], lanes: d1)]))
        let all = try #require(summary.tiers.first)
        #expect(all.d1FarLineUps == 2 && all.d1FarTakenShare == 0.5 && all.d1CloseLineUps == 0)
        let close = try #require(LanesSummary([race([seat(0), seat(1)],
                                                    lanes: lanes(trailer(), leader(gap: 3), distance: { _ in 3 },
                                                                 air0: ribbons(Set(20..<30))))]))
        #expect(close.tiers[0].d1CloseLineUps == 2 && close.tiers[0].d1CloseTakenShare == 0.5)
    }

    /// The heated-out row (PR 4's A): a D1 victim out of her air, by gybing away (the end) or heating out (sailed out to
    /// windward), and whether within the victim's reaction delay and 3 s of the start.
    @Test func victimsOutAreGybedOrHeatedOutWithinTheirReaction() {
        let air = ribbons(Set(20..<30))
        let quick = lanes(trailer(), leader(gybeAt: 22), distance: { _ in 5 }, air0: air)
        #expect(quick.episodes.map(\.end) == [.victimTurned] && quick.episodes.map(\.victimOutQuickly) == [true])
        let late = lanes(trailer(), leader(gybeAt: 28), distance: { _ in 5 }, air0: air)
        #expect(late.episodes.map(\.victimOutQuickly) == [false])
        let slowToSee = lanes(trailer(), leader(gybeAt: 28), distance: { _ in 5 }, air0: air, reactionDelays: [0, 6])
        #expect(slowToSee.episodes.map(\.victimOutQuickly) == [true], "within her 6 s reaction and 3 s")
        // Heated out: a second after the end she is more than 0.3 L further up the trailer's windward side.
        let heated = lanes(trailer(), { t in self.leader()(t).map { var b = $0; if t >= 30 { b.x -= 0.8; b.y += 0.6 }; return b } },
                           distance: { _ in 5 }, air0: air)
        #expect(heated.episodes.map(\.exit) == [.pinchedOut] && heated.episodes.map(\.victimOutQuickly) == [false])
        #expect(lanes(trailer(), leader(), distance: { _ in 5 }, air0: air).episodes.map(\.victimOutQuickly) == [nil])
    }

    /// D2: a trailer within 8 L gybes away from the boat ahead (on her old gybe 3 s before); covered if it gybes within
    /// 20 s.
    @Test func splitsAreCoveredByAGybeWithinTwentySeconds() {
        let covered = lanes(trailer(gybeAt: 30), leader(gybeAt: 45))
        #expect(covered.splits.map(\.time) == [30] && covered.splits.map(\.covered) == [true])
        #expect(lanes(trailer(gybeAt: 30), leader(gybeAt: 51)).splits.map(\.covered) == [false])
        // Already on the trailer's new gybe 3 s before: no split.
        #expect(lanes(trailer(gybeAt: 30), leader(gybeAt: 27)).splits.isEmpty)
        // A boat behind gybing is no split for the leader.
        #expect(lanes(trailer(), leader(gybeAt: 30)).splits.isEmpty)
    }

    /// D3: the order of two running boats within 3 L flips by distance to the mark; the side is the passer's (up the wind
    /// of the passed boat or down it); each's seconds in the other's air over the 20 s before.
    @Test func passesReadTheSideAndTheAirBefore() throws {
        let passer: (Int) -> LaneSample? = { t in
            self.boat(.downwind, x: 1, y: 5 - 0.6 * Double(t), heading: Self.portRun, starboard: false, toMark: 50 - 0.6 * Double(t))
        }
        let passed: (Int) -> LaneSample? = { t in
            self.boat(.downwind, x: 0, y: -0.5 * Double(t), heading: Self.portRun, starboard: false, toMark: 47.05 - 0.5 * Double(t))
        }
        let pass = lanes(passer, passed, air0: ribbons(Set(18..<25)))
        #expect(pass.passes.count == 1)
        let p = try #require(pass.passes.first)
        #expect(p.passer == 0 && p.passed == 1 && p.time == 30 && p.windward)
        #expect(p.passerHadPassedSeconds == 7 && p.passedHadPasserSeconds == 0)
        // 3 L apart or more: no pass.
        #expect(lanes(passer, passed, distance: { _ in 3 }).passes.isEmpty)
    }

    // MARK: - Upwind crossings

    /// U2: opposite tacks, both beating, within 8 L, the order across the course flips; the boat further up the course
    /// crosses ahead; taken when she tacks within 6 s and an episode on it starts within 20 s.
    @Test func crossingsAreTakenByATackAndAnEpisode() throws {
        func ahead(tackAt: Int?) -> (Int) -> LaneSample? {
            { t in
                let tacked = tackAt.map { t >= $0 } ?? false
                return self.boat(.upwind, x: 10.05 - 0.5 * Double(t), y: 2, heading: tacked ? Self.portBeat : Self.starboardBeat,
                                 starboard: !tacked, toMark: 50)
            }
        }
        let behind: (Int) -> LaneSample? = { t in
            self.boat(.upwind, x: 0.5 * Double(t) - 10, y: 0, heading: Self.portBeat, starboard: false, toMark: 52)
        }
        let taken = lanes(seconds: 60, ahead(tackAt: 24), behind, air0: ribbons(Set(27..<33)))
        let cross = try #require(taken.crossings.first)
        #expect(taken.crossings.count == 1 && cross.ahead == 0 && cross.behind == 1 && cross.time == 21)
        #expect(abs(cross.marginLengths - 2) < 1e-9 && cross.taken && cross.gainLengths == 0)
        #expect(lanes(seconds: 60, ahead(tackAt: 28), behind, air0: ribbons(Set(29..<33))).crossings.first?.taken == false,
                "she tacked 7 s after")
        #expect(lanes(seconds: 60, ahead(tackAt: 24), behind).crossings.first?.taken == false, "no episode")
        // Outside the 1.5-5 L band the crossing is not kept.
        let wide = lanes(seconds: 60, { t in ahead(tackAt: nil)(t).map { var b = $0; b.y = 6; return b } }, behind)
        #expect(wide.crossings.isEmpty)
    }

    // MARK: - The rows

    private func seat(_ seat: Int, tier: BotTier = .national, engagement: Double? = 0.5) -> SeatMetrics {
        var metrics = SeatMetrics(
            seat: seat, tier: tier, skill: 0.9, status: "racing", finished: false, place: nil, ironsSeconds: 0,
            markContacts: 0, boatContacts: 0, contactsEndingInFouls: 0, contactsToFoulsShare: 0, foulsAsOffender: 0,
            dsqMissedPenalty: 0, ocsCount: 0, edgeSeconds: 0, landContacts: 0, boundaryContacts: 0, preGunIronsSeconds: 0,
            startSeconds: 1, startLineSpot: 0.5)
        metrics.engagement = engagement
        return metrics
    }

    private func race(_ seats: [SeatMetrics], lanes: RaceLanes?) -> RaceResult {
        let cell = BotRaceCell(seed: 1, venue: "dev-venue@3", conditions: "classic-oscillating@3", tideStateDegrees: 0,
                               fleetSize: seats.count, tierMix: .national, profileMix: .live, laps: 1, capSecondsAfterGun: 30)
        var result = RaceResult(cell: cell, finalTick: 0, capped: true, tideStateAtGun: nil, seats: seats,
                                ranks: seats.indices.map { $0 + 1 }, hullLength: 5, timings: TickTimings(samples: [], cpuSeconds: 0))
        result.lanes = lanes
        return result
    }

    private func episode(_ kind: LaneEpisode.Kind, caster: Int = 0, seconds: Int = 5, end: LaneEpisode.End = .sailedOut,
                         exit: LaneEpisode.Exit? = nil, excess: Double? = nil, ahead: (Bool?, Bool?) = (nil, nil),
                         out: Bool? = nil) -> LaneEpisode {
        LaneEpisode(kind: kind, caster: caster, victim: 1 - caster, start: 10, seconds: seconds, end: end, exit: exit,
                    excessLengths: excess, excessSeconds: excess.map { $0 * 2 }, aheadAtStart: ahead.0, aheadAfter: ahead.1,
                    victimWasAhead: nil, victimOutQuickly: out)
    }

    /// Chances a race: the mean over the races, the p90 by nearest rank (`round(p·(n−1))`, half to even) and the most.
    @Test func chancesARaceAreTheMeanTheNearestRankP90AndTheMost() {
        // 0, 1, 2 ... 10 a race: p90 is index round(9.0) = 9.
        let p = LanesSummary.PerRace(Array(0...10))
        #expect(p.mean == 5 && p.p90 == 9 && p.max == 10)
        // Six races: round(4.5) = 4, half to even.
        #expect(LanesSummary.PerRace([0, 1, 2, 3, 4, 5]).p90 == 4)
    }

    /// U1's rows: let go is her own tack; held against let go leaves out the mark's ends; place lost is led at the start
    /// and trailed 60 s on; the playing seats are live bots at engagement 0.3 or more; seconds held a race.
    @Test func u1RowsSplitHeldFromLetGo() throws {
        let one = RaceLanes(episodes: [
            episode(.ribbons, seconds: 6, end: .casterTurned, excess: -1, ahead: (true, false)),
            episode(.ribbons, seconds: 4, end: .sailedOut, exit: .footedOut, excess: 1, ahead: (true, true)),
            episode(.ribbons, seconds: 10, end: .mark, excess: 5),
            episode(.ribbons, caster: 1, seconds: 2, end: .casterTurned, excess: nil),
            episode(.backwind, end: .casterTurned, excess: -0.5),
            episode(.backwind, end: .victimTurned, excess: 0.5),
        ])
        let summary = try #require(LanesSummary([
            race([seat(0, engagement: 0.5), seat(1, engagement: 0.2)], lanes: one),
            race([seat(0), seat(1)], lanes: RaceLanes()),
        ]))
        #expect(summary.races == 2 && summary.tiers.map(\.tier) == [DiagnoseSummary.all, "national"])
        let row = summary.tiers[0]
        #expect(row.u1.mean == 2 && row.u1.max == 4)
        #expect(row.u1LetGoShare == 0.5 && row.u1LetGo.mean == 1)
        #expect(row.u1PlayingEpisodes == 3 && abs(row.u1PlayingLetGoShare - 1.0 / 3) < 1e-12, "seat 1 is not playing")
        #expect(row.u1HeldSeconds.mean == 11 && row.u1HeldSeconds.max == 22)
        #expect(row.u1HeldOverLetGoLengths == 2, "the mark's end left out; a nil excess left out")
        #expect(row.u1PlaceLostHeld == 0 && row.u1PlaceLostLetGo == 1)
        #expect(row.u1EndShares["casterTurned"] == 0.5 && row.u1EndShares["mark"] == 0.25)
        #expect(row.u1ExitShares["footedOut"] == 0.25 && row.u3.mean == 0.5)
        #expect(row.u1b.mean == 1 && row.u1bHeldShare == 0.5 && row.u1bLengths == 0 && row.u1bLetGoPerRace == 0.5)
    }

    /// U2, D1, D2 and D3's shares; the D1 episodes' value, place taken and victims out; and the tier is the boat's with
    /// the chance.
    @Test func downwindRowsAndTiers() throws {
        let lanes = RaceLanes(
            episodes: [
                episode(.downwind, seconds: 3, end: .victimTurned, excess: 2, ahead: (false, true), out: true),
                episode(.downwind, seconds: 5, end: .sailedOut, exit: .pinchedOut, excess: 1, ahead: (false, false), out: false),
                episode(.downwind, caster: 1, seconds: 7, end: .casterTurned),
            ],
            crossings: [LaneCrossing(ahead: 0, behind: 1, time: 5, marginLengths: 2, taken: true, gainLengths: 1),
                        LaneCrossing(ahead: 1, behind: 0, time: 9, marginLengths: 3, taken: false, gainLengths: -1)],
            lineUps: [LaneLineUp(trailer: 0, leader: 1, start: 1, seconds: 3, rangeLengths: 4, taken: true),
                      LaneLineUp(trailer: 0, leader: 1, start: 9, seconds: 3, rangeLengths: 4.5, taken: false)],
            splits: [LaneSplit(trailer: 1, leader: 0, time: 5, covered: true)],
            passes: [LanePass(passer: 1, passed: 0, time: 3, windward: true, passedHadPasserSeconds: 3, passerHadPassedSeconds: 2),
                     LanePass(passer: 0, passed: 1, time: 8, windward: false, passedHadPasserSeconds: 0, passerHadPassedSeconds: 5)])
        let summary = try #require(LanesSummary([race([seat(0, tier: .club), seat(1)], lanes: lanes)]))
        #expect(summary.tiers.map(\.tier) == [DiagnoseSummary.all, "club", "national"])
        let all = summary.tiers[0]
        #expect(all.u2.mean == 2 && all.u2TakenShare == 0.5 && all.u2TakenOverNotLengths == 2 && all.u2UntakenPerRace == 1)
        #expect(all.d1LineUps.mean == 2 && all.d1TakenShare == 0.5 && all.d1CloseTakenShare == 1 && all.d1FarTakenShare == 0)
        #expect(all.d1Episodes.mean == 3 && all.d1HeldMedianSeconds == 5 && all.d1Lengths == 1.5 && all.d1Seconds == 3)
        #expect(all.d1TookPlaceShare == 0.5)
        #expect(abs(all.d1VictimGybedShare - 1.0 / 3) < 1e-12 && abs(all.d1VictimHeatedOutShare - 1.0 / 3) < 1e-12)
        #expect(abs(all.d1VictimOutShare - 2.0 / 3) < 1e-12 && abs(all.d1VictimOutQuicklyShare - 1.0 / 3) < 1e-12)
        #expect(all.d2.mean == 1 && all.d2CoveredShare == 1)
        #expect(all.d3DefendedShare == 0.5 && all.d3Windward == 1 && all.d3Leeward == 1)
        #expect(all.d3PasserHadHerShare == 0.5 && all.d3WindwardPasserHadHerShare == 0)
        // Seat 0 is Club: its D1 episodes, its crossing ahead, its line-ups, the split from it and the pass of it.
        let club = summary.tiers[1]
        #expect(club.d1Episodes.mean == 2 && club.u2.mean == 1 && club.d1LineUps.mean == 2 && club.d2.mean == 1)
        #expect(club.d3.mean == 1 && club.d3Windward == 1)
        #expect(summary.tiers[2].d1Episodes.mean == 1 && summary.tiers[2].d2.mean == 0)
        // A race the harness didn't watch: no rows.
        #expect(LanesSummary([race([seat(0)], lanes: nil)]) == nil)
        #expect(summary.lines.first?.hasPrefix("lanes (#379): 1 races") == true)
    }
}
