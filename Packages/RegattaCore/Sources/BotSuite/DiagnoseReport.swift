import Foundation
import RegattaBots
import RegattaCore

/// `regatta-botsuite --diagnose`'s tables (#471), pooled over a run's races: the report's `diagnose` key and the text
/// after the gate. Every seat of every race counts, by her tier; `all` is every tier together. Each table is a list of
/// rows in a fixed order (tiers `all`, then those that sailed; causes in their priority order), so two runs of the
/// same matrix give the same bytes.
public struct DiagnoseSummary: Codable, Hashable, Sendable {
    /// The `tier` (and `phase`) of a row over all of them.
    public static let all = "all"
    /// The late-starter tables: a start later than each of these, seconds after the gun, or none.
    public static let lateSeconds = [5, 10]
    /// A turn served with more than this of its 40 s gone is a slow one. Seconds from its clock.
    public static let slowTurnSeconds = 30.0

    public var races: Int
    public var starts: [StartRow]
    public var lateStarters: [LateRow]
    public var penaltyEpisodes: [EpisodeRow]
    public var penaltiesOwed: [OwedRow]
    public var preStartCalls: [CallsRow]
    public var nonFinishers: [NonFinishRow]
    /// Planing off the wind (#462); empty on a class that doesn't plane.
    public var planing: [PlaningRow]

    /// Where the live bots lose their time (#462), by tactics skill, handling skill and kind of leg; empty when no live
    /// bot sailed.
    public var legs: [LegRow]
    /// Mark roundings against the ideal path (#511), by tier and mark; empty when no boat sailed a rounding to its leg's
    /// end.
    public var roundings: [RoundingRow]
    /// Before the gun, the bots' avoidance of a boat not keeping clear (#541, report-only), by tier; nil in a report from
    /// before it.
    public var preGunAvoidance: [PreGunAvoidanceRow]?

    /// `tier`'s bot seats' avoidance before the gun (#541, `SeatMetrics.preGunAvoidLuffs` …): the seat-races with any
    /// (a luff, a bear-away or a centred hold), the decisions of each kind a seat-race, and how the avoiding seats
    /// started against the rest. A seat no bot sailed doesn't count.
    public struct PreGunAvoidanceRow: Codable, Hashable, Sendable {
        public var tier: String
        public var seats: Int
        /// Seat-races with any pre-gun avoidance decision, and their share of `seats`.
        public var avoidingSeats: Int
        public var avoidingShare: Double
        /// Decisions in all, and a seat-race.
        public var luffs: Int
        public var bearAways: Int
        public var holds: Int
        public var luffsPerSeat: Double
        public var bearAwaysPerSeat: Double
        public var holdsPerSeat: Double
        /// Turns to the furthest pass (none clearing), and centred holds given up as early: of those, turned away,
        /// held centred all the same (`Avoidance.heldEarly`, #541 fix round 3) and left to her plan (nil); and OCS
        /// seat-races whose last held-early hold was within 6 s of the gun; and luffs taken early for a boat that can't
        /// keep clear, no other heading clearing (`Avoidance.earlyLuff`, #541 fix round 4).
        public var furthest: Int
        public var holdsRefusedEarly: Int
        public var refusedHoldsTurned: Int
        public var heldEarly: Int
        public var refusedHoldsNil: Int
        public var ocsWithin6sOfHeldEarly: Int
        public var earlyLuffs: Int
        /// Turns up: the largest turn towards the wind, degrees (nil with none), and those decisions over 10°. Every
        /// luff decision counts, the furthest pass's (none clearing) included, not only the luff preference's.
        public var largestTurnUpDegrees: Double?
        public var turnsUpOver10: Int
        /// The luff preference's own picks (#541 Q4): decisions taking a clearing luff over a bear-away that also
        /// cleared, and their sizes, degrees (nil with none).
        public var preferredLuffs: Int
        public var preferredLuffDegrees: Spread?
        public var preferredLuffMaxDegrees: Double?
        /// On time (within `LateCause.onTimeSeconds`; never started is late), mean start of those that started, and
        /// OCS seat-races: the avoiding seats', then the rest's.
        public var avoidingOnTimeShare: Double
        public var restOnTimeShare: Double
        public var avoidingMeanStartSeconds: Double?
        public var restMeanStartSeconds: Double?
        public var avoidingOCS: Int
        public var restOCS: Int
        /// The worst cases: the latest start of an avoiding seat (nil with none started), those never started, and OCS
        /// seat-races whose last avoidance was within 6 s of the gun.
        public var latestStartAfterAvoidance: Double?
        public var avoidingNeverStarted: Int
        public var ocsWithin6sOfAvoidance: Int
    }

