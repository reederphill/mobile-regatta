import Crypto
import Foundation
import Persistence
import RegattaCore
import Synchronization

// Fair-play flags (#155; #26: suspicious patterns are only flagged, alternate accounts an accepted risk). Every night the
// server reads the races that closed in the window from their logs and incident indexes, and flags a player whose
// rule calls run high (contacts above all), whom many different players protest, whose inputs repeat tick for tick from
// race to race, or who leaves just before the close in race after race. A flag goes to the admin queue (#154) and is
// kept a year with the race logs (#28). A flag is only ever looked at: nothing here gives a penalty, and deciding a flag
// doesn't either.

/// The scan's window and thresholds: placeholders until real races tune them (#155).
public struct FairPlaySettings: Sendable, Equatable {
    /// How often the scan runs.
    public var interval: Duration = .seconds(86_400)
    /// The races it reads: those that closed this long before it.
    public var window: TimeInterval = 30 * 86_400
    /// How long an admin has to look at a flag (#34's 24 h, as a report).
    public var reviewWithin: TimeInterval = 24 * 3600
    /// A rate needs this many of her races in the window.
    public var minRaces = 5
    /// Rule calls against her per race (placeholder)...
    public var ruleCallsPerRace = 1.5
    /// ...or those from a contact (placeholder): contact is what spoils another player's race.
    public var contactCallsPerRace = 0.75
    /// Different players protesting her in the window (placeholder).
    public var distinctProtesters = 4
    /// A seat's inputs are compared only past this many records: a player who sat still at the start of two races
    /// mustn't look like a script (placeholder).
    public var minInputs = 60
    /// Gone (disconnected, dropped or left) this long before the close, unfinished and not back (placeholder)...
    public var lateDropSeconds = 60
    /// ...in this many races in the window (placeholder).
    public var lateDrops = 3

    public init() {}
}

/// A closed race as the scans read it (#155, #157): its log, results and incidents decoded, its bots, and who sat where.
public struct ArchivedRace: Sendable {
    public var id: UUID
    public var endedAt: Date
    public var log: RaceLog
    public var summary: RaceSummary
    public var incidents: IncidentIndex
    public var bots: [StoredRaceBot]
    public var seating: RaceSeating

    public init(id: UUID, endedAt: Date, log: RaceLog, summary: RaceSummary, incidents: IncidentIndex, bots: [StoredRaceBot] = [],
                seating: RaceSeating) {
        self.id = id
        self.endedAt = endedAt
        self.log = log
        self.summary = summary
        self.incidents = incidents
        self.bots = bots
        self.seating = seating
    }

    /// The players who sailed their own seats, by seat: not a seat a bot took over before the gun, nor a deleted
    /// player's (#160: her seats are nobody's).
    public var players: [Int: String] {
        var players: [Int: String] = [:]
        for holder in seating.humans { if let player = seating.human(at: holder.seat) { players[holder.seat] = player } }
        return players
    }
}

extension RaceArchive {
    /// A closed race, decoded, with its seating; nil unless it closed.
    public func archivedRace(_ id: UUID, endedAt: Date) async throws -> ArchivedRace? {
        guard let closed = try await closedRace(id) else { return nil }
        return ArchivedRace(id: id, endedAt: endedAt, log: try RaceLog(jsonData: closed.log), summary: try RaceSummary(decoding: closed.results),
                            incidents: try RaceResultsFeed.decodeIncidents(closed.incidents), bots: closed.bots,
                            seating: try await seats(of: id) ?? RaceSeating(humans: []))
    }
}

/// What the scan found about one player: the flag it raises, but for its times.
public struct FairPlayFinding: Sendable, Equatable {
    public var kind: StoredFlag.Kind
    public var playerID: String
    public var value: Double
    public var threshold: Double
    public var raceIDs: [String]
    public var detail: String
}

