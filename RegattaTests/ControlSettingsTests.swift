import Foundation
import Testing
@testable import Regatta

/// The device's controls a race reads (#112, #113): the tilt (#597) among them.
@MainActor @Suite struct ControlSettingsTests {
    private func parse(_ arguments: String...) -> LaunchOptions {
        LaunchOptions(arguments: ["/path/to/Regatta"] + arguments)
    }

    /// A new install draws at 45°; Settings holds the tilt inside 5…55 whatever is stored or set; `-tilt` stands over
    /// Settings, and a render fixture draws at 45 unless `-tilt` says otherwise.
    @Test func tiltDefaultsTo45AndClampsTo5To55() throws {
        #expect(DeviceSettings().tilt == 45)
        #expect(ControlSettings().tilt == 45)
        #expect(ControlSettings(DeviceSettings(), launchOptions: parse()).tilt == 45)

        var settings = DeviceSettings()
        settings.tilt = 70
        #expect(settings.tilt == 55)
        settings.tilt = 0
        #expect(settings.tilt == 5)
        settings.tilt = .nan
        #expect(settings.tilt == 45)
        settings.tilt = 30
        #expect(ControlSettings(settings, launchOptions: parse()).tilt == 30)
        #expect(ControlSettings(tilt: 90).tilt == 55)

        let controls = ControlSettings(settings, launchOptions: parse("-tilt", "20"))
        #expect(controls.tilt == 20, "-tilt over Settings")
        settings.tilt = 50
        controls.update(settings, launchOptions: parse())
        #expect(controls.tilt == 50, "a Settings change reaches the race")
        #expect(ControlSettings.tilt(30, launchOptions: parse("-fixture", "windward-mark")) == 45)
        #expect(ControlSettings.tilt(30, launchOptions: parse("-fixture", "windward-mark", "-tilt", "10")) == 10)

        let name = "ControlSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(DeviceSettings(defaults: defaults).tilt == 45)
        defaults.set(80.0, forKey: DeviceSettings.Key.tilt.rawValue)
        #expect(DeviceSettings(defaults: defaults).tilt == 55, "a stored tilt past the range reads clamped")
        settings.tilt = 25
        settings.save(to: defaults)
        #expect(DeviceSettings(defaults: defaults).tilt == 25)
    }
}
