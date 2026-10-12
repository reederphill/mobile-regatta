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
    /// identity, the terms, the queue, the race session and the profile are the online session's (#161, #162); the
    /// rest stay on their fakes until their tickets (#163–#166). With no endpoint nothing changes.
    let services: ServiceSet
    /// The online session and the device identity under it, when there is an endpoint.
    let online: OnlineStatus.Session?
    /// Opens a hand-off's race connection (#141): `/race` on the services' host with a session (#162), the Debug fake
    /// race host on the fakes; with neither (no endpoint) nothing answers.
    let raceConnector: RaceConnector

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
        super.init()
    }
    /// Usage analytics (#128), one for the app over its one set of `analytics.` keys: every scene logs to it. Sent at
    /// launch and on going to the background, never during a race.
    private(set) lazy var analytics = Analytics.app(transport: services.analytics)
    private var metricKit: MetricKitForwarder?

    private static func makeServices(launchOptions: LaunchOptions) -> (ServiceSet, OnlineStatus.Session?, RaceConnector) {
        // The fakes' online results scenarios fill in live, a sleep apart (the services package keeps no clock).
        var services = launchOptions.fakeServices.map { ServiceSet.fake($0, wait: { try? await Task.sleep(for: $0) }) }
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
        if let number = launchOptions.devIdentity, launchOptions.fakeServices == nil {
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

    /// The online session on the real transport, the Keychain and the system's clock (#161).
    private static func makeSession(url: URL, device: any DeviceIdentitySource) -> OnlineSession {
        let tokens = KeychainSessionTokenStore()
        tokens.purgeOnFreshInstall(defaults: .standard)
        let log = Logger(subsystem: "com.phillreeder.regatta", category: "session")
        return OnlineSession(OnlineSession.Dependencies(
            connect: { try await URLSessionServiceLink.connect(to: url) }, device: device, tokens: tokens,
            sleep: { try await Task.sleep(for: $0) }, jitter: { Double.random(in: -1...1) },
            clientBuild: OnlineLaunch.clientBuild,
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
        Task { await analytics.flush() }
        return true
    }
}
