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
        lines.append("penalty episodes; timings are median / p90 seconds over the served one-turn episodes (n): call to 30° in, "
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
        lines.append("started turns given up, an episode, by cause; episodes of 2+ calls; turns served with more than "
            + "\(Int(Self.slowTurnSeconds)) s gone; episodes ending in a DSQ, and owed at the end")
        var resetRows: [[String]] = [["", "resets"] + ResetCause.allCases.map(\.label)
            + ["2+ calls", "turns", "> \(Int(Self.slowTurnSeconds)) s", "dsq", "open"]]
        for row in shown {
            var cells: [String] = [name(row), fixed(row.resetsPerEpisode, 3)]
            for cause in ResetCause.allCases { cells.append(fixed(row.resetsPerEpisodeByCause[cause.rawValue] ?? 0, 3)) }
            cells += [fixed(row.stackedShare, 3), "\(row.turnsServed)", fixed(row.slowTurnShare, 4), "\(row.disqualified)", "\(row.open)"]
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
