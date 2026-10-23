import Foundation
import Observation
import RegattaClient
import RegattaCore
import RegattaProtocol
import RegattaServices

/// One end of a race connection the app can close (#141): the WebSocket, or the Debug fake host's.
nonisolated protocol RaceConnection: RaceTransport {
    func close()
}

extension WebSocketTransport: RaceConnection {}

/// Opens a connection to the race a token seats her in: `/race` in the app (#162 gives it its address), the fake
/// host on the fakes.
typealias RaceConnector = (RaceToken) -> any RaceConnection

/// A connection nobody answers: what a hand-off gets where there is no race server to reach (the scripted fakes
/// without a fake race; #162 brings the real address).
nonisolated final class UnansweredRaceConnection: RaceConnection {
    private(set) var isConnected = true
    func send(_ frame: [UInt8]) {}
    func receive() -> [[UInt8]] { [] }
    func close() { isConnected = false }
}

/// How the online race sequence ended, for the queue.
enum SequenceOutcome: Equatable {
    /// She gave her seat up before she was done: Race online waits for the server's word (the cooldown, or idle).
    case left
    /// She was done, or the race closed: the queue is free.
    case over
    case cancelled
}

/// What the queue hands over at fleet lock, and tells the sequence of the stream meanwhile (#141).
protocol OnlineSequence: AnyObject {
    /// The takeover's briefing is up: the race link starts under it.
    func begin(_ handOff: HandOff, briefing: BriefingPayload, host: any FleetLockHost)
    /// The stream says `.fleetLocked` and she is waiting for nothing: a race she dropped out of may still run, or the
    /// app was killed in its briefing.
    func fleetLockedWhileIdle()
    /// The stream left `.fleetLocked`: nothing to rejoin any more.
    func fleetUnlocked()
}

enum RaceLinkStatus: Equatable {
    /// No `RaceStart` yet.
    case joining
    case up
    /// It was up and dropped: rejoining, then waiting for the `Resync`.
    case reconnecting
    case updateRequired
}

/// The race link as the sequence's state machine reads it (#141): `OnlineRaceLink` over the race client in the app,
/// a scripted one on a manual clock in the tests.
protocol RaceLinking: AnyObject {
    var status: RaceLinkStatus { get }
    /// The server's race clock in ticks, once the link's clock has synchronised.
    var tick: Int? { get }
    var ending: RaceClient.Ending? { get }
    /// Her own finish or DSQ, or the close.
    var isPlayerDone: Bool { get }
    /// After the gun a reconnect needs a fresh token (`RaceSessionService.rejoin()`): true while it waits for one.
    var wantsToken: Bool { get }
    /// The race the cover shows; nil for a scripted link.
    var launch: OnlineLaunch? { get }
    func start()
    /// Runs the link while the race isn't on screen (the briefing): the scene runs it from then on.
    func pump(isShown: Bool)
    func provide(_ token: RaceToken)
    /// `LeaveRace`, as soon as there is a connection to send it on (5 s at most), then waits for the server to close
    /// it (2 s at most) and closes the link.
    func leave() async
    /// Closes the connection and sends nothing: the background.
    func drop()
    func close()
    /// Her results as she leaves, if she was done.
    func resultsToKeep() -> RaceResultViewModel?
}

extension AppModel.Notice {
    // TODO-COPY (#171)
    static let raceEnded = AppModel.Notice(title: "The race has ended", message: "Back to Race online.")
}

/// The online race from the briefing's end to Home again (#141, #25): the race link under the briefing, the briefing's
/// end on the race clock, the sequence and the race, Leave and its confirm, drops and reconnects, the ends (close,
/// cancel, closed while away), and Home's Rejoin race. Pure values out, no SwiftUI or UIKit; the views are dumb.
@MainActor @Observable
final class OnlineRaceController: OnlineSequence {
    enum Phase: Equatable {
        case idle
        /// #140's briefing; the link joins under it.
        case briefing
        /// The briefing ran out before the link was up: the water's colour and "Joining".
        case joining
        /// Race tick -60 s to the gun.
        case sequence
        case racing
        /// Her own finish or DSQ, or the close: the results.
        case done
    }

