import XCTest
@testable import MaxMiCore

final class IdentTests: XCTestCase {
    func testUUIDv7ShapeAndVersion() {
        let id = Ident.uuidv7(nowMs: 1_720_000_000_000)
        // 8-4-4-4-12 lowercase hex
        XCTAssertNotNil(id.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#, options: .regularExpression))
    }
    func testUUIDv7TimeSortable() {
        let a = Ident.uuidv7(nowMs: 1_000)
        let b = Ident.uuidv7(nowMs: 2_000)
        XCTAssertLessThan(a.prefix(13), b.prefix(13)) // 48-bit ms timestamp leads
    }
    func testSha256HexKnownVector() {
        XCTAssertEqual(ContentHash.sha256Hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