/// The scan over a window's races, one race at a time (a race's log is read, counted and let go): what each player did,
/// then the findings. Pure.
public struct FairPlayScan: Sendable {
    public let settings: FairPlaySettings

    private struct Tally {
        var races: [String] = []
        var calls = 0
        var contactCalls = 0
        var callRaces: [String] = []
        var protesters: Set<String> = []
        var protestRaces: [String] = []
        var lateDropRaces: [String] = []
    }

    private var tallies: [String: Tally] = [:]
    /// Each seat's inputs by their digest: the player and race of every seat that sailed them.
    private var inputs: [SHA256.Digest: [(player: String, race: String)]] = [:]

    public init(settings: FairPlaySettings) { self.settings = settings }

    public mutating func add(_ race: ArchivedRace) {
        let id = race.id.uuidString
        let players = race.players
        for (seat, player) in players {
            var tally = tallies[player] ?? Tally()
            tally.races.append(id)
            // Rule calls against her (an incident called on her as the offender), and those a contact opened.
            var calls = 0, contacts = 0
            for incident in race.incidents.incidents {
                guard case .called(let call) = incident.outcome, call.offender == seat else { continue }
                calls += 1
                if incident.trigger == .contact { contacts += 1 }
            }
            tally.calls += calls
            tally.contactCalls += contacts
            if calls > 0 { tally.callRaces.append(id) }
            // Other players protesting her: a bot's protest, or her own seat's, isn't one.
            let protesters = Set(race.incidents.protests.filter { $0.protested == seat }.compactMap { players[$0.protester] }).subtracting([player])
            tally.protesters.formUnion(protesters)
            if !protesters.isEmpty { tally.protestRaces.append(id) }
            if Self.leftLate(seat, race, within: settings.lateDropSeconds * Race.tickRate) { tally.lateDropRaces.append(id) }
            tallies[player] = tally
            // Her inputs, tick for tick, as one digest.
            let records = race.log.inputs.filter { $0.seat == seat }
            if records.count >= settings.minInputs {
                var hash = SHA256()
                for record in records { hash.update(data: Data("\(record.tick) \(record.kind)\n".utf8)) }
                inputs[hash.finalize(), default: []].append((player, id))
            }
        }
    }

    /// Whether `seat` went (disconnected, dropped or left) within `ticks` of the close, didn't come back, and didn't
    /// finish.
    static func leftLate(_ seat: Int, _ race: ArchivedRace, within ticks: Int) -> Bool {
        guard race.summary.rows.first(where: { $0.seat == seat })?.code != ResultCode.finished.rawValue else { return false }
        let events = race.log.seatEvents.filter { $0.seat == seat }
        guard let last = events.last(where: { event in
            switch event.kind {
            case .disconnected, .dropped, .left, .rejoined: true
            default: false
            }
        }) else { return false }
        return last.kind != .rejoined && last.tick >= race.log.finalTick - ticks
    }