    /// `tier`'s roundings of `mark` (`RoundingMark.rawValue`, or `all`): how many metres over the ideal path they were
    /// (`RoundingObservation.extraMetres`; negative for a boat that sailed straight inside the tacking or gybing cone).
    /// A row of no roundings has its counts and shares at 0 and nothing else.
    public struct RoundingRow: Codable, Hashable, Sendable {
        public var tier: String
        public var mark: String
        public var roundings: Int
        public var extraMean: Double?
        public var extra: Spread?
        /// The share `RoundingObservation.wideMetres` or more over: 30 m, 50 m.
        public var over30Share: Double
        public var over50Share: Double
        /// Those that passed the mark on its wrong side before rounding it; the windward row's only.
        public var wrongSide: Int?
        /// Those that overshot the gate's line (`RoundingObservation.overshoots`); the gate row's only.
        public var overshoots: Int?
        /// The gate from her entry to the leg's end against the ideal for that span (#519,
        /// `RoundingObservation.EntryToEnd`): the mean metres and seconds over it, and the seconds' spread. The gate
        /// row's only. Unlike the extra metres' rounding part, it charges a boat that crosses the line at the gate's
        /// centre for her way along it to a mark.
        public var entryToEndExtraMetres: Double?
        public var entryToEndExtraSeconds: Double?
        public var entryToEndSeconds: Spread?
        /// The gate's time and depth beyond it (#519, `RoundingObservation.BelowTheLine`): the seconds from her first
        /// tick below the gate's line to her last, mean and spread; the deepest she was below it, metres, mean and
        /// spread; and the roundings still below it when the exit's window closed, whose seconds are capped there.
        /// The gate row's only. It has no ideal path in it: a clean rounding is a few seconds, not 0.
        public var belowLineSecondsMean: Double?
        public var belowLineSeconds: Spread?
        public var deepestMean: Double?
        public var deepest: Spread?
        public var stillBelow: Int?
    }

    /// The legs of one kind (`LegKind.rawValue`) begun by the live bots of one tactics skill and one handling skill
    /// (tiers, as `AxesSummary`'s buckets).
    public struct LegRow: Codable, Hashable, Sendable {
        public var skill: String
        public var hand: String
        public var kind: String
        /// The bots of that skill and hand, and the legs of the kind they began.
        public var boats: Int
        public var legs: Int
        /// Seconds after the first boat of her race onto the leg that she came onto it.
        public var secondsBehind: Spread?
        /// Sailed to their end.
        public var completedShare: Double
        /// Mean seconds over the fastest boat on the leg in her race, of the completed legs she was given no penalty
        /// turn on, and of those she was; nil of none.
        public var cleanLost: Double?
        public var turnLost: Double?
        /// The share of the legs begun with a penalty turn given on them; and turns, falls off the plane and gybes a
        /// leg begun.
        public var turnShare: Double
        public var turns: Double
        public var falls: Double
        public var gybes: Double
        /// Calls against her a leg begun, by rule (a mark touch under "31").
        public var calls: [String: Double]
    }

    /// `tier`'s planing off the wind (`PlaningObservation`), a boat a race unless said.
    public struct PlaningRow: Codable, Hashable, Sendable {
        public var tier: String
        public var boats: Int
        public var runSeconds: Double
        public var offSeconds: Double
        /// Off the plane, of all the tier's seconds running.
        public var offShare: Double
        public var gybes: Double
        public var falls: Double
        /// By what took her off (`PlaningObservation.Cause.rawValue`, every cause a key).
        public var fallsByCause: [String: Double]
        /// The share of the tier's gybes with a fall off the plane.
        public var fallsPerGybe: Double
        /// Seconds off the plane a fall, of the falls that ended back on it while she ran.
        public var secondsOff: Spread?
        /// Back on the plane within `RaceObserver.backOnSeconds`, of the falls she ran on for that long after.
        public var backOnShare: Double
    }

    /// A tier's starts.
    public struct StartRow: Codable, Hashable, Sendable {
        public var tier: String
        public var boats: Int
        /// Started within `LateCause.onTimeSeconds` of the gun.
        public var onTimeShare: Double
        public var over5Share: Double
        public var over10Share: Double
        public var neverStarted: Int
        /// Of the boats that started; nil when none did.
        public var meanStartSeconds: Double?
    }

    /// The boats of `tier` starting more than `overSeconds` after the gun, or never, whose primary cause is `cause`
    /// (`LateCause.rawValue`, or `all` for the sum).
    public struct LateRow: Codable, Hashable, Sendable {
        public var overSeconds: Int
        public var tier: String
        public var cause: String
        public var boats: Int
        public var perThousand: Double
        /// Of those that started; nil when none did.
        public var meanStartSeconds: Double?
    }

    public struct Spread: Codable, Hashable, Sendable {
        public var median: Double
        public var p90: Double

        /// Nil of nothing.
        init?(_ values: [Double]) {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            let middle = sorted.count / 2
            median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
            p90 = sorted[min(sorted.count - 1, Int(0.9 * Double(sorted.count)))]
        }
    }

    /// The penalty episodes of `tier`'s boats opened in `phase` (`PenaltyPhase.rawValue`); either may be `all`.
    public struct EpisodeRow: Codable, Hashable, Sendable {
        public var tier: String
        public var phase: String
        public var episodes: Int
        public var served: Int
        public var disqualified: Int
        /// Still owed when the race ended.
        public var open: Int
        /// The served episodes of one call and one turn: what the four timings below are over, so each is one turn's.
        public var oneTurnEpisodes: Int
        /// From the call to 30° into the turn.
        public var secondsToStarted: Spread?
        /// From there to served.
        public var secondsTurning: Spread?
        /// From served to 90 % of her target speed, of those that got there in a minute owing nothing.
        public var secondsRecovering: Spread?
        /// From the call to 90 % of her target speed, of the same.
        public var secondsTotal: Spread?
        /// Every served episode: from the call to owing nothing, over its turns.
        public var secondsPerTurn: Spread?
        /// Started turns given up, an episode; and by cause (`ResetCause.rawValue`, every cause a key).
        public var resetsPerEpisode: Double
        public var resetsPerEpisodeByCause: [String: Double]
        /// Under a `tackAndGybe` penalty (#487): recrosses, and first crossings voided by a rounding, an episode
        /// (`PenaltyEpisode.recrosses`, `roundingVoids`); 0 under `fullCircle`.
        public var recrossesPerEpisode: Double
        public var roundingVoidsPerEpisode: Double
        /// Calls on a boat turning (taking a penalty), an episode (`PenaltyEpisode.callsWhileTurning`).
        public var callsWhileTurningPerEpisode: Double
        /// Episodes of two calls or more.
        public var stackedShare: Double
        public var turnsServed: Int
        /// Of them, served with more than `slowTurnSeconds` of the turn's clock gone.
        public var slowTurnShare: Double
    }