    /// Home's Rejoin race: the race clock when the service read it, counted on locally.
    struct RejoinEntry: Equatable {
        var tick: Int
        var readAt: Date
        var timescale = 1.0

        /// Whole seconds into the race at `date`.
        func seconds(at date: Date) -> Int {
            max(0, Int((Double(tick) / Double(Race.tickRate) + date.timeIntervalSince(readAt) * timescale).rounded(.down)))
        }

        /// "12:41".
        func clock(at date: Date) -> String { formatClock(Double(seconds(at: date))) }

        // TODO-COPY (#171)
        func spoken(at date: Date) -> String {
            let seconds = seconds(at: date)
            return "Rejoin race, \(seconds / 60) minutes \(seconds % 60) seconds into the race"
        }
    }

    private(set) var phase = Phase.idle
    /// "Leave the race?" is up, over the briefing or the race; everything runs on behind it.
    private(set) var isConfirmingLeave = false
    /// The connection has been gone 2 s: the line under the briefing's countdown, or in the race's notice slot.
    private(set) var isReconnecting = false
    /// "Race continues" is up.
    private(set) var isMenuOpen = false
    private(set) var rejoinEntry: RejoinEntry?
    /// The race clock is before the gun, as far as the link knows: the leave confirm's wording.
    private(set) var isBeforeGun = true

    static let reconnectingAfter: TimeInterval = 2
    /// The race link failing this long while the device is online: ask the service whether the race still runs.
    static let serverGoneAfter: TimeInterval = 60
    /// How long the race just left is followed to its close for Home's Last race (#163): the rating's wait.
    static let ratingWait: TimeInterval = 600
    /// A token ask the service didn't answer is tried again after this long, not every tick (#162).
    static let tokenRetryAfter: TimeInterval = 2

    @ObservationIgnored weak var queue: QueueController?
    @ObservationIgnored private weak var host: (any FleetLockHost)?
    @ObservationIgnored private let raceSession: any RaceSessionService
    @ObservationIgnored var makeLink: (HandOff) -> any RaceLinking
    /// Whether the race session may be asked now (#162, `OnlineStatus.mayAskService`): never for a player who isn't
    /// through the gate, whose connection the server would close for it.
    @ObservationIgnored var mayAskService: () -> Bool = { true }
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: (Duration) async -> Void
    @ObservationIgnored private let tickInterval: Duration?
    @ObservationIgnored private let timescale: Double
    @ObservationIgnored private var isOnline: Bool
    @ObservationIgnored private(set) var link: (any RaceLinking)?
    @ObservationIgnored private var handOff: HandOff?
    /// The race tick the briefing ends at: the gun less the rules' start sequence.
    @ObservationIgnored private var sequenceStartTick = 0
    @ObservationIgnored private var briefingAligned = false
    @ObservationIgnored private var lostAt: Date?
    @ObservationIgnored private var askedWhetherGone = false
    @ObservationIgnored private var fetchingToken = false
    @ObservationIgnored private var tokenRetryAt: Date?
    @ObservationIgnored private var askingRejoin = false
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var follower: Task<Void, Never>?
    @ObservationIgnored private var followUntil: Date?
    /// The last `LeaveRace` on its way: Race again waits for it before it joins the queue.
    @ObservationIgnored private(set) var leaving: Task<Void, Never>?

