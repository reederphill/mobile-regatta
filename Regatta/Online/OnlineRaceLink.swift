import Foundation
import RegattaClient
import RegattaProtocol
import RegattaServices

/// The race link of the online race sequence (#141), over the race client: an `OnlineLaunch` that joins with the
/// hand-off's token until it is in, and the driver's reconnects, which reuse that token before the gun and wait for a
/// fresh one (`RaceSessionService.rejoin()`, the controller's) after it.
final class OnlineRaceLink: RaceLinking {
    /// What the launch's and the driver's closures share with the link.
    private final class State {
        var token: RaceToken
        var fresh: RaceToken?
        var wantsToken = false
        var isClosed = false
        var last: (any RaceConnection)?
        let connector: RaceConnector

        init(token: RaceToken, connector: @escaping RaceConnector) {
            self.token = token
            self.connector = connector
        }

        func open() -> any RaceConnection {
            guard !isClosed else {
                let dead = UnansweredRaceConnection()
                dead.close()
                return dead
            }
            let connection = connector(token)
            last = connection
            return connection
        }

        /// Whether the driver may rejoin now, at race tick `tick`.
        func allowsRejoin(tick: Int?) -> Bool {
            if isClosed { return false }
            // Before the gun the hand-off's token still seats her.
            guard let tick, tick >= 0 else { return true }
            guard let fresh else {
                wantsToken = true
                return false
            }
            token = fresh
            self.fresh = nil
            wantsToken = false
            return true
        }
    }

    private let state: State
    private let onlineLaunch: OnlineLaunch
    private let results: OnlineResults?
    private var task: Task<Void, Never>?

    /// `build` makes the launch from the link's connection and token sources (`AppModel.onlineRaceLink`).
    init(handOff: HandOff, connector: @escaping RaceConnector, results: OnlineResults?,
         build: (_ connect: @escaping () -> any RaceConnection, _ token: @escaping () -> [UInt8]) -> OnlineLaunch) {
        let state = State(token: handOff.token, connector: connector)
        self.state = state
        self.results = results
        onlineLaunch = build({ state.open() }, { state.token.bytes })
        onlineLaunch.onDriver = { driver in
            driver.canRejoin = { [weak driver] in state.allowsRejoin(tick: driver?.serverTick) }
            driver.rejoinToken = { state.token.bytes }
        }
    }

    var launch: OnlineLaunch? { onlineLaunch }

    private var driver: OnlineDriver? { onlineLaunch.session?.driver as? OnlineDriver }

    var status: RaceLinkStatus {
        switch onlineLaunch.phase {
        case .connecting, .failed: return .joining
        case .updateRequired: return .updateRequired
        case .racing:
            switch driver?.connection {
            case .reconnecting: return .reconnecting
            case .updateRequired: return .updateRequired
            default: return .up
            }
        }
    }

    var tick: Int? { driver?.serverTick }

    var ending: RaceClient.Ending? {
        if results?.isCancelled == true { return .cancelled(.unspecified) }
        return driver?.client.ending
    }

    var isPlayerDone: Bool { onlineLaunch.session?.playerDone ?? false }

    var wantsToken: Bool { state.wantsToken }

    func provide(_ token: RaceToken) {
        state.fresh = token
        state.wantsToken = false
    }

    func start() {
        guard task == nil else { return }
        task = Task { [onlineLaunch] in await onlineLaunch.start() }
    }

    func pump(isShown: Bool) {
        // Under the briefing nothing draws the race: the clock still syncs and the snapshots are read. What the
        // briefing's seconds would have noticed is dropped, not shown in a burst as the water appears.
        guard !isShown, let driver else { return }
        driver.tick(0)
        _ = driver.drainEvents()
    }

    func leave() async {
        let joinBy = ContinuousClock.now + .seconds(5)
        while driver == nil, status == .joining, ContinuousClock.now < joinBy {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if let client = driver?.client, client.transport.isConnected {
            client.leave()
            // The server closes the connection once the seat is released: a join before that is `alreadyQueued`.
            let closedBy = ContinuousClock.now + .seconds(2)
            while client.transport.isConnected, ContinuousClock.now < closedBy {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        close()
    }

    func drop() {
        state.last?.close()
    }

    func close() {
        state.isClosed = true
        onlineLaunch.stop()
        state.last?.close()
    }

    func resultsToKeep() -> RaceResultViewModel? { onlineLaunch.session?.resultsToKeep() }
}