    /// The turns `tier`'s boats were given.
    public struct OwedRow: Codable, Hashable, Sendable {
        public var tier: String
        public var boats: Int
        /// Turns given a boat a race: calls that cost one, and mark touches.
        public var turnsPerBoat: Double
        public var owingOneShare: Double
        public var owingTwoShare: Double
        public var owingThreeShare: Double
        /// Episodes opened before her start, a boat.
        public var preStartEpisodesPerBoat: Double
        /// Those opened before the gun, by the seconds left to it at the call.
        public var secondsToGun: GunBuckets
    }

    public struct GunBuckets: Codable, Hashable, Sendable {
        public var over40 = 0
        public var from40To20 = 0
        public var from20To10 = 0
        public var under10 = 0
        /// Opened after the gun by a boat that hadn't started.
        public var afterGun = 0
    }

    /// `tier`'s rule calls as the offender before the gun (`SeatMetrics.preStartCallsByRule`), by rule.
    public struct CallsRow: Codable, Hashable, Sendable {
        public var tier: String
        public var boats: Int
        public var calls: [String: Int]
        public var perBoat: [String: Double]
        /// All of them a boat, and all but rule 21.2's (called while she turned a penalty).
        public var allPerBoat: Double
        public var notTurningPerBoat: Double
    }

    /// The boats of `tier` that didn't finish for `cause` (`NonFinishCause.rawValue`, or `all`).
    public struct NonFinishRow: Codable, Hashable, Sendable {
        public var tier: String
        public var cause: String
        public var boats: Int
        public var perThousand: Double
        /// Of those not disqualified; nil when there are none.
        public var medianMetresToGo: Double?
    }

