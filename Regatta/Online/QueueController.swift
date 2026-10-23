import Foundation
import Observation
import RegattaCore
import RegattaServices

/// What the queue needs of the app at fleet lock and after (#140): `AppModel`.
protocol FleetLockHost: AnyObject {
    /// A practice race or its briefing is in the race sequence: the chip rides over it.
    var isPracticeShowing: Bool { get }
    /// The takeover: everything else goes and the online briefing shows. False when this build can't brief the race
    /// (it names files the build doesn't have).
    func takeOver(_ handOff: HandOff, briefing: BriefingPayload) -> Bool
    /// Out of the race sequence to the bare home screen, the livery unlocked, with `notice` if given.
    func endRaceSequence(notice: AppModel.Notice?)
    func postNotice(_ notice: AppModel.Notice)
    /// The briefing gives way to the race it briefed, in the same cover (#141).
    func showRace(_ launch: OnlineLaunch)
    /// Home's Rejoin race: the cover, straight to the water.
    func rejoinRace(_ launch: OnlineLaunch)
    /// The locked fleet's briefing ends this many seconds from now: the race clock's word, once the link has it.
    func setBriefingRemaining(_ seconds: Double)
    func setLiveryLocked(_ locked: Bool)
    /// Her results in an online race she was done in, for Home's Last race.
    func keepLastRace(_ results: RaceResultViewModel)
    /// The results of a race that closed while she was away, from the service's last race.
    func keepLastRace(_ report: RaceReport, rating: RatingOutcome?)
    /// The rating the server pushed for the Last race row's race, after the cover was gone.
    func setLastRaceRating(_ outcome: RatingOutcome, raceID: RaceID)
    /// The race a hand-off seats her in, with its briefing's seat liveries (#163): kept for that race's launch and results.
    func keepHandOff(_ fleet: RaceFleet)
    /// `raceID`'s seat liveries as its briefing showed them, if this device kept them.
    func fleet(of raceID: RaceID) -> [Livery]?
}

extension AppModel.Notice {
    // TODO-COPY (#171): every notice here is placeholder wording.
    static let leftQueue = AppModel.Notice(title: "You left the queue", message: "")
    static let leftQueueInBackground = AppModel.Notice(title: "You left the queue", message: "The app went to the background.")
    static let leftQueueOnDrop = AppModel.Notice(title: "You left the queue", message: "The connection dropped.")
    static let couldNotJoin = AppModel.Notice(title: "Couldn't join", message: "Try Race online again.")
    static let couldNotStartRace = AppModel.Notice(title: "Couldn't start the race", message: "Try Race online again.")
    static let raceCancelled = AppModel.Notice(title: "The race was cancelled", message: "")
    static let updateToRaceOnline = AppModel.Notice(title: "Update to race online", message: "")
}

/// The queue from the Race online tap to the gun's briefing (#140, #16, #25): joining, the wait and its lock banner,
/// leaving, a lost connection, and at fleet lock the takeover, where the race sequence (#141) takes it from here. The
/// one reader of the queue's state stream; the bar, the chip and Home's Race online slot read its values, and it draws
/// nothing itself (no SwiftUI or UIKit).
@MainActor @Observable
final class QueueController {
    private enum Stage: Equatable {
        case idle
        case joining(deadline: Date)
        case queued(players: Int, lockAt: Date)
        case connectionLost
        /// `.fleetLocked` came; the hand-off is being fetched.
        case locking
        /// From the takeover's briefing to Home again: the race sequence's (`OnlineRaceController`).
        case inRace
        case settling(until: Date)
    }

    /// The bar and the chip; nil when neither shows.
    private(set) var bar: QueueBarState?
    private(set) var entry = RaceOnlineEntry.ready

