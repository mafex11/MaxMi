import Foundation
import CryptoKit
import Security

// NOTE: duplicated verbatim in Sources/MaxMi/ and Sources/MaxMiMCP/ — two executable
// targets, one 40-line function; a shared target for this alone isn't worth it.
public enum KeychainKeyStore {
    public enum KeyError: Error { case unavailable(OSStatus) }

    static let service = "dev.mafex.maxmi.dbkey"
    static let accessGroup = "6B7UDKRDH2.dev.mafex.maxmi"

    public static func getOrCreate() throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return data }
        guard status == errSecItemNotFound else { throw KeyError.unavailable(status) }

        let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: fresh,
        ]
        status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { return fresh }
        if status == errSecDuplicateItem {           // lost the creation race — re-read
            query[kSecReturnData as String] = true
            status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data, data.count == 32 { return data }
        }
        throw KeyError.unavailable(status)
    }
}
