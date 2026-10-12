import Foundation
import RegattaServiceClient
import Security

/// The session tokens in the Keychain (#161): a generic password per Game Center player, the account her
/// `teamPlayerID`, the value the token's bytes and nothing else. Readable only while the device is unlocked, never
/// synced, never restored to another device, in the app's own access group. The signature, its salt, the alias and
/// the restrictions are never stored.
nonisolated struct KeychainSessionTokenStore: SessionTokenStore {
    static let service = "com.phillreeder.regatta.session"
    /// Set once this install has looked at the Keychain.
    static let installedKey = "session.keychainChecked"

    struct Failure: Error, Equatable {
        /// The `OSStatus`. Never the item.
        var status: Int32
    }

    var service = KeychainSessionTokenStore.service

    private func query(_ account: String?) -> [CFString: Any] {
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrSynchronizable: false]
        if let account { query[kSecAttrAccount] = account }
        return query
    }

    func token(for teamPlayerID: String) throws -> [UInt8]? {
        var query = query(teamPlayerID)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw Failure(status: status) }
        return [UInt8](data)
    }

    func setToken(_ token: [UInt8], for teamPlayerID: String) throws {
        var item = query(teamPlayerID)
        item[kSecValueData] = Data(token)
        item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        var status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query(teamPlayerID) as CFDictionary, [
                kSecValueData: Data(token), kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ] as CFDictionary)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    func removeToken(for teamPlayerID: String) throws {
        let status = SecItemDelete(query(teamPlayerID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }

    func removeAll(except teamPlayerID: String?) throws {
        for account in try accounts() where account != teamPlayerID { try removeToken(for: account) }
    }

    /// The players a token is kept for.
    func accounts() throws -> [String] {
        var query = query(nil)
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitAll
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let found = items as? [[CFString: Any]] else { throw Failure(status: status) }
        return found.compactMap { $0[kSecAttrAccount] as? String }
    }

    /// The Keychain outlives the app: a token found by a fresh install belongs to an install that is gone, so the
    /// first launch deletes them all. `defaults` remembers that it has (they are deleted with the app).
    func purgeOnFreshInstall(defaults: UserDefaults) {
        guard !defaults.bool(forKey: Self.installedKey) else { return }
        try? removeAll(except: nil)
        defaults.set(true, forKey: Self.installedKey)
    }
}
