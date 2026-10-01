import Foundation
import Testing
@testable import Regatta

/// The device settings store (#110): per device, in `UserDefaults`, never synced.
@MainActor @Suite struct DeviceSettingsTests {
    /// A private defaults domain, removed after `body`.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "DeviceSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    /// Nothing stored reads as the defaults (auto zoom on and no pinch-zoom among them); every value survives a save and a load;
    /// a value stored wrong reads as its default.
    @Test func defaultsAndRoundTrip() throws {
        try withDefaults { defaults in
            let fresh = DeviceSettings(defaults: defaults)
            #expect(fresh == DeviceSettings())
            #expect(fresh.steering == .halves && fresh.camera == .courseUp)
            #expect(fresh.autoZoom && fresh.zoomMultiplier == 1 && fresh.laylines && !fresh.ladderLines && fresh.hints)
            #expect(fresh.music && fresh.effects && fresh.haptics)
            #expect(!fresh.hidesLobbyChat && fresh.sharesUsageData)

            var changed = DeviceSettings()
            changed.steering = .tiller
            changed.camera = .boatUp
            changed.autoZoom = false
            changed.zoomMultiplier = 1.35
            changed.laylines = false
            changed.ladderLines = true
            changed.hints = false
            changed.music = false
            changed.effects = false
            changed.haptics = false
            changed.hidesLobbyChat = true
            changed.sharesUsageData = false
            changed.save(to: defaults)
            #expect(DeviceSettings(defaults: defaults) == changed)
            #expect(Set(DeviceSettings.Key.allCases.map(\.rawValue)).isSubset(of: defaults.dictionaryRepresentation().keys))

            defaults.set("dial", forKey: DeviceSettings.Key.steering.rawValue)
            defaults.set("maybe", forKey: DeviceSettings.Key.haptics.rawValue)
            let damaged = DeviceSettings(defaults: defaults)
            #expect(damaged.steering == .halves && damaged.haptics)
        }
    }

    /// Auto zoom was Auto framing (#113, #322): a device that turned Auto framing off keeps auto zoom off, until
    /// Auto zoom itself is saved.
    @Test func autoFramingReadsAsAutoZoom() throws {
        try withDefaults { defaults in
            defaults.set(false, forKey: DeviceSettings.legacyAutoFramingKey)
            #expect(!DeviceSettings(defaults: defaults).autoZoom)
            defaults.set(true, forKey: DeviceSettings.Key.autoZoom.rawValue)
            #expect(DeviceSettings(defaults: defaults).autoZoom)
        }
    }

    /// The model saves each change as it's made, and a new model on the same defaults reads it back.
    @Test func theModelSavesChanges() throws {
        try withDefaults { defaults in
            let model = AppModel(defaults: defaults)
            #expect(model.deviceSettings == DeviceSettings())
            model.deviceSettings.ladderLines = true
            model.deviceSettings.camera = .boatUp
            #expect(DeviceSettings(defaults: defaults).ladderLines)
            // A pinch-zoom kept by a race (#322) is saved too, and every race reads it.
            model.controls.keepZoomMultiplier(1.4)
            #expect(model.deviceSettings.zoomMultiplier == 1.4)
            let reopened = AppModel(defaults: defaults)
            #expect(reopened.deviceSettings.ladderLines && reopened.deviceSettings.camera == .boatUp)
            #expect(reopened.deviceSettings.zoomMultiplier == 1.4 && reopened.controls.zoomMultiplier == 1.4)
        }
    }

    /// Reset hints forgets every hint's progress, and nothing else.
    @Test func resetHintsClearsOnlyHints() throws {
        try withDefaults { defaults in
            defaults.set(2, forKey: DeviceSettings.hintKeyPrefix + "steer")
            defaults.set(true, forKey: DeviceSettings.hintKeyPrefix + "tack")
            var settings = DeviceSettings()
            settings.hints = false
            settings.save(to: defaults)
            AppModel(defaults: defaults).resetHints()
            #expect(defaults.object(forKey: DeviceSettings.hintKeyPrefix + "steer") == nil)
            #expect(defaults.object(forKey: DeviceSettings.hintKeyPrefix + "tack") == nil)
            #expect(DeviceSettings(defaults: defaults) == settings)
        }
    }

    /// Hide lobby chat turns the lobby area into the queue and leaderboard (#17, #25).
    @Test func hideLobbyChatHidesTheLobby() {
        let status = LobbyStatus(isSignedIn: true, hasAcceptedTerms: true, queuedPlayers: 4)
        #expect(LobbyPanelState(isOnline: true, status: status.hidingChat(false)) == .lobby)
        #expect(LobbyPanelState(isOnline: true, status: status.hidingChat(true)) == .chatHidden(queuedPlayers: 4))
    }
}
