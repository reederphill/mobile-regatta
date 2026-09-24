import Foundation
import Testing
@testable import Regatta

/// The shipping configuration in the built app bundle (#107).
@MainActor @Suite struct ShippingConfigTests {
    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    @Test func requiresAnA12() throws {
        let capabilities = try #require(info["UIRequiredDeviceCapabilities"] as? [String])
        #expect(capabilities.contains("iphone-ipad-minimum-performance-a12"))
    }

    @Test func declaresNoNonExemptEncryption() {
        #expect(info["ITSAppUsesNonExemptEncryption"] as? Bool == false)
    }

    @Test func usesTheSceneLifeCycleAndALaunchScreen() throws {
        let manifest = try #require(info["UIApplicationSceneManifest"] as? [String: Any])
        let configurations = try #require(manifest["UISceneConfigurations"] as? [String: [[String: Any]]])
        let application = try #require(configurations["UIWindowSceneSessionRoleApplication"]?.first)
        #expect(application["UISceneDelegateClassName"] as? String == "Regatta.SceneDelegate")
        #expect(info["UILaunchScreen"] is [String: Any])
    }

    @Test func doesNotRelyOnRequiringFullScreen() {
        #expect(info["UIRequiresFullScreen"] == nil)
    }

    @Test func bundlesAPrivacyManifestWithoutTracking() throws {
        let url = try #require(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let manifest = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        let apis = try #require(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let userDefaults = try #require(apis.first { $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryUserDefaults" })
        #expect(userDefaults["NSPrivacyAccessedAPITypeReasons"] as? [String] == ["CA92.1"])
        let collected = try #require(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        #expect(collected.allSatisfy { $0["NSPrivacyCollectedDataTypeTracking"] as? Bool == false })
    }

    @Test func bundlesTheAcknowledgements() throws {
        let acknowledgements = try Acknowledgement.bundled()
        #expect(acknowledgements.allSatisfy { !$0.name.isEmpty && !$0.license.isEmpty })
    }
}
