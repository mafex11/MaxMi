import Foundation
import Security

/// Stores the short-lived, per-install MaxMi relay credential in the login Keychain.
/// Provider credentials are never accepted or stored here.
public enum RelayTokenStore {
    public enum TokenError: Error {
        case unavailable(OSStatus)
        case invalid
    }

    private static let service = "dev.mafex.maxmi.relay-token"

    public static func read() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              isValid(token) else {
            throw TokenError.unavailable(status)
        }
        return token
    }

    public static func store(_ token: String) throws {
        guard isValid(token), let data = token.data(using: .utf8) else {
            throw TokenError.invalid
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw TokenError.unavailable(status) }
        var add = query
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecValueData as String] = data
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw TokenError.unavailable(addStatus) }
    }

    public static func remove() throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenError.unavailable(status)
        }
    }

    private static func isValid(_ token: String) -> Bool {
        let count = token.utf8.count
        return count >= 16 && count <= 2_048 && !token.contains(where: { $0.isWhitespace })
    }
}