    /// Every state the stream gives, and a refusal `join` threw: `OnlineStatus` words Race online's line and the
    /// lobby's count from it.
    @ObservationIgnored var onState: ((QueueState) -> Void)?
    /// VoiceOver's announcements: joined, lock soon, lock. Nothing else is announced.
    @ObservationIgnored var announce: (String) -> Void = { _ in }
    /// Runs the leave a backgrounded app sends, keeping the app awake until it is through (`OnlineStatus`: a
    /// background task). Here it only runs it.
    @ObservationIgnored var whileAwake: (@escaping @Sendable () async -> Void) -> Task<Void, Never> = { work in Task { await work() } }

    /// A join that hears nothing back gives up after this long.
    static let joinTimeout: TimeInterval = 8
    /// After leaving a locked fleet, Race online waits this long at most for the server's word.
    static let settleTimeout: TimeInterval = 3
    /// The lock haptic fires once per stretch in the queue, and again only if the lock moved back past this (a hold).
    static let lockSoonRearmSeconds = 20

    private var stage = Stage.idle {
        didSet {
            switch stage {
            case .idle, .inRace:
                bar = nil
                entry = .ready
            case .joining:
                bar = .joining
                entry = .queued
            case .queued(let players, let lockAt):
                bar = .waiting(players: players, lockAt: lockAt)
                entry = .queued
            case .connectionLost:
                bar = .connectionLost
                entry = .queued
            case .locking:
                bar = .locking
                entry = .queued
            case .settling:
                bar = nil
                entry = .settling
            }
        }
    }

    @ObservationIgnored private let queue: any QueueService
    @ObservationIgnored private let raceSession: any RaceSessionService
    @ObservationIgnored private let sequence: (any OnlineSequence)?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: (Duration) async -> Void
    /// How often the controller looks at its clock while something is timed; nil in tests, which call `tick()`.
    @ObservationIgnored private let tickInterval: Duration?
    @ObservationIgnored private weak var host: (any FleetLockHost)?
    @ObservationIgnored private var haptics: any Haptics = SilentHaptics()
    @ObservationIgnored private var isOnline: Bool
    /// The online session is open, where there is one (#162): her place in the queue lives on its connection.
    @ObservationIgnored private var isSessionOpen = true
    @ObservationIgnored private var lockSoonLatched = false
    /// The stream's last state: what a join that finds her already queued adopts.
    @ObservationIgnored private var lastState: QueueState?
    /// A cooldown's end, counted on the device: at it Race online is ready again, whatever the server last said.
    @ObservationIgnored private var cooldownUntil: Date?
    /// After Leave, a `.queued` the server sent before it heard is ignored until this.
    @ObservationIgnored private var leavingUntil: Date?
    /// The read of the queue's stream, while it runs.
    @ObservationIgnored private(set) var reader: Task<Void, Never>?
    @ObservationIgnored private var readerEnded = false
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// The last leave sent to the queue, best effort: the bar never waits for it.
    @ObservationIgnored private(set) var leaving: Task<Void, Never>?

