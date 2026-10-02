import Foundation
import RegattaCore

/// Your livery (#136, #21), kept on the device as JSON. #162 syncs the server's copy over it on sign-in.
struct LiveryStore {
    let defaults: UserDefaults
    static let key = "myLivery"

    /// The stored livery if it's valid for `boatClass`; else a new player's (#21: a random free starter design in random
    /// palette colours, with a random sail number) from `seed`, or `fallback` when given, saved at once so it's stable.
    func load(boatClass: String, catalogue: LiveryCatalogue = .bundled, seed: UInt64 = .random(in: .min ... .max),
              fallback: Livery? = nil) -> Livery {
        if let data = defaults.data(forKey: Self.key), let livery = try? JSONDecoder().decode(Livery.self, from: data),
           (try? catalogue.validate(livery, boatClass: boatClass)) != nil {
            return livery
        }
        let livery = fallback ?? catalogue.newPlayerLivery(boatClass: boatClass, seed: seed) ?? FleetLiveries.yours
        save(livery)
        return livery
    }

    func save(_ livery: Livery) {
        guard let data = try? JSONEncoder().encode(livery) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// Online races you've completed (#21, G6: any result but RET; never practice, never a cancelled race): what earned
/// designs count. Nothing counts them on the device yet: #162/#163 set it from the server's profile, and
/// `-completedRaces` for UI tests.
struct CompletedRacesStore {
    let defaults: UserDefaults
    static let key = "completedOnlineRaces"

    var count: Int {
        get { max(0, defaults.integer(forKey: Self.key)) }
        nonmutating set { defaults.set(max(0, newValue), forKey: Self.key) }
    }
}

/// Where My boat keeps your livery, owned designs and completed races: the app's defaults, or in UI tests a suite of
/// their own, emptied at launch unless `-keepMyBoat` (a relaunch that checks what was saved), so a changed livery
/// never leaks into another test.
enum MyBoatDefaults {
    static let uiTestingSuite = "com.phillreeder.regatta.uitesting.myboat"
    /// Whether this launch has emptied the UI tests' suite: the store stub and `AppModel` both ask.
    private static var emptied = false

    /// The suite's name for `launchOptions`, or nil for the app's own defaults.
    static func suiteName(for launchOptions: LaunchOptions) -> String? {
        launchOptions.uiTesting ? uiTestingSuite : nil
    }

    /// The defaults for `launchOptions`; the UI tests' suite emptied once per launch unless `-keepMyBoat`.
    static func defaults(for launchOptions: LaunchOptions, standard: UserDefaults) -> UserDefaults {
        guard let name = suiteName(for: launchOptions), let suite = UserDefaults(suiteName: name) else { return standard }
        if !emptied {
            emptied = true
            if !launchOptions.keepMyBoat { suite.removePersistentDomain(forName: name) }
        }
        return suite
    }
}
