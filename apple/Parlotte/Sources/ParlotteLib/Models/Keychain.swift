import Foundation
import Security

/// Thin wrapper over the macOS Keychain for storing per-profile secrets
/// (access tokens, refresh tokens). Items are scoped to the app bundle via
/// `kSecAttrService` and per-profile via `kSecAttrAccount`, and are marked
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` so they never leave the
/// device in an iCloud backup or via migration.
///
/// Prefers the **data-protection keychain** (`kSecUseDataProtectionKeychain`).
/// Unlike the legacy file-based "login" keychain, access is governed by the
/// app's entitlement / access group rather than a per-code-signature ACL, so
/// a signed app never triggers the "Parlotte wants to use your confidential
/// information… enter the login keychain password" prompt on launch.
///
/// Unsigned/unentitled builds (`swift run` during development, the test runner)
/// can't use the data-protection keychain, so we detect availability once at
/// startup and consistently use the legacy keychain there instead — keeping
/// every operation on the *same* store so reads and writes always agree.
public enum ParlotteKeychain {
    private static let service = "dev.nxthdr.Parlotte"

    /// Whether the data-protection keychain is usable in this process. Probed
    /// once: a signed/provisioned app (TestFlight/App Store) can use it; an
    /// unsigned dev/test build gets `errSecMissingEntitlement` and falls back
    /// to the legacy keychain for all operations.
    private static let useDataProtection: Bool = {
        let probeAccount = "__dataprotection_probe__"
        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: probeAccount,
            kSecValueData as String: Data("probe".utf8),
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess || status == errSecDuplicateItem {
            add.removeValue(forKey: kSecValueData as String)
            SecItemDelete(add as CFDictionary)
            return true
        }
        return false
    }()

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: useDataProtection,
        ]
    }

    /// Store `value` under `account`. Overwrites any existing entry.
    @discardableResult
    public static func set(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    public static func get(_ account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    @discardableResult
    public static func remove(_ account: String) -> Bool {
        let query = baseQuery(account: account)
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
