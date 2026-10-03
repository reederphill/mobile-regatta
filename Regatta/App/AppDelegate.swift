import RegattaCore
import RegattaServices
import UIKit

/// The app's entry point. The UI lives in one window scene, `SceneDelegate`, declared in Info.plist's scene
/// manifest: apps built with the iOS 27 SDK must use the scene life cycle.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// The services every scene runs on. `-fakeServices <scenario>` plays a scenario's scripted fakes (#242);
    /// otherwise the device's connectivity, signed out, until the real services arrive.
    let services = AppDelegate.makeServices(launchOptions: .current)
    /// Usage analytics (#128), one for the app over its one set of `analytics.` keys: every scene logs to it. Sent at
    /// launch and on going to the background, never during a race.
    private(set) lazy var analytics = Analytics.app(transport: services.analytics)
    private var metricKit: MetricKitForwarder?

    private static func makeServices(launchOptions: LaunchOptions) -> ServiceSet {
        var services = launchOptions.fakeServices.map(ServiceSet.fake)
            ?? ServiceSet.unconnected(connectivity: PathConnectivityService())
        // The shop sells every paid design from a stub until StoreKit (#137): see `StubStoreService`. Its defaults
        // are My boat's (UI tests' own suite, emptied at launch).
        services.store = StubStoreService(boatClass: RaceFiles.defaults.boatClass.ref.id,
                                          defaults: .init(MyBoatDefaults.defaults(for: launchOptions, standard: .standard)),
                                          isOnline: launchOptions.fakeServices != .offline)
        return services
    }

    /// The running app's delegate.
    static var current: AppDelegate? { UIApplication.shared.delegate as? AppDelegate }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let analytics = analytics
        let metricKit = MetricKitForwarder(analytics: analytics)
        metricKit.start()
        self.metricKit = metricKit
        Task { await analytics.flush() }
        return true
    }
}