    /// `seats` are the same races' seats, for the pre-start calls.
    public init(_ diagnoses: [RaceDiagnosis], seats: [SeatMetrics]) {
        races = diagnoses.count
        let boats = diagnoses.flatMap(\.boats)
        let sailed = BotTier.allCases.filter { tier in boats.contains { $0.tier == tier } }
        let groups: [(name: String, boats: [BoatDiagnosis])] =
            [(Self.all, boats)] + sailed.map { tier in (tier.rawValue, boats.filter { $0.tier == tier }) }

        starts = groups.map { group in
            let started = group.boats.compactMap(\.start.startSeconds)
            func later(than seconds: Double) -> Int {
                group.boats.filter { ($0.start.startSeconds ?? .infinity) > seconds }.count
            }
            return StartRow(tier: group.name, boats: group.boats.count,
                            onTimeShare: share(started.filter { $0 <= LateCause.onTimeSeconds }.count, of: group.boats.count),
                            over5Share: share(later(than: 5), of: group.boats.count),
                            over10Share: share(later(than: 10), of: group.boats.count),
                            neverStarted: group.boats.count - started.count, meanStartSeconds: mean(started))
        }
        lateStarters = Self.lateSeconds.flatMap { over in
            groups.flatMap { group -> [LateRow] in
                let late = group.boats.filter { ($0.start.startSeconds ?? .infinity) > Double(over) }
                    .map { (cause: LateCause.of($0.start) ?? .other, seconds: $0.start.startSeconds) }
                func row(_ name: String, _ of: [(cause: LateCause, seconds: Double?)]) -> LateRow {
                    LateRow(overSeconds: over, tier: group.name, cause: name, boats: of.count,
                            perThousand: 1000 * share(of.count, of: group.boats.count),
                            meanStartSeconds: mean(of.compactMap(\.seconds)))
                }
                return LateCause.allCases.map { cause in row(cause.rawValue, late.filter { $0.cause == cause }) }
                    + [row(Self.all, late)]
            }
        }
        let phases: [PenaltyPhase?] = [nil] + PenaltyPhase.allCases
        penaltyEpisodes = groups.flatMap { group in
            let episodes = group.boats.flatMap(\.episodes)
            return phases.map { phase in
                EpisodeRow(tier: group.name, phase: phase?.rawValue ?? Self.all,
                           episodes: phase.map { phase in episodes.filter { $0.phase == phase } } ?? episodes)
            }
        }
        penaltiesOwed = groups.map { group in
            let count = group.boats.count
            let preStart = group.boats.flatMap(\.episodes).filter { $0.phase == .preStart }
            var buckets = GunBuckets()
            for episode in preStart {
                switch -episode.callSeconds {
                case ...0: buckets.afterGun += 1
                case ..<10: buckets.under10 += 1
                case ..<20: buckets.from20To10 += 1
                case ..<40: buckets.from40To20 += 1
                default: buckets.over40 += 1
                }
            }
            return OwedRow(tier: group.name, boats: count,
                           turnsPerBoat: count == 0 ? 0 : Double(group.boats.reduce(0) { $0 + $1.turnsOwed }) / Double(count),
                           owingOneShare: share(group.boats.filter { $0.turnsOwed >= 1 }.count, of: count),
                           owingTwoShare: share(group.boats.filter { $0.turnsOwed >= 2 }.count, of: count),
                           owingThreeShare: share(group.boats.filter { $0.turnsOwed >= 3 }.count, of: count),
                           preStartEpisodesPerBoat: count == 0 ? 0 : Double(preStart.count) / Double(count),
                           secondsToGun: buckets)
        }
        preStartCalls = ([(Self.all, seats)] + sailed.map { tier in (tier.rawValue, seats.filter { $0.tier == tier }) }).map { name, seats in
            var calls: [String: Int] = [:]
            for seat in seats { calls.merge(seat.preStartCallsByRule, uniquingKeysWith: +) }
            let count = Double(max(seats.count, 1))
            let total = calls.values.reduce(0, +)
            return CallsRow(tier: name, boats: seats.count, calls: calls, perBoat: calls.mapValues { Double($0) / count },
                            allPerBoat: Double(total) / count,
                            notTurningPerBoat: Double(total - (calls[RacingRule.takingAPenalty.rawValue] ?? 0)) / count)
        }
        nonFinishers = groups.flatMap { group -> [NonFinishRow] in
            let out = group.boats.compactMap { boat in NonFinishCause.of(boat.finish).map { (cause: $0, finish: boat.finish) } }
            func row(_ name: String, _ of: [(cause: NonFinishCause, finish: FinishObservation)]) -> NonFinishRow {
                NonFinishRow(tier: group.name, cause: name, boats: of.count,
                             perThousand: 1000 * share(of.count, of: group.boats.count),
                             medianMetresToGo: Spread(of.filter { $0.finish.status != .dsq }.map(\.finish.metresToGo))?.median)
            }
            return NonFinishCause.allCases.map { cause in row(cause.rawValue, out.filter { $0.cause == cause }) } + [row(Self.all, out)]
        }
        legs = BotTier.allCases.flatMap { skill in
            BotTier.allCases.flatMap { hand -> [LegRow] in
                let bots = boats.filter { $0.skill == skill && $0.hand == hand }
                guard !bots.isEmpty else { return [] }
                return LegKind.allCases.compactMap { kind in
                    let begun = bots.flatMap(\.legs).filter { $0.kind == kind }
                    guard !begun.isEmpty else { return nil }
                    let count = Double(begun.count)
                    var calls: [String: Int] = [:]
                    for leg in begun { calls.merge(leg.calls, uniquingKeysWith: +) }
                    return LegRow(skill: skill.rawValue, hand: hand.rawValue, kind: kind.rawValue, boats: bots.count, legs: begun.count,
                                  secondsBehind: Spread(begun.map(\.secondsBehind)),
                                  completedShare: share(begun.filter { $0.seconds != nil }.count, of: begun.count),
                                  cleanLost: mean(begun.filter { $0.turns == 0 }.compactMap(\.secondsLost)),
                                  turnLost: mean(begun.filter { $0.turns > 0 }.compactMap(\.secondsLost)),
                                  turnShare: share(begun.filter { $0.turns > 0 }.count, of: begun.count),
                                  turns: Double(begun.reduce(0) { $0 + $1.turns }) / count,
                                  falls: Double(begun.reduce(0) { $0 + $1.falls }) / count,
                                  gybes: Double(begun.reduce(0) { $0 + $1.gybes }) / count,
                                  calls: calls.mapValues { Double($0) / count })
                }
            }
        }
        planing = groups.compactMap { group in
            let seen = group.boats.map(\.planing)
            let count = Double(max(seen.count, 1))
            func sum(_ value: KeyPath<PlaningObservation, Double>) -> Double { seen.reduce(0) { $0 + $1[keyPath: value] } }
            func total(_ value: KeyPath<PlaningObservation, Int>) -> Int { seen.reduce(0) { $0 + $1[keyPath: value] } }
            guard sum(\.runSeconds) > 0 else { return nil }
            return PlaningRow(tier: group.name, boats: seen.count, runSeconds: sum(\.runSeconds) / count,
                              offSeconds: sum(\.offSeconds) / count, offShare: sum(\.offSeconds) / sum(\.runSeconds),
                              gybes: Double(total(\.gybes)) / count, falls: Double(total(\.falls)) / count,
                              fallsByCause: Dictionary(uniqueKeysWithValues: PlaningObservation.Cause.allCases.map { cause in
                                  (cause.rawValue, Double(seen.reduce(0) { $0 + ($1.fallsByCause[cause] ?? 0) }) / count)
                              }),
                              fallsPerGybe: share(total(\.gybesWithAFall), of: total(\.gybes)),
                              secondsOff: Spread(seen.flatMap(\.secondsOff)),
                              backOnShare: share(total(\.fallsBackOn), of: total(\.fallsWatched)))
        }
        let bots = seats.filter { $0.preGunAvoidLuffs != nil }
        preGunAvoidance = ([(Self.all, bots)] + sailed.map { tier in (tier.rawValue, bots.filter { $0.tier == tier }) }).map { name, seats in
            func total(_ value: KeyPath<SeatMetrics, Int?>) -> Int { seats.reduce(0) { $0 + ($1[keyPath: value] ?? 0) } }
            func avoids(_ seat: SeatMetrics) -> Bool {
                (seat.preGunAvoidLuffs ?? 0) + (seat.preGunAvoidBearAways ?? 0) + (seat.preGunAvoidHolds ?? 0) > 0
            }
            let avoiding = seats.filter(avoids)
            let rest = seats.filter { !avoids($0) }
            func onTime(_ of: [SeatMetrics]) -> Double {
                share(of.filter { ($0.startSeconds ?? .infinity) <= LateCause.onTimeSeconds }.count, of: of.count)
            }
            let count = Double(max(seats.count, 1))
            let turnsUp = seats.compactMap(\.preGunAvoidLargestTurnUpDegrees).filter { $0 > 0 }
            let preferred = seats.flatMap { $0.preGunPreferredLuffDegrees ?? [] }
            return PreGunAvoidanceRow(
                tier: name, seats: seats.count, avoidingSeats: avoiding.count, avoidingShare: share(avoiding.count, of: seats.count),
                luffs: total(\.preGunAvoidLuffs), bearAways: total(\.preGunAvoidBearAways), holds: total(\.preGunAvoidHolds),
                luffsPerSeat: Double(total(\.preGunAvoidLuffs)) / count,
                bearAwaysPerSeat: Double(total(\.preGunAvoidBearAways)) / count,
                holdsPerSeat: Double(total(\.preGunAvoidHolds)) / count,
                furthest: total(\.preGunAvoidFurthest), holdsRefusedEarly: total(\.preGunHoldsRefusedEarly),
                refusedHoldsTurned: total(\.preGunRefusedHoldsTurned), heldEarly: total(\.preGunHeldEarly),
                refusedHoldsNil: total(\.preGunHoldsRefusedEarly) - total(\.preGunRefusedHoldsTurned) - total(\.preGunHeldEarly),
                ocsWithin6sOfHeldEarly: seats.filter { $0.ocsCount > 0 && ($0.preGunLastHeldEarlySeconds ?? -.infinity) > -6 }.count,
                earlyLuffs: total(\.preGunEarlyLuffs),
                largestTurnUpDegrees: turnsUp.max(), turnsUpOver10: total(\.preGunAvoidTurnsUpOver10),
                preferredLuffs: preferred.count, preferredLuffDegrees: Spread(preferred),
                preferredLuffMaxDegrees: preferred.max(),
                avoidingOnTimeShare: onTime(avoiding), restOnTimeShare: onTime(rest),
                avoidingMeanStartSeconds: mean(avoiding.compactMap(\.startSeconds)),
                restMeanStartSeconds: mean(rest.compactMap(\.startSeconds)),
                avoidingOCS: avoiding.filter { $0.ocsCount > 0 }.count, restOCS: rest.filter { $0.ocsCount > 0 }.count,
                latestStartAfterAvoidance: avoiding.compactMap(\.startSeconds).max(),
                avoidingNeverStarted: avoiding.filter { $0.startSeconds == nil }.count,
                ocsWithin6sOfAvoidance: avoiding.filter { $0.ocsCount > 0 && ($0.preGunLastAvoidSeconds ?? -.infinity) > -6 }.count)
        }
        let wide = RoundingObservation.wideMetres
        roundings = boats.allSatisfy(\.roundings.isEmpty) ? [] : groups.flatMap { group in
            let seen = group.boats.flatMap(\.roundings)
            return ([nil] + RoundingMark.allCases.map { $0 }).map { (mark: RoundingMark?) in
                let rounded = seen.filter { mark == nil || $0.mark == mark }
                let extras = rounded.map(\.extraMetres)
                let spans = mark == .gate ? rounded.compactMap(\.entryToEnd) : []
                let below = mark == .gate ? rounded.compactMap(\.belowTheLine) : []
                return RoundingRow(tier: group.name, mark: mark?.rawValue ?? Self.all, roundings: rounded.count,
                                   extraMean: mean(extras), extra: Spread(extras),
                                   over30Share: share(extras.filter { $0 >= wide[0] }.count, of: extras.count),
                                   over50Share: share(extras.filter { $0 >= wide[1] }.count, of: extras.count),
                                   wrongSide: mark == .windward && !rounded.isEmpty ? rounded.filter(\.wrongSide).count : nil,
                                   overshoots: mark == .gate && !rounded.isEmpty ? rounded.filter(\.overshoots).count : nil,
                                   entryToEndExtraMetres: mean(spans.map(\.extraMetres)),
                                   entryToEndExtraSeconds: mean(spans.map(\.extraSeconds)),
                                   entryToEndSeconds: Spread(spans.map(\.extraSeconds)),
                                   belowLineSecondsMean: mean(below.map(\.seconds)),
                                   belowLineSeconds: Spread(below.map(\.seconds)),
                                   deepestMean: mean(below.map(\.deepest)), deepest: Spread(below.map(\.deepest)),
                                   stillBelow: below.isEmpty ? nil : below.filter(\.stillBelow).count)
            }
        }
    }

