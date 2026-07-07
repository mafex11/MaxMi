import Foundation
import CryptoKit
import Security

// NOTE: duplicated verbatim in Sources/MaxMi/ and Sources/MaxMiMCP/ — two executable
// targets, one 40-line function; a shared target for this alone isn't worth it.
//
// LOGIN KEYCHAIN SHARING: Both binaries (MaxMi.app + maxmi-mcp) share the encryption
// key via the login keychain, identified by service name. Both are signed with the same
// identity, so keychain ACLs recognize them as the same app. First read in each binary
// prompts once for "Always Allow" (at most 2 prompts total), then silent. No keychain
// access group entitlement needed (that would require a provisioning profile, which we
// don't have for this personal build).
enum KeychainKeyStore {
    enum KeyError: Error { case unavailable(OSStatus) }

    static let service = "dev.mafex.maxmi.dbkey"

    static func getOrCreate() throws -> Data {
        // Try reading from login keychain.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return data }

        guard status == errSecItemNotFound else {
            throw KeyError.unavailable(status)
        }

        // No key exists — generate a fresh one.
        let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: fresh,
        ]
        status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { return fresh }

        // Lost the creation race — re-read.
        if status == errSecDuplicateItem {
            status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data, data.count == 32 { return data }
        }

        throw KeyError.unavailable(status)
    }
}
