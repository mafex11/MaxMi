import CryptoKit
import Foundation

public enum CipherError: Error, Equatable {
    case integrityFailure       // authentication failed: tampered data or wrong key
    case malformedCiphertext    // prefixed but not decodable as nonce+ct+tag
}

/// Encrypts/decrypts individual TEXT column values. Minimi-parity wire format:
/// "enc:v1:" + base64(nonce[12] ‖ ciphertext ‖ tag[16]), AES-256-GCM, no AAD.
public protocol FieldCipher: Sendable {
    func encrypt(_ plaintext: String) throws -> String
    func decrypt(_ stored: String) throws -> String
}

public struct AESGCMFieldCipher: FieldCipher {
    static let prefix = "enc:v1:"
    let key: SymmetricKey

    public init(keyData: Data) {
        precondition(keyData.count == 32, "AES-256 needs a 32-byte key")
        self.key = SymmetricKey(data: keyData)
    }

    public func encrypt(_ plaintext: String) throws -> String {
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        // .combined is nonce ‖ ciphertext ‖ tag for the default 12-byte nonce.
        return Self.prefix + sealed.combined!.base64EncodedString()
    }

    public func decrypt(_ stored: String) throws -> String {
        guard stored.hasPrefix(Self.prefix) else { return stored }   // passthrough: pre-M3 rows
        guard let blob = Data(base64Encoded: String(stored.dropFirst(Self.prefix.count))),
              blob.count >= 12 + 16,
              let box = try? AES.GCM.SealedBox(combined: blob) else {
            throw CipherError.malformedCiphertext
        }
        guard let plain = try? AES.GCM.open(box, using: key) else {
            throw CipherError.integrityFailure
        }
        return String(decoding: plain, as: UTF8.self)
    }
}

public typealias FixedKeyCipher = AESGCMFieldCipher

public extension AESGCMFieldCipher {
    /// Deterministic key for tests. Never used outside test targets.
    static var testCipher: AESGCMFieldCipher { AESGCMFieldCipher(keyData: Data(repeating: 7, count: 32)) }
}