    // MARK: - Text

    /// The tables as text: what `regatta-botsuite --diagnose` prints after the gate. A run of one tier prints that
    /// tier's rows and leaves out `all`'s, which are the same.
    public var lines: [String] {
        let single = starts.count == 2
        let tiers = starts.map(\.tier).filter { !single || $0 != Self.all }
        func printed<Row>(_ rows: [Row], _ tier: KeyPath<Row, String>) -> [Row] { rows.filter { tiers.contains($0[keyPath: tier]) } }
        var lines = ["diagnose: \(races) races; starts by tier (on time is within \(Int(LateCause.onTimeSeconds)) s of the gun):"]
        lines += table([["tier", "boats", "on time", "> 5 s", "> 10 s", "never", "mean start s"]] + printed(starts, \.tier).map {
            [$0.tier, "\($0.boats)", fixed($0.onTimeShare, 3), fixed($0.over5Share, 3), fixed($0.over10Share, 3),
             "\($0.neverStarted)", text($0.meanStartSeconds, 2)]
        })
        for over in Self.lateSeconds {
            lines.append("late starters, more than \(over) s after the gun or never, by primary cause: per 1000 boats (mean start s)")
            var rows: [[String]] = [["cause"] + tiers]
            for (key, label) in LateCause.allCases.map({ ($0.rawValue, $0.label) }) + [(Self.all, Self.all)] {
                var cells: [String] = [label]
                for tier in tiers {
                    let row = lateStarters.first { $0.overSeconds == over && $0.tier == tier && $0.cause == key }
                    cells.append(row.map { "\(fixed($0.perThousand, 1)) (\(text($0.meanStartSeconds, 1)))" } ?? "-")
                }
                rows.append(cells)
            }
            lines += table(rows)
        }
        lines.append("penalty episodes; timings are median / p90 seconds over the served one-turn episodes (n): call to 30° in "
            + "(the first crossing under tackAndGybe), "
            + "turning, served to 90 % of target speed, total; then every served episode's seconds a turn")
        func spread(_ spread: Spread?) -> String { spread.map { "\(fixed($0.median, 1)) / \(fixed($0.p90, 1))" } ?? "-" }
        let shown = penaltyEpisodes.filter { $0.tier == Self.all || ($0.phase == Self.all && !single) }
        func name(_ row: EpisodeRow) -> String {
            row.phase == Self.all ? row.tier : PenaltyPhase(rawValue: row.phase)?.label ?? row.phase
        }
        lines += table([["", "episodes", "n", "call to 30°", "turning", "recovering", "total", "s a turn"]] + shown.map {
            [name($0), "\($0.episodes)", "\($0.oneTurnEpisodes)", spread($0.secondsToStarted), spread($0.secondsTurning),
             spread($0.secondsRecovering), spread($0.secondsTotal), spread($0.secondsPerTurn)]
        })
        lines.append("started turns given up, an episode, by cause; recrosses and rounding voids (tackAndGybe) and calls on a "
            + "boat turning, an episode; episodes of 2+ calls; turns served with more than "
            + "\(Int(Self.slowTurnSeconds)) s gone; episodes ending in a DSQ, and owed at the end")
        var resetRows: [[String]] = [["", "resets"] + ResetCause.allCases.map(\.label)
            + ["recross", "void", "calls turning", "2+ calls", "turns", "> \(Int(Self.slowTurnSeconds)) s", "dsq", "open"]]
        for row in shown {
            var cells: [String] = [name(row), fixed(row.resetsPerEpisode, 3)]
            for cause in ResetCause.allCases { cells.append(fixed(row.resetsPerEpisodeByCause[cause.rawValue] ?? 0, 3)) }
            cells += [fixed(row.recrossesPerEpisode, 3), fixed(row.roundingVoidsPerEpisode, 3),
                      fixed(row.callsWhileTurningPerEpisode, 3), fixed(row.stackedShare, 3), "\(row.turnsServed)", fixed(row.slowTurnShare, 4), "\(row.disqualified)", "\(row.open)"]
            resetRows.append(cells)
        }
        lines += table(resetRows)
        lines.append("turns owed a boat a race, the share of boats owing 1, 2, 3 or more; pre-start episodes a boat, and those "
            + "opened before the gun by the seconds left to it at the call (after: after the gun, not yet started)")
        lines += table([["tier", "turns/boat", ">= 1", ">= 2", ">= 3", "pre-start/boat", "> 40 s", "40-20 s", "20-10 s", "< 10 s", "after"]] + printed(penaltiesOwed, \.tier).map {
            [$0.tier, fixed($0.turnsPerBoat), fixed($0.owingOneShare, 3), fixed($0.owingTwoShare, 3), fixed($0.owingThreeShare, 3),
             fixed($0.preStartEpisodesPerBoat, 3), "\($0.secondsToGun.over40)", "\($0.secondsToGun.from40To20)",
             "\($0.secondsToGun.from20To10)", "\($0.secondsToGun.under10)", "\($0.secondsToGun.afterGun)"]
        })
        lines.append("pre-start calls a boat by rule (all but 21.2, called while she turned a penalty; all):")
        let rules = RacingRule.allCases.map(\.rawValue).filter { rule in preStartCalls.contains { $0.calls[rule] != nil } }
        lines += table([["tier"] + rules + ["but 21.2", "all"]] + printed(preStartCalls, \.tier).map { row in
            [row.tier] + rules.map { fixed(row.perBoat[$0] ?? 0, 3) } + [fixed(row.notTurningPerBoat, 3), fixed(row.allPerBoat, 3)]
        })
        if let avoidance = preGunAvoidance {
            lines.append("pre-gun avoidance (#541): bot seat-races with any (luff, bear-away or centred hold); decisions a "
                + "seat-race; turns to the furthest pass and holds refused as early (turned / held early / nil), with OCS "
                + "within 6 s of a held-early hold, and early luffs for a stopped boat (no other heading clearing); turns up (every turn towards the "
                + "wind, the furthest pass's included): the largest and those over 10°; the luff preference's own picks (a "
                + "clearing luff over a bear-away that also cleared): count, median / max°; "
                + "on time, mean start s and OCS of the avoiding seats / the rest; the latest avoiding start, never "
                + "started, and OCS within 6 s of an avoidance")
            lines += table([["tier", "seats", "avoiding", "luff", "bear", "hold", "furthest", "refused", "turned / held / nil",
                             "ocs < 6 s held", "early luff", "max up°", "up > 10°",
                             "preferred", "pref med / max°",
                             "on time", "mean start", "ocs", "latest", "never", "ocs < 6 s"]]
                + printed(avoidance, \.tier).map {
                    [$0.tier, "\($0.seats)", "\($0.avoidingSeats) (\(fixed($0.avoidingShare, 3)))", fixed($0.luffsPerSeat, 3),
                     fixed($0.bearAwaysPerSeat, 3), fixed($0.holdsPerSeat, 3), "\($0.furthest)", "\($0.holdsRefusedEarly)",
                     "\($0.refusedHoldsTurned) / \($0.heldEarly) / \($0.refusedHoldsNil)", "\($0.ocsWithin6sOfHeldEarly)", "\($0.earlyLuffs)",
                     text($0.largestTurnUpDegrees, 1), "\($0.turnsUpOver10)", "\($0.preferredLuffs)",
                     "\(text($0.preferredLuffDegrees?.median, 1)) / \(text($0.preferredLuffMaxDegrees, 1))",
                     "\(fixed($0.avoidingOnTimeShare, 3)) / \(fixed($0.restOnTimeShare, 3))",
                     "\(text($0.avoidingMeanStartSeconds, 2)) / \(text($0.restMeanStartSeconds, 2))",
                     "\($0.avoidingOCS) / \($0.restOCS)", text($0.latestStartAfterAvoidance, 1), "\($0.avoidingNeverStarted)",
                     "\($0.ocsWithin6sOfAvoidance)"]
                })
        }
        lines.append("non-finishers by cause: per 1000 boats (boats; median metres to go)")
        var finishRows: [[String]] = [["cause"] + tiers]
        for (key, label) in NonFinishCause.allCases.map({ ($0.rawValue, $0.label) }) + [(Self.all, Self.all)] {
            var cells: [String] = [label]
            for tier in tiers {
                let row = nonFinishers.first { $0.tier == tier && $0.cause == key }
                cells.append(row.map { "\(fixed($0.perThousand, 1)) (\($0.boats); \(text($0.medianMetresToGo, 0)))" } ?? "-")
            }
            finishRows.append(cells)
        }
        lines += table(finishRows)
        if !planing.isEmpty {
            lines.append("planing off the wind, a boat a race: seconds running and off the plane (share), gybes, falls off the "
                + "plane (by cause: a gybe, too deep, a lull or a shadow, slow), the share of gybes with a fall, seconds off a fall "
                + "(median / p90), and falls she is back on from within \(Int(RaceObserver.backOnSeconds)) s")
            let causes = PlaningObservation.Cause.allCases.map(\.rawValue)
            lines += table([["tier", "running s", "off s", "off", "gybes", "falls"] + causes + ["falls/gybe", "s off a fall", "back on"]]
                + printed(planing, \.tier).map { row in
                    [row.tier, fixed(row.runSeconds, 1), fixed(row.offSeconds, 1), fixed(row.offShare, 3), fixed(row.gybes), fixed(row.falls)]
                        + causes.map { fixed(row.fallsByCause[$0] ?? 0) }
                        + [fixed(row.fallsPerGybe, 3), spread(row.secondsOff), fixed(row.backOnShare, 3)]
                })
        }
        if !legs.isEmpty {
            lines.append("legs by tactics skill and handling (live bots): legs begun, seconds behind the first boat onto the leg "
                + "(median / p90), the share sailed to their end, mean seconds over the race's fastest boat on the leg without a "
                + "penalty turn and with one, the share with one; turns, falls off the plane and gybes a leg; calls a leg by rule")
            let rules = RacingRule.allCases.map(\.rawValue).filter { rule in legs.contains { $0.calls[rule] != nil } }
            lines += table([["skill", "hand", "leg", "boats", "legs", "behind s", "to its end", "clean s", "turn s", "with a turn",
                             "turns", "falls", "gybes"] + rules]
                + legs.map { row in
                    [row.skill, row.hand, LegKind(rawValue: row.kind)?.label ?? row.kind, "\(row.boats)", "\(row.legs)",
                     spread(row.secondsBehind), fixed(row.completedShare, 3), text(row.cleanLost, 1), text(row.turnLost, 1),
                     fixed(row.turnShare, 3), fixed(row.turns), fixed(row.falls), fixed(row.gybes)]
                        + rules.map { fixed(row.calls[$0] ?? 0, 3) }
                })
        }
        if !roundings.isEmpty {
            lines.append("roundings by tier and mark: extra metres a rounding (approach from \(Int(RoundingObservation.entryRange)) m "
                + "out, the rounding, the \(RoundingObservation.exitSeconds) s after, against the ideal path): mean, median / p90; "
                + "the share of roundings 30 m or more and 50 m or more over; windward roundings that passed the mark on its "
                + "wrong side; gate roundings that spent \(RoundingObservation.overshootSeconds) s or more below the line before "
                + "crossing it; gate roundings from entry to the leg's end against the ideal approach to the better mark and "
                + "round it: mean extra metres and seconds, the seconds' median / p90 (read these for the gate: its rounding "
                + "part starts where she crossed the line, so a centre crossing's way along the line to a mark is free); gate "
                + "roundings below the line, from her first tick more than \(Int(RoundingObservation.belowLine)) m below its level "
                + "(outside a mark too) to her last within the \(RoundingObservation.exitSeconds) s after the leg's end: mean "
                + "seconds, median / p90, the deepest she was, mean and p90 metres, and those still below it then (no ideal "
                + "path in it, so a clean rounding is a few seconds, not 0: compare two trees; it is blind to the approach, "
                + "which the entry-to-end columns catch)")
            func count(_ count: Int?, of row: RoundingRow) -> String {
                count.map { "\($0) (\(fixed(100 * share($0, of: row.roundings), 1))%)" } ?? "-"
            }
            lines += table([["tier", "mark", "roundings", "mean m", "median / p90 m", ">= 30 m", ">= 50 m", "wrong side", "overshoot",
                             "entry to end m", "entry to end s", "median / p90 s", "below the line s", "median / p90 s", "deepest m",
                             "p90 m", "still below"]]
                + printed(roundings, \.tier).map { row in
                    [row.tier, row.mark, "\(row.roundings)", text(row.extraMean, 1), spread(row.extra), fixed(row.over30Share, 3),
                     fixed(row.over50Share, 3), count(row.wrongSide, of: row), count(row.overshoots, of: row),
                     text(row.entryToEndExtraMetres, 1), text(row.entryToEndExtraSeconds, 1), spread(row.entryToEndSeconds),
                     text(row.belowLineSecondsMean, 1), spread(row.belowLineSeconds), text(row.deepestMean, 1),
                     text(row.deepest?.p90, 1), count(row.stillBelow, of: row)]
                })
        }
        return lines
    }
}

