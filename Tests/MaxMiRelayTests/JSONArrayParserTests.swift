import XCTest
@testable import MaxMiRelay

final class JSONArrayParserTests: XCTestCase {
    func testPlainArray() throws {
        XCTAssertEqual(try JSONArrayParser.parse(#"["a", "b"]"#), ["a", "b"])
    }
    func testFencedArray() throws {
        let raw = "```json\n[\"fact one\", \"fact two\"]\n```"
        XCTAssertEqual(try JSONArrayParser.parse(raw), ["fact one", "fact two"])
    }
    func testProseWrappedArray() throws {
        XCTAssertEqual(try JSONArrayParser.parse(#"Here you go: ["x"] hope that helps"#), ["x"])
    }
    func testGarbageThrows() {
        XCTAssertThrowsError(try JSONArrayParser.parse("no array here"))
        XCTAssertThrowsError(try JSONArrayParser.parse(#"{"not": "an array"}"#))
        XCTAssertThrowsError(try JSONArrayParser.parse(#"[1, 2, 3]"#)) // numbers, not strings
    }
    func testEmptyArrayIsValid() throws {
        XCTAssertEqual(try JSONArrayParser.parse("[]"), [])
    }
}
