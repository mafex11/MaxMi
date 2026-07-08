import XCTest
@testable import MaxMiCore

final class FieldCipherTests: XCTestCase {
    let cipher = AESGCMFieldCipher.testCipher

    func testUnavailableCipherThrowsOnEncrypt() {
        XCTAssertThrowsError(try UnavailableCipher().encrypt("secret")) {
            XCTAssertEqual($0 as? CipherError, .keyUnavailable)
        }
    }
    func testUnavailableCipherRefusesEncryptedButPassesPlaintext() throws {
        let u = UnavailableCipher()
        XCTAssertEqual(try u.decrypt("legacy plaintext"), "legacy plaintext")
        XCTAssertThrowsError(try u.decrypt("enc:v1:AAAA")) {
            XCTAssertEqual($0 as? CipherError, .keyUnavailable)
        }
    }

    func testRoundTrip() throws {
        let pt = "The user is watching episode 18 of Gin Tama."
        let ct = try cipher.encrypt(pt)
        XCTAssertEqual(try cipher.decrypt(ct), pt)
    }
    func testWireFormatShape() throws {
        let ct = try cipher.encrypt("hello")
        XCTAssertTrue(ct.hasPrefix("enc:v1:"))
        let blob = Data(base64Encoded: String(ct.dropFirst("enc:v1:".count)))
        XCTAssertNotNil(blob)
        XCTAssertEqual(blob!.count, 12 + 5 + 16, "nonce(12) + ct(len(pt)) + tag(16)")
    }
    func testNonDeterministic() throws {
        XCTAssertNotEqual(try cipher.encrypt("same"), try cipher.encrypt("same"),
                          "fresh nonce per encryption")
    }
    func testPassthroughOnUnprefixedInput() throws {
        XCTAssertEqual(try cipher.decrypt("plain old text"), "plain old text")
        XCTAssertEqual(try cipher.decrypt(""), "")
    }
    func testTamperedCiphertextThrowsIntegrityFailure() throws {
        let ct = try cipher.encrypt("secret")
        var blob = Data(base64Encoded: String(ct.dropFirst(7)))!
        blob[blob.count - 1] ^= 0xff
        let tampered = "enc:v1:" + blob.base64EncodedString()
        XCTAssertThrowsError(try cipher.decrypt(tampered)) {
            XCTAssertEqual($0 as? CipherError, .integrityFailure)
        }
    }
    func testWrongKeyThrowsIntegrityFailure() throws {
        let other = AESGCMFieldCipher(keyData: Data(repeating: 9, count: 32))
        let ct = try cipher.encrypt("secret")
        XCTAssertThrowsError(try other.decrypt(ct)) {
            XCTAssertEqual($0 as? CipherError, .integrityFailure)
        }
    }
    func testMalformedBase64Throws() {
        XCTAssertThrowsError(try cipher.decrypt("enc:v1:!!!not-base64!!!")) {
            XCTAssertEqual($0 as? CipherError, .malformedCiphertext)
        }
        XCTAssertThrowsError(try cipher.decrypt("enc:v1:AAAA")) {   // too short for nonce+tag
            XCTAssertEqual($0 as? CipherError, .malformedCiphertext)
        }
    }
    func testEmptyAndUnicodeRoundTrip() throws {
        XCTAssertEqual(try cipher.decrypt(try cipher.encrypt("")), "")
        let uni = "日本語 🧠 emoji — dashes"
        XCTAssertEqual(try cipher.decrypt(try cipher.encrypt(uni)), uni)
    }
}