extension DiagnoseSummary.EpisodeRow {
    init(tier: String, phase: String, episodes: [PenaltyEpisode]) {
        self.tier = tier
        self.phase = phase
        self.episodes = episodes.count
        let served = episodes.filter { $0.outcome == .served }
        self.served = served.count
        disqualified = episodes.filter { $0.outcome == .disqualified }.count
        open = episodes.filter { $0.outcome == .open }.count
        let oneTurn = served.filter { $0.turnsServed == 1 }
        oneTurnEpisodes = oneTurn.count
        secondsToStarted = .init(oneTurn.compactMap(\.secondsToStarted))
        secondsTurning = .init(oneTurn.compactMap(\.secondsTurning))
        secondsRecovering = .init(oneTurn.compactMap(\.secondsRecovering))
        secondsTotal = .init(oneTurn.compactMap { episode in
            guard let wait = episode.secondsToStarted, let turning = episode.secondsTurning,
                  let recovering = episode.secondsRecovering else { return nil }
            return wait + turning + recovering
        })
        secondsPerTurn = .init(served.compactMap { episode in
            guard let wait = episode.secondsToStarted, let turning = episode.secondsTurning, episode.turnsServed > 0 else { return nil }
            return (wait + turning) / Double(episode.turnsServed)
        })
        let count = Double(max(episodes.count, 1))
        resetsPerEpisodeByCause = Dictionary(uniqueKeysWithValues: ResetCause.allCases.map { cause in
            (cause.rawValue, Double(episodes.reduce(0) { $0 + ($1.resets[cause] ?? 0) }) / count)
        })
        resetsPerEpisode = Double(episodes.reduce(0) { $0 + $1.resets.values.reduce(0, +) }) / count
        recrossesPerEpisode = Double(episodes.reduce(0) { $0 + $1.recrosses }) / count
        roundingVoidsPerEpisode = Double(episodes.reduce(0) { $0 + $1.roundingVoids }) / count
        callsWhileTurningPerEpisode = Double(episodes.reduce(0) { $0 + $1.callsWhileTurning }) / count
        stackedShare = share(episodes.filter { $0.calls >= 2 }.count, of: episodes.count)
        let turns = episodes.flatMap(\.turnSeconds)
        turnsServed = turns.count
        slowTurnShare = share(turns.filter { $0 > DiagnoseSummary.slowTurnSeconds }.count, of: turns.count)
    }
}

private func mean(_ values: [Double]) -> Double? {
    values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
}

private func text(_ value: Double?, _ places: Int) -> String { value.map { fixed($0, places) } ?? "-" }

/// `rows` as lines of aligned columns, the first row the header: the first column left-aligned, the rest right.
private func table(_ rows: [[String]]) -> [String] {
    let widths = (0..<(rows.map(\.count).max() ?? 0)).map { column in
        rows.map { column < $0.count ? $0[column].count : 0 }.max() ?? 0
    }
    return rows.map { row in
        "  " + row.enumerated().map { column, cell in
            let pad = String(repeating: " ", count: widths[column] - cell.count)
            return column == 0 ? cell + pad : pad + cell
        }.joined(separator: "  ")
    }
}