    init(queue: any QueueService, raceSession: any RaceSessionService, sequence: (any OnlineSequence)? = nil,
         isOnline: Bool = true, now: @escaping () -> Date = Date.init,
         sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }, tickInterval: Duration? = .seconds(1)) {
        self.queue = queue
        self.raceSession = raceSession
        self.sequence = sequence
        self.isOnline = isOnline
        self.now = now
        self.sleep = sleep
        self.tickInterval = tickInterval
    }

    /// The app model the takeover acts on, and its haptics (gated by Settings).
    func attach(host: any FleetLockHost, haptics: any Haptics) {
        self.host = host
        self.haptics = haptics
    }

    /// Whether the chip shows: queued, over a practice race or its briefing.
    var showsChip: Bool { bar != nil && host?.isPracticeShowing == true }

    /// Reads the queue's state stream until it ends. A stream that ends is a lost connection; the next regain or
    /// join opens it again.
    func start() {
        guard reader == nil else { return }
        readerEnded = false
        reader = Task { [weak self, queue] in
            for await state in queue.stateUpdates() { await self?.receive(state) }
            self?.streamEnded()
        }
    }

    // MARK: The player

    /// Race online, past the gate; and Race again.
    func join() async {
        guard stage == .idle else { return }
        if readerEnded { start() }
        stage = .joining(deadline: now().addingTimeInterval(Self.joinTimeout))
        scheduleTick()
        do {
            try await queue.join()
        } catch QueueError.refused(let refusal) {
            guard case .joining = stage else { return }
            // The reason lands on Race online's line.
            await receive(.unavailable(refusal))
        } catch QueueError.alreadyQueued {
            guard case .joining = stage, let lastState else { return }
            await receive(lastState)
        } catch {
            guard case .joining = stage else { return }
            stage = .idle
            host?.postNotice(.couldNotJoin)
        }
    }

    /// The bar's and the chip's Leave: free, at once, whatever the server answers.
    func leave() {
        guard isWaiting else { return }
        giveUpPlace()
        leaving = Task { [queue] in try? await queue.leave() }
    }

    /// Online results' Race again (#24): home, with the queue running.
    func raceAgain() async {
        host?.endRaceSequence(notice: nil)
        await join()
    }

    // MARK: The race sequence

    /// Home's Rejoin race, or a relaunch in the briefing, took her back into a race: the queue stays out of it, as
    /// from a takeover. False when she is waiting for another by now.
    @discardableResult func sequenceBegan() -> Bool {
        guard stage == .idle else { return false }
        stage = .inRace
        return true
    }

    /// The race sequence is over and Home is up. Having left, Race online stays off until the server says where she
    /// stands (idle, or the cooldown); otherwise the queue is free at once.
    func sequenceEnded(_ outcome: SequenceOutcome) {
        guard stage == .inRace else { return }
        switch outcome {
        case .left:
            stage = .settling(until: now().addingTimeInterval(Self.settleTimeout))
            scheduleTick()
        case .over, .cancelled:
            stage = .idle
        }
    }

    // MARK: The world

    /// The scene went to the background, or came back. Queued, the background is a leave (#25). After fleet lock it is
    /// a drop: nothing is sent, her seat is kept, and she is back in the race if she returns before the gun (#147).
    func sceneChanged(isBackground: Bool) {
        guard isBackground, isWaiting else { return }
        giveUpPlace()
        // The system may suspend the app any moment now: the leave gets the time it needs.
        leaving = whileAwake { [queue] in try? await queue.leave() }
        host?.postNotice(.leftQueueInBackground)
    }

    func connectionChanged(isOnline: Bool) {
        let was = isReachable
        self.isOnline = isOnline
        reachabilityChanged(from: was)
    }

    /// The online session opened, or is open no longer (#162). Queued, a session that goes is a lost connection, as the
    /// device's path going is: the server dropped her place with it.
    func sessionChanged(isOpen: Bool) {
        let was = isReachable
        isSessionOpen = isOpen
        reachabilityChanged(from: was)
    }

    private var isReachable: Bool { isOnline && isSessionOpen }

    private func reachabilityChanged(from was: Bool) {
        let isReachable = isReachable
        guard isReachable != was else { return }
        if isReachable {
            if stage == .connectionLost {
                stage = .idle
                host?.postNotice(.leftQueueOnDrop)
            }
            if readerEnded { start() }
        } else if isWaiting {
            // The server drops her place with the connection: no silent re-queue.
            stage = .connectionLost
        }
    }

    /// The queue's state, from its stream.
    func receive(_ state: QueueState) async {
        lastState = state
        onState?(state)
        if state != .fleetLocked { sequence?.fleetUnlocked() }
        let now = now()
        cooldownUntil = nil
        switch state {
        case .idle:
            leavingUntil = nil
            switch stage {
            case .queued, .settling: stage = .idle
            // Joining, the join's own answer or its timeout decides.
            case .idle, .joining, .connectionLost, .locking, .inRace: break
            }
        case .unavailable(let refusal):
            leavingUntil = nil
            if case .cooldown(let seconds) = refusal { cooldownUntil = now.addingTimeInterval(TimeInterval(max(0, seconds))) }
            switch stage {
            case .joining, .settling: stage = .idle
            case .queued:
                stage = .idle
                host?.postNotice(.leftQueue)
            case .idle, .connectionLost, .locking, .inRace: break
            }
        case .queued(let status):
            switch stage {
            case .idle:
                if let leavingUntil, now < leavingUntil { break }
                lockSoonLatched = false
                wait(status, from: now)
            case .joining:
                lockSoonLatched = false
                // TODO-COPY (#171)
                announce("Joined the queue")
                wait(status, from: now)
            case .queued:
                wait(status, from: now)
            case .connectionLost, .locking, .inRace, .settling: break
            }
        case .fleetLocked:
            // Only a fleet she was waiting for takes the app over. Waiting for nothing, it may be a race she dropped
            // out of (#141), or stale after a leave: the sequence asks the service which.
            guard isWaiting else {
                if stage == .idle { sequence?.fleetLockedWhileIdle() }
                break
            }
            stage = .locking
            await takeOver()
        }
        scheduleTick()
    }

    /// The controller's clock moved: a join that timed out, the lock banner's haptic, a cooldown's end, the settle
    /// wait, the reconnecting line. Runs each second while any of them is pending.
    func tick() {
        let now = now()
        switch stage {
        case .joining(let deadline) where now >= deadline:
            stage = .idle
            host?.postNotice(.couldNotJoin)
        case .queued: noteLockSoon(at: now)
        case .settling(let until) where now >= until: stage = .idle
        default: break
        }
        if let cooldownUntil, now >= cooldownUntil {
            // Ready at zero, without waiting for the server's `.idle`, and with no notice.
            self.cooldownUntil = nil
            onState?(.idle)
        }
    }

    // MARK: Inside

    /// Joining or queued: there is a place to give up, or to lose.
    private var isWaiting: Bool {
        switch stage {
        case .joining, .queued: true
        default: false
        }
    }

    private func giveUpPlace() {
        stage = .idle
        leavingUntil = now().addingTimeInterval(Self.settleTimeout)
    }

    private func wait(_ status: QueuedStatus, from now: Date) {
        // A hold moved the lock back: the banner and its haptic come again.
        if status.secondsToLock > Self.lockSoonRearmSeconds { lockSoonLatched = false }
        stage = .queued(players: status.queuedPlayers, lockAt: now.addingTimeInterval(TimeInterval(status.secondsToLock)))
        noteLockSoon(at: now)
    }

    private func noteLockSoon(at now: Date) {
        guard !lockSoonLatched, let bar, bar.kind(at: now) == .lockSoon, let seconds = bar.secondsToLock(at: now) else { return }
        lockSoonLatched = true
        haptics.impact(intensity: 0.4)
        // TODO-COPY (#171)
        announce("Race in \(seconds) seconds")
    }

    /// Fleet lock: fetches her seat and its briefing (one retry), then hands the app over to it.
    private func takeOver() async {
        var handOff = try? await raceSession.handOff()
        if handOff?.briefing == nil { handOff = try? await raceSession.handOff() }
        // She may have gone meanwhile.
        guard stage == .locking else { return }
        guard let handOff, let briefing = handOff.briefing, let host else {
            stage = .idle
            host?.postNotice(.couldNotStartRace)
            return
        }
        guard host.takeOver(handOff, briefing: briefing) else {
            stage = .idle
            // Nothing is sent: the server counts the seat she never took as a drop at the gun.
            host.postNotice(.updateToRaceOnline)
            return
        }
        stage = .inRace
        haptics.impact(intensity: 1)
        // TODO-COPY (#171)
        announce("Fleet set, briefing")
        sequence?.begin(handOff, briefing: briefing, host: host)
    }

    private func streamEnded() {
        reader = nil
        readerEnded = true
        guard isWaiting else { return }
        if isReachable {
            // Only the stream went: her place went with it. The next join opens it again.
            stage = .idle
            host?.postNotice(.leftQueueOnDrop)
        } else {
            stage = .connectionLost
        }
    }

    private var needsTicks: Bool {
        if cooldownUntil != nil { return true }
        switch stage {
        case .joining, .queued, .settling: return true
        default: return false
        }
    }

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
