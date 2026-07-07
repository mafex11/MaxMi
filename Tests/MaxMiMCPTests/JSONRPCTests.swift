import XCTest
@testable import MaxMiMCP

final class JSONRPCTests: XCTestCase {
    func testParseValidRequest() {
        let msg = JSONRPC.parse(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        XCTAssertEqual(msg?["method"] as? String, "ping")
        XCTAssertEqual(msg?["id"] as? Int, 1)
    }
    func testParseGarbageReturnsNil() {
        XCTAssertNil(JSONRPC.parse("not json"))
        XCTAssertNil(JSONRPC.parse(#"["array","not","object"]"#))
        XCTAssertNil(JSONRPC.parse(""))
    }
    func testResponseAndErrorAreSingleLineJSON() {
        let r = JSONRPC.response(id: 1, result: ["ok": true])
        XCTAssertFalse(r.contains("\n"))
        let parsed = JSONRPC.parse(r)
        XCTAssertEqual((parsed?["result"] as? [String: Any])?["ok"] as? Bool, true)
        let e = JSONRPC.error(id: 2, code: -32601, message: "nope")
        let ep = JSONRPC.parse(e)
        XCTAssertEqual(((ep?["error"] as? [String: Any])?["code"]) as? Int, -32601)
    }
}