    init(raceSession: any RaceSessionService, makeLink: @escaping (HandOff) -> any RaceLinking, isOnline: Bool = true,
         timescale: Double = 1, now: @escaping () -> Date = Date.init,
         sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) },
         tickInterval: Duration? = .milliseconds(100)) {
        self.raceSession = raceSession
        self.makeLink = makeLink
        self.isOnline = isOnline
        self.timescale = timescale
        self.now = now
        self.sleep = sleep
        self.tickInterval = tickInterval
    }

    /// The app model the sequence acts on: needed before a rejoin, which no fleet lock precedes.
    func attach(host: any FleetLockHost) { self.host = host }

    // MARK: The sequence

    func begin(_ handOff: HandOff, briefing: BriefingPayload, host: any FleetLockHost) {
        self.host = host
        clearOffer()
        // The briefing's liveries are the race's: nothing after it carries them (#163).
        host.keepHandOff(RaceFleet(raceID: handOff.raceID, briefing: briefing))
        sequenceStartTick = -(briefing.gunInSeconds - briefing.briefingSeconds) * Race.tickRate
        phase = .briefing
        start(handOff)
    }

    private func start(_ handOff: HandOff) {
        self.handOff = handOff
        briefingAligned = false
        askedWhetherGone = false
        isBeforeGun = phase == .briefing
        lostAt = isOnline ? nil : now()
        let link = makeLink(handOff)
        self.link = link
        link.start()
        scheduleTick()
    }

    /// The briefing's own countdown ran out (it counts from receipt until the link is up): the water, joined or not.
    func briefingEnded() {
        guard phase == .briefing else { return }
        enterRace()
    }

    private func enterRace() {
        guard let link else { return }
        guard link.tick != nil, link.launch != nil || link.status != .joining else {
            phase = .joining
            if let launch = link.launch { host?.showRace(launch) }
            return
        }
        if let launch = link.launch { host?.showRace(launch) }
        phase = (link.tick ?? 0) < 0 ? .sequence : .racing
    }

    /// The controller's clock moved. Runs every `tickInterval` while a race runs or one is followed; tests call it.
    func tick() {
        let now = now()
        if let followUntil, now >= followUntil { stopFollowing() }
        guard phase != .idle, let link else { return }
        link.pump(isShown: phase != .briefing)
        if link.status == .updateRequired { return end(.left, notice: .updateToRaceOnline) }
        switch link.ending {
        case .cancelled: return end(.cancelled, notice: .raceCancelled)
        case .closed: finishRacing()
        case nil: break
        }
        let tick = link.tick
        if let tick { isBeforeGun = tick < 0 }
        switch phase {
        case .briefing:
            guard let tick else { break }
            if tick >= sequenceStartTick {
                enterRace()
            } else if !briefingAligned {
                // From here the briefing ends on the race clock, not 15 s from its receipt.
                briefingAligned = true
                host?.setBriefingRemaining(Double(sequenceStartTick - tick) / Double(Race.tickRate))
            }
        case .joining:
            if tick != nil, link.status != .joining { enterRace() }
        case .sequence:
            if let tick, tick >= 0 { phase = .racing }
        case .racing, .done, .idle: break
        }
        if link.isPlayerDone { finishRacing() }
        watchConnection(link, at: now)
    }

    private func finishRacing() {
        guard phase != .done else { return }
        if phase == .briefing || phase == .joining, let launch = link?.launch { host?.showRace(launch) }
        phase = .done
        isMenuOpen = false
        isConfirmingLeave = false
    }

    private func watchConnection(_ link: any RaceLinking, at now: Date) {
        let isDown = !isOnline || link.status == .reconnecting || (link.status == .joining && phase != .briefing)
        guard isDown, link.ending == nil else {
            lostAt = nil
            askedWhetherGone = false
            isReconnecting = false
            return
        }
        let since = lostAt ?? now
        lostAt = since
        if now >= since.addingTimeInterval(Self.reconnectingAfter) { isReconnecting = true }
        if link.wantsToken, !fetchingToken, now >= tokenRetryAt ?? .distantPast {
            fetchingToken = true
            Task { await fetchToken() }
        }
        if isOnline, !askedWhetherGone, now >= since.addingTimeInterval(Self.serverGoneAfter), mayAskService() {
            askedWhetherGone = true
            Task { await askWhetherGone() }
        }
    }

    /// After the gun every reconnect asks the service first: a fresh token, or the word that the race is over.
    private func fetchToken() async {
        defer { fetchingToken = false }
        guard mayAskService() else { return tokenRetryAt = now().addingTimeInterval(Self.tokenRetryAfter) }
        do {
            let offer = try await raceSession.rejoin()
            tokenRetryAt = nil
            link?.provide(offer.handOff.token)
        } catch RaceSessionError.noRace {
            tokenRetryAt = nil
            await raceIsOver()
        } catch {
            // No answer (the session is down, or the call timed out): not "no race". Again in a moment.
            tokenRetryAt = now().addingTimeInterval(Self.tokenRetryAfter)
        }
    }

    private func askWhetherGone() async {
        do {
            let offer = try await raceSession.rejoin()
            link?.provide(offer.handOff.token)
        } catch RaceSessionError.noRace {
            // Before the gun there is nothing to rejoin yet: the hand-off says whether the race stands.
            if isBeforeGun {
                do {
                    _ = try await raceSession.handOff()
                    return
                } catch RaceSessionError.noRace {
                } catch {
                    return askedWhetherGone = false
                }
            }
            await raceIsOver()
        } catch {
            // No answer: asked again while the link stays down.
            askedWhetherGone = false
        }
    }

    /// The service knows no race of hers any more: it closed while she was away (Home, with the Last race row) or was
    /// cancelled (Home, with the notice).
    private func raceIsOver() async {
        guard phase != .idle, let raceID = handOff?.raceID else { return }
        let last: LastRace?
        do {
            last = try await raceSession.lastRace()
        } catch {
            // No answer says nothing of the race: the next ask finds out.
            tokenRetryAt = now().addingTimeInterval(Self.tokenRetryAfter)
            askedWhetherGone = false
            return
        }
        guard phase != .idle else { return }
        if let last, last.report.raceID == raceID {
            stopFollowing()
            host?.keepLastRace(last.report, rating: last.rating?.outcome)
            host?.onlineRaceClosed()
            end(.over, keepsResults: false, follows: last.rating == nil)
        } else {
            end(.cancelled, notice: .raceCancelled)
        }
    }

    // MARK: The player

    func openMenu() {
        guard phase == .sequence || phase == .racing else { return }
        isMenuOpen = true
    }

    func closeMenu() { isMenuOpen = false }

    func askToLeave() {
        guard phase != .idle, phase != .done else { return }
        isConfirmingLeave = true
    }

    func stay() { isConfirmingLeave = false }

    /// "Leave the race?", confirmed (owner 2026-10-12: final, before and after the gun): `LeaveRace`, and Home. Before
    /// the gun a bot takes the seat, and the race is no longer hers. After it she is scored RET, and the race is her
    /// last once it closes (#163, G1): nothing is kept now, and the follower keeps the closed race.
    func leaveRace() {
        guard phase != .idle else { return }
        end(.left, sendsLeave: true, keepsResults: isBeforeGun, follows: !isBeforeGun)
    }

    /// The results' Home: done, she gives the seat up for good, so the queue is free.
    func home() {
        guard phase != .idle else { return }
        end(.over, sendsLeave: link?.ending == nil)
    }

    /// The results' Race again: Home, and into the queue once the server has let the seat go.
    func raceAgain() async {
        home()
        await leaving?.value
        await queue?.join()
    }

    /// `follows`: the race was hers past the gun and she hasn't seen it close; the follower keeps it once it does.
    /// Results she was done in follow too while they aren't final or their rating is pending (Home or Race again
    /// before the close).
    private func end(_ outcome: SequenceOutcome, notice: AppModel.Notice? = nil, sendsLeave: Bool = false,
                     keepsResults: Bool = true, follows: Bool = false) {
        guard phase != .idle else { return }
        var follows = follows
        if keepsResults, let kept = link?.resultsToKeep(), kept.keepsAsLastRace, outcome != .cancelled {
            // A newer race is Home's: the one before it is no longer followed.
            stopFollowing()
            host?.keepLastRace(kept)
            // Rows still sailing, or the rating not in: Home or Race again before the close.
            if !kept.isFinal || kept.online?.rating == .pending { follows = true }
        }
        if follows, let raceID = handOff?.raceID { follow(raceID) }
        if let link {
            if sendsLeave {
                leaving = Task { await link.leave() }
            } else {
                link.close()
            }
        }
        link = nil
        phase = .idle
        isConfirmingLeave = false
        isReconnecting = false
        isMenuOpen = false
        lostAt = nil
        host?.endRaceSequence(notice: notice)
        queue?.sequenceEnded(outcome)
    }

    // MARK: The world

    /// The background is a drop, before and after the gun (owner 2026-10-11): nothing is sent, and on return the link
    /// reconnects at once with the cover where it was. With no race on, the return asks for one to rejoin.
    func sceneChanged(isBackground: Bool) {
        guard phase != .idle else {
            if !isBackground { ask(orTakeOver: false) }
            return
        }
        if isBackground { link?.drop() } else { tick() }
    }

    func connectionChanged(isOnline: Bool) {
        self.isOnline = isOnline
        if phase != .idle { tick() }
    }

    // MARK: Rejoin

    func fleetLockedWhileIdle() { ask(orTakeOver: true) }

    /// The online session opened for a player through the gate (#162): a race she dropped out of may still run, which a
    /// cold launch learns here, before any scene change. Then her last race, from the service (#163).
    func sessionOpened() { ask(orTakeOver: true, thenLastRace: true) }

    private func ask(orTakeOver: Bool, thenLastRace: Bool = false) {
        guard phase == .idle, !askingRejoin, mayAskService() else { return }
        askingRejoin = true
        Task {
            await askForRejoin(orTakeOver: orTakeOver)
            askingRejoin = false
            if thenLastRace { await adoptLastRace() }
        }
    }

    /// Her last race as the service has it, once, as a session opens (#163, T4): Home's Last race takes it by
    /// `FleetLockHost.adoptsLastRace` (a relaunch, a reinstall or a second device has none; a frozen one is refreshed;
    /// the app was killed in the race it was handed). A race whose rating isn't in is followed to it.
    func adoptLastRace() async {
        guard phase == .idle, mayAskService(), let last = try? await raceSession.lastRace(), phase == .idle, let host, host.adoptsLastRace(last.report.raceID) else { return }
        host.keepLastRace(last.report, rating: last.rating?.outcome)
        if last.rating == nil { follow(last.report.raceID) }
    }

    /// Asks the service once for a race in progress to take back: an offer puts Rejoin race on Home. `orTakeOver`
    /// (the stream said `.fleetLocked`): with nothing to rejoin, a seat in a fleet that hasn't started yet takes the
    /// app over again, as at fleet lock (the app was killed in the briefing).
    func askForRejoin(orTakeOver: Bool = false) async {
        guard phase == .idle else { return }
        do {
            let offer = try await raceSession.rejoin()
            guard phase == .idle else { return }
            handOff = offer.handOff
            rejoinEntry = RejoinEntry(tick: offer.clock.tick, readAt: now(), timescale: timescale)
            host?.setLiveryLocked(true)
        } catch RaceSessionError.noRace {
            // Nothing to rejoin: before the gun, or stale (a `.fleetLocked` after a leave).
            clearOffer()
            if orTakeOver { await takeOverAgain() }
        } catch {
            // No answer (#162): what Home shows stays as it was.
        }
    }

    /// The briefing again, with the time the race clock leaves it, or straight to the sequence: the link says which
    /// once it is up. A seat she left has no hand-off, so a stale `.fleetLocked` ends here.
    private func takeOverAgain() async {
        guard let handOff = try? await raceSession.handOff(), let briefing = handOff.briefing, phase == .idle, let host,
              queue?.sequenceBegan() != false, host.takeOver(handOff, briefing: briefing) else { return }
        begin(handOff, briefing: briefing, host: host)
    }

    func fleetUnlocked() {
        guard rejoinEntry != nil else { return }
        let raceID = handOff?.raceID
        clearOffer()
        // The race closed while she was away: its results are Home's Last race, with no notice.
        Task {
            guard let raceID, mayAskService(), let last = try? await raceSession.lastRace(), last.report.raceID == raceID else { return }
            stopFollowing()
            host?.keepLastRace(last.report, rating: last.rating?.outcome)
            host?.onlineRaceClosed()
            if last.rating == nil { follow(raceID) }
        }
    }

    /// Home's Rejoin race: straight to the water, on a fresh token, with no briefing.
    func rejoin() async {
        guard phase == .idle, rejoinEntry != nil, let host, mayAskService() else { return }
        do {
            let offer = try await raceSession.rejoin()
            guard phase == .idle else { return }
            await keepBriefingFleet(of: offer.handOff.raceID)
            guard phase == .idle else { return }
            rejoinEntry = nil
            phase = .racing
            start(offer.handOff)
            queue?.sequenceBegan()
            if let launch = link?.launch { host.rejoinRace(launch) }
        } catch RaceSessionError.noRace {
            clearOffer()
            host.postNotice(.raceEnded)
        } catch {
            // No answer (#162): the row stays for another tap.
        }
    }

    /// A rejoin's hand-off has no briefing (#163): with no fleet kept for `raceID` (a cold launch on another device,
    /// or after a reinstall), the service's hand-off, which it keeps for a dropped player until the close, has it. With
    /// neither, the race wears the seeded fleet.
    private func keepBriefingFleet(of raceID: RaceID) async {
        guard host?.fleet(of: raceID) == nil, let handOff = try? await raceSession.handOff(), handOff.raceID == raceID,
              let briefing = handOff.briefing else { return }
        host?.keepHandOff(RaceFleet(raceID: raceID, briefing: briefing))
    }

    private func clearOffer() {
        guard rejoinEntry != nil else { return }
        rejoinEntry = nil
        host?.setLiveryLocked(false)
    }

    // MARK: Inside

    /// The follower (#163, T3): the race just left, followed to its close after the cover is gone, for `ratingWait`.
    /// The close pushes every player whose last race it becomes a rating change (`.rated` or `.unrated`, a post-gun
    /// leaver's too), so the push is the close's signal; then the service's last race replaces Home's Last race with
    /// the closed rows, her RET row included (G1), and the rating. Without that read the pushed rating is kept, and the
    /// next session's open reads the race again (`adoptLastRace`). Not for a race she left before the gun.
    private func follow(_ raceID: RaceID) {
        stopFollowing()
        followUntil = now().addingTimeInterval(Self.ratingWait)
        follower = Task { [weak self, raceSession] in
            for await change in raceSession.ratingChanges() where change.raceID == raceID {
                await self?.closed(raceID, change: change)
                break
            }
            // A follower given up, or replaced by the next, leaves what follows it alone.
            guard !Task.isCancelled else { return }
            self?.follower = nil
            self?.followUntil = nil
        }
        scheduleTick()
    }

    private func closed(_ raceID: RaceID, change: RatingChange) async {
        guard mayAskService(), let last = try? await raceSession.lastRace(), last.report.raceID == raceID else {
            host?.setLastRaceRating(change.outcome, raceID: raceID)
            return
        }
        host?.keepLastRace(last.report, rating: last.rating?.outcome ?? change.outcome)
        host?.onlineRaceClosed()
    }

    private func stopFollowing() {
        follower?.cancel()
        follower = nil
        followUntil = nil
    }

    /// The race left is followed to its close (#163).
    var isFollowing: Bool { follower != nil }

    /// The controller's clock runs: a race, or a race followed to its close.
    var needsTicks: Bool { phase != .idle || followUntil != nil }

    private func scheduleTick() {
        guard let tickInterval, ticker == nil, needsTicks else { return }
        ticker = Task { [weak self, sleep] in
            while let self, self.needsTicks, !Task.isCancelled {
                await sleep(tickInterval)
                self.tick()
            }
            self?.ticker = nil
        }
    }
}