    /// What reached a threshold, player by player.
    public func findings() -> [FairPlayFinding] {
        var found: [FairPlayFinding] = []
        for (player, tally) in tallies.sorted(by: { $0.key < $1.key }) {
            let races = Double(tally.races.count)
            if tally.races.count >= settings.minRaces {
                let rate = Double(tally.calls) / races, contactRate = Double(tally.contactCalls) / races
                let detail = "\(tally.calls) rule calls (\(tally.contactCalls) from contact) in \(tally.races.count) races"
                if contactRate >= settings.contactCallsPerRace {
                    found.append(FairPlayFinding(kind: .ruleCalls, playerID: player, value: contactRate, threshold: settings.contactCallsPerRace,
                                                 raceIDs: tally.callRaces, detail: detail + ": contact calls per race"))
                } else if rate >= settings.ruleCallsPerRace {
                    found.append(FairPlayFinding(kind: .ruleCalls, playerID: player, value: rate, threshold: settings.ruleCallsPerRace,
                                                 raceIDs: tally.callRaces, detail: detail + ": rule calls per race"))
                }
            }
            if tally.protesters.count >= settings.distinctProtesters {
                found.append(FairPlayFinding(kind: .protests, playerID: player, value: Double(tally.protesters.count),
                                             threshold: Double(settings.distinctProtesters), raceIDs: tally.protestRaces,
                                             detail: "protested by \(tally.protesters.count) different players in \(tally.races.count) races"))
            }
            if tally.lateDropRaces.count >= settings.lateDrops {
                found.append(FairPlayFinding(kind: .lateDrops, playerID: player, value: Double(tally.lateDropRaces.count),
                                             threshold: Double(settings.lateDrops), raceIDs: tally.lateDropRaces,
                                             detail: "gone unfinished within \(settings.lateDropSeconds) s of the close in "
                                                 + "\(tally.lateDropRaces.count) of \(tally.races.count) races"))
            }
        }
        // The same inputs in two races or more: every player who sailed them.
        var identical: [String: Set<String>] = [:]
        for seats in inputs.values where Set(seats.map(\.race)).count >= 2 {
            for (player, _) in seats { identical[player, default: []].formUnion(seats.map(\.race)) }
        }
        for (player, races) in identical.sorted(by: { $0.key < $1.key }) {
            found.append(FairPlayFinding(kind: .identicalInputs, playerID: player, value: Double(races.count), threshold: 2,
                                         raceIDs: races.sorted(), detail: "inputs identical tick for tick across \(races.count) races"))
        }
        return found
    }
}

/// The nightly scan (#155): reads the window's closed races, and raises each finding as a flag in the admin queue,
/// unless the player has a flag of its kind from within the window already (waiting or decided). Raises flags and
/// nothing else.
public final class FairPlayJob: Sendable {
    public let settings: FairPlaySettings
    let store: any ModerationStore
    let archive: any RaceArchive
    let now: @Sendable () -> Date
    private let loop = Mutex<Task<Void, Never>?>(nil)

    public init(settings: FairPlaySettings = FairPlaySettings(), store: any ModerationStore, archive: any RaceArchive,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.settings = settings
        self.store = store
        self.archive = archive
        self.now = now
    }

    /// One scan. Returns the flags it raised. A race that can't be read is left out, and logged.
    @discardableResult
    public func runOnce() async -> [StoredFlag] {
        let time = now()
        var scan = FairPlayScan(settings: settings)
        do {
            for (id, ended) in try await archive.closedRaces(endedFrom: time - settings.window, to: time) {
                do {
                    if let race = try await archive.archivedRace(id, endedAt: ended) { scan.add(race) }
                } catch {
                    Self.log("can't read race \(id): \(error)")
                }
            }
        } catch {
            Self.log("can't list the window's races: \(error)")
            return []
        }
        var raised: [StoredFlag] = []
        for finding in scan.findings() {
            do {
                let recent = try await store.flags(of: finding.playerID).contains {
                    $0.kind == finding.kind && $0.createdAt >= time - settings.window
                }
                guard !recent else { continue }
                raised.append(try await store.raise(StoredFlag(
                    kind: finding.kind, playerID: finding.playerID, value: finding.value, threshold: finding.threshold,
                    raceIDs: finding.raceIDs, detail: finding.detail, createdAt: time, dueAt: time + settings.reviewWithin)))
            } catch {
                Self.log("can't raise a \(finding.kind.rawValue) flag on \(finding.playerID): \(error)")
            }
        }
        return raised
    }

    public func start() {
        let interval = settings.interval
        loop.withLock { loop in
            guard loop == nil else { return }
            loop = Task { [self] in
                while !Task.isCancelled {
                    await runOnce()
                    try? await Task.sleep(for: interval)
                }
            }
        }
    }

    public func stop() {
        loop.withLock { loop in
            loop?.cancel()
            loop = nil
        }
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("RegattaServer: fair play: \(message)\n".utf8))
    }
}
