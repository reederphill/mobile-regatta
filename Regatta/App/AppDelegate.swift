import os
import RegattaCore
import RegattaServiceClient
import RegattaServices
import UIKit

/// The app's entry point. The UI lives in one window scene, `SceneDelegate`, declared in Info.plist's scene
/// manifest: apps built with the iOS 27 SDK must use the scene life cycle.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// The services every scene runs on. `-fakeServices <scenario>` plays a scenario's scripted fakes (#242);
    /// otherwise the device's connectivity and Game Center with the terms kept on the device (#138), the rest signed
    /// out until the real services arrive. Tests and UI tests never touch Game Center.
    ///
    /// With a service endpoint (`OnlineEndpoint`) and a device identity (Game Center, or Debug's `-devIdentity`), the
    /// identity, the terms, the queue, the race session, the profile, usage analytics and Delete my online data are
    /// the online session's (#161, #162, #166); the rest stay on their fakes until their tickets. With no endpoint
    /// nothing changes.
    let services: ServiceSet
    /// The online session and the device identity under it, when there is an endpoint.
    let online: OnlineStatus.Session?
    /// Opens a hand-off's race connection (#141): `/race` on the services' host with a session (#162), the Debug fake
    /// race host on the fakes; with neither (no endpoint) nothing answers.
    let raceConnector: RaceConnector
    /// The profile's Game Center photo and leaderboard (#139): GameKit's where the identity is Game Center's, else
    /// no photo and a leaderboard that only counts its taps.
    let playerPhotos: any PlayerPhotoSource
    let leaderboard: any LeaderboardPresenter
    /// The leaderboard's top, the hidden lobby panel's (#142): GameKit's beside Game Center, a fixed five otherwise.
    let leaderboardTop: any LeaderboardTopSource

    override init() {
        var (services, online, connector) = AppDelegate.makeServices(launchOptions: .current)
        #if DEBUG
        if let director = FakeRaceDirector.make(launchOptions: .current, services: services) {
            services.raceSession = FakeRaceSession(director)
            services.queue = DirectedQueue(services.queue, director: director)
            connector = { [director] token in director.connect(token) }
        }
        #endif
        (self.services, self.online, raceConnector) = (services, online, connector)
        if AppDelegate.usesGameCenter(.current) {
            (playerPhotos, leaderboard, leaderboardTop) = (GameKitPlayerPhoto(), GameKitLeaderboardPresenter(), GameKitLeaderboardTop())
        } else {
            (playerPhotos, leaderboard, leaderboardTop) = (NoPlayerPhoto(), RecordingLeaderboardPresenter(), FixedLeaderboardTop())
        }
        super.init()
    }
    /// Usage analytics (#128), one for the app over its one set of `analytics.` keys: every scene logs to it. Sent as
    /// the session comes through the terms and on going to the background, never during a race (`OnlineStatus`, #166);
    /// at launch too, which sends nothing until a session is open (the fakes take it).
    private(set) lazy var analytics = Analytics.app(transport: services.analytics)
    private var metricKit: MetricKitForwarder?

    private static func makeServices(launchOptions: LaunchOptions) -> (ServiceSet, OnlineStatus.Session?, RaceConnector) {
        // The fakes' online results scenarios fill in live, a sleep apart (the services package keeps no clock).
        var services = launchOptions.fakeServices.map { ServiceSet.fake($0, wait: { try? await Task.sleep(for: $0) },
                                                                                  clock: { Int(Date().timeIntervalSince1970) }) }
            ?? ServiceSet.unconnected(connectivity: PathConnectivityService())
        // A scripted queue plays at a pace a person can watch: a state a second, at `-timescale` (#140).
        if launchOptions.fakeServices != nil {
            services.queue = PacedQueueService(services.queue, interval: .seconds(1 / launchOptions.timescale))
        }
        var device: (any DeviceIdentitySource)?
        if usesGameCenter(launchOptions) {
            let identity = GameKitIdentityService()
            services.identity = identity
            services.terms = LocalTermsService(identity: identity, defaults: .standard)
            device = GameKitDeviceIdentity(gameKit: identity)
        }
        #if DEBUG
        if let number = DevIdentity.number(launchOptions: launchOptions, defaults: .standard), launchOptions.fakeServices == nil {
            device = DevIdentity.device(number, restrictions: launchOptions.devRestrictions)
        }
        #endif
        var online: OnlineStatus.Session?
        #if DEBUG
        // The scenarios that are the session's own states play a session over their fakes (#161).
        if let fake = launchOptions.fakeServices.flatMap(FakeSession.make) {
            services.identity = fake.session.identity
            services.terms = fake.session.terms
            services.queue = fake.session.queue
            online = fake
        }
        #endif
        var connector: RaceConnector = { _ in UnansweredRaceConnection() }
        if let device, let url = OnlineEndpoint.serviceURL(launchOptions: launchOptions, defaults: .standard,
                                                           info: Bundle.main.infoDictionary ?? [:]) {
            let session = makeSession(url: url, device: device)
            services.adopt(session)
            online = OnlineStatus.Session(session: session, device: device)
            if let race = OnlineEndpoint.raceConnector(serviceURL: url) { connector = race }
        }
        // The shop sells every paid design from a stub until StoreKit (#137): see `StubStoreService`. Its defaults
        // are My boat's (UI tests' own suite, emptied at launch).
        services.store = StubStoreService(boatClass: RaceFiles.defaults.boatClass.ref.id,
                                          defaults: .init(MyBoatDefaults.defaults(for: launchOptions, standard: .standard)),
                                          isOnline: OnlineStatus.isInitiallyOnline(launchOptions))
        return (services, online, connector)
    }

    /// The online session on the real transport, the Keychain and the system's clock (#161), proving each connection
    /// with App Attest (#158; `unsupported` on the simulator).
    private static func makeSession(url: URL, device: any DeviceIdentitySource) -> OnlineSession {
        let keys = KeychainAttestationKeyStore()
        keys.purgeOnFreshInstall(defaults: .standard)
        let tokens = KeychainSessionTokenStore()
        tokens.purgeOnFreshInstall(defaults: .standard)
        // Kept in the app's own defaults even under UI tests, so a relaunch after a deletion still holds her (#166).
        let held = DefaultsHeldPlayerStore(defaults: .standard)
        let attester = ConnectionAttester(attestor: DeviceAppAttestor(), store: keys, nonce: { DeviceAppAttestor.nonce() })
        let log = Logger(subsystem: "com.phillreeder.regatta", category: "session")
        return OnlineSession(OnlineSession.Dependencies(
            connect: { try await URLSessionServiceLink.connect(to: url) }, device: device, tokens: tokens,
            sleep: { try await Task.sleep(for: $0) }, jitter: { Double.random(in: -1...1) },
            clientBuild: OnlineLaunch.clientBuild, attester: attester, held: held,
            // An event names no player and carries no token or signature; private all the same.
            log: { event in log.info("session: \(String(describing: event), privacy: .private)") }))
    }

    /// Game Center and the device's terms only off the fakes, outside UI tests (`-uitesting`) and unit tests.
    private static func usesGameCenter(_ launchOptions: LaunchOptions) -> Bool {
        launchOptions.fakeServices == nil && !launchOptions.uiTesting
            && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    }

    /// The running app's delegate.
    static var current: AppDelegate? { UIApplication.shared.delegate as? AppDelegate }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let analytics = analytics
        let metricKit = MetricKitForwarder(analytics: analytics)
        metricKit.start()
        self.metricKit = metricKit
        // `.ambient` (#126): the silent switch silences the game. Tests, UI tests and render fixtures play nothing.
        if AppAudio.isLive(.current) { SoundSession.configure() }
        // Game Center signs a returning player in silently; its sign-in sheet waits for Race online (#23, #138).
        (services.identity as? GameKitIdentityService)?.start()
        if let gameKit = (online?.device as? GameKitDeviceIdentity)?.gameKit { gameKit.start() }
        // The session follows the device's player from here; it opens nothing until she can use it (#161).
        if let session = online?.session { Task { await session.start() } }
        #if DEBUG
        if LaunchOptions.current.captureAppAttestFixture { AppAttestFixtureCapture.run() }
        #endif
        Task { await analytics.flush() }
        return true
    }
}
