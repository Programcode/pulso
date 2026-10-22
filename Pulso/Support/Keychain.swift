import Foundation
import Security

/// Single-purpose keychain wrapper for the optional server bearer token.
enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "dev.lenilson.pulso"

    static func string(for account: String) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// nil or empty deletes the item. An existing item is updated in place,
    /// so a concurrent reader never sees it missing mid-write.
    static func set(_ value: String?, for account: String) {
        guard let value, !value.isEmpty else {
            SecItemDelete(base(account) as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(base(account) as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var attributes = base(account)
            attributes.merge(update) { _, new in new }
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }

    private static func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
