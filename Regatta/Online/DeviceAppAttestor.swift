import CryptoKit
import DeviceCheck
import Foundation
import os
import RegattaProtocol
import RegattaServiceClient
import Security

/// App Attest on the device (#158, ADR 0014): `DCAppAttestService.shared`, its base64 key ids as bytes and its errors as
/// `AppAttestorError`. Unsupported on the simulator: the session then sends `unsupported`, which only a dev server's
/// bypass lets through.
nonisolated struct DeviceAppAttestor: AppAttestor {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }

    func generateKey() async throws(AppAttestorError) -> [UInt8] {
        let keyID: String
        do { keyID = try await DCAppAttestService.shared.generateKey() } catch { throw Self.map(error) }
        guard let bytes = Data(base64Encoded: keyID) else { throw .other }
        return [UInt8](bytes)
    }

    func attestKey(_ keyID: [UInt8], clientDataHash: [UInt8]) async throws(AppAttestorError) -> [UInt8] {
        do {
            return [UInt8](try await DCAppAttestService.shared.attestKey(Data(keyID).base64EncodedString(), clientDataHash: Data(clientDataHash)))
        } catch {
            throw Self.map(error)
        }
    }

    func generateAssertion(_ keyID: [UInt8], clientDataHash: [UInt8]) async throws(AppAttestorError) -> [UInt8] {
        do {
            return [UInt8](try await DCAppAttestService.shared.generateAssertion(Data(keyID).base64EncodedString(),
                                                                                  clientDataHash: Data(clientDataHash)))
        } catch {
            throw Self.map(error)
        }
    }

    static func map(_ error: any Error) -> AppAttestorError {
        guard let error = error as? DCError else { return .other }
        switch error.code {
        case .featureUnsupported: return .unsupported
        case .serverUnavailable: return .serverUnavailable
        case .invalidKey, .invalidInput: return .invalidKey
        default: return .other
        }
    }

    /// Sixteen random bytes for a proof's client data.
    static func nonce() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: AttestationClientData.nonceLength)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<bytes.count).map { _ in UInt8.random(in: 0...255) }
        }
        return bytes
    }
}

/// The App Attest key id in the Keychain (#158): one generic password, the key id and whether the server acknowledged
/// its attestation, readable from the first unlock after a boot (a connection made while the device is locked, from a
/// background launch, still finds it), never synced or restored to another device. A fresh install's
/// first launch deletes it with the session tokens (`KeychainSessionTokenStore.purgeOnFreshInstall`): the key lives in
/// this install's Secure Enclave only.
nonisolated struct KeychainAttestationKeyStore: AttestationKeyStore {
    static let service = "com.phillreeder.regatta.appattest"
    static let account = "key"

    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service, kSecAttrAccount: Self.account, kSecAttrSynchronizable: false]
    }

    func load() -> AttestationKeyRecord? {
        var query = query
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(AttestationKeyRecord.self, from: data)
    }

    func save(_ record: AttestationKeyRecord?) {
        SecItemDelete(query as CFDictionary)
        guard let record, let data = try? JSONEncoder().encode(record) else { return }
        var item = query
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    /// Runs with the session tokens' purge: once per install.
    func purgeOnFreshInstall(defaults: UserDefaults) {
        guard !defaults.bool(forKey: KeychainSessionTokenStore.installedKey) else { return }
        save(nil)
    }
}

#if DEBUG
/// `-captureAppAttestFixture` (#175, DEBUG only, no UI): on a device, makes a key, attests it and asserts once over
/// fixed client data, and writes `Documents/app-attest.json` in `RealAppAttestTests`' schema. Copy it off the device
/// with Xcode's container download into `Packages/RegattaServer/Tests/Fixtures/real/`. No server is needed: the fixture
/// verifies offline against Apple's root at its capture time.
enum AppAttestFixtureCapture {
    struct Fixture: Encodable {
        var teamID: String
        var bundleID: String
        var environment: String
        var keyID: String
        var attestation: String
        var attestationClientData: String
        var assertion: String
        var assertionClientData: String
        var assertionCounter: UInt32
        var capturedAt: UInt64
    }

    static func run() {
        let log = Logger(subsystem: "com.phillreeder.regatta", category: "appattest")
        Task {
            do {
                let url = try await capture()
                log.notice("App Attest fixture written to \(url.path, privacy: .public)")
            } catch {
                log.error("App Attest fixture capture failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    static func capture() async throws -> URL {
        let device = DeviceAppAttestor()
        guard device.isSupported else { throw AppAttestorError.unsupported }
        let capturedAt = UInt64(Date().timeIntervalSince1970 * 1000)
        let keyID = try await device.generateKey()
        let attestationClientData = Array("regatta app attest fixture: attestation".utf8)
        let assertionClientData = Array("regatta app attest fixture: assertion".utf8)
        let attestation = try await device.attestKey(keyID, clientDataHash: Array(SHA256.hash(data: attestationClientData)))
        let assertion = try await device.generateAssertion(keyID, clientDataHash: Array(SHA256.hash(data: assertionClientData)))
        let info = Bundle.main.infoDictionary ?? [:]
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        // The App ID prefix is the team id: `AppIdentifierPrefix` is in the entitlements, not the Info.plist, so it is
        // read off the keychain access group a throwaway item lands in.
        let teamID = (info["AppIdentifierPrefix"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: ".")) ?? Self.teamID() ?? ""
        let environment = (info["APP_ATTEST_ENVIRONMENT"] as? String) ?? "development"
        let fixture = Fixture(teamID: teamID, bundleID: bundleID, environment: environment, keyID: Data(keyID).base64EncodedString(),
                              attestation: Data(attestation).base64EncodedString(),
                              attestationClientData: Data(attestationClientData).base64EncodedString(),
                              assertion: Data(assertion).base64EncodedString(),
                              assertionClientData: Data(assertionClientData).base64EncodedString(), assertionCounter: 1,
                              capturedAt: capturedAt)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("app-attest.json")
        try encoder.encode(fixture).write(to: url)
        return url
    }

    /// The team id, from the access group of a keychain item added and deleted at once.
    private static func teamID() -> String? {
        let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "com.phillreeder.regatta.teamid",
                                     kSecAttrAccount: "probe"]
        var query = item
        query[kSecReturnAttributes] = true
        var result: CFTypeRef?
        defer { SecItemDelete(item as CFDictionary) }
        guard SecItemAdd(query as CFDictionary, &result) == errSecSuccess,
              let group = (result as? [CFString: Any])?[kSecAttrAccessGroup] as? String else { return nil }
        return group.split(separator: ".").first.map(String.init)
    }
}
#endif
