import XCTest
@testable import MaxMiMCP

struct StubTools: ToolProvider {
    var toolDefinitions: [[String: Any]] {
        [["name": "search_memory", "description": "d", "inputSchema": ["type": "object"]],
         ["name": "list_active_threads", "description": "d", "inputSchema": ["type": "object"]],
         ["name": "meeting_memory", "description": "d", "inputSchema": ["type": "object"]]]
    }
    func call(name: String, arguments: [String: Any]) async -> ToolResult {
        if name == "search_memory" {
            return ToolResult(text: "echo: \(arguments["query"] as? String ?? "")")
        }
        return ToolResult(text: "Unknown tool: \(name)", isError: true)
    }
}

final class MCPServerTests: XCTestCase {
    let server = MCPServer(tools: StubTools())

    func req(_ s: String) async -> [String: Any]? {
        guard let out = await server.handle(s) else { return nil }
        return JSONRPC.parse(out)
    }

    func testInitializeHandshake() async {
        let r = await req(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#)
        let result = r?["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-06-18")
        let info = result?["serverInfo"] as? [String: Any]
        XCTAssertEqual(info?["name"] as? String, "maxmi")
        XCTAssertNotNil((result?["capabilities"] as? [String: Any])?["tools"])
    }
    func testInitializedNotificationGetsNoReply() async {
        let out = await server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(out)
    }
    func testToolsListReturnsThreeTools() async {
        let r = await req(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = (r?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.map { $0["name"] as? String },
                       ["search_memory", "list_active_threads", "meeting_memory"])
    }
    func testToolsCallWrapsTextContent() async {
        let r = await req(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_memory","arguments":{"query":"hi"}}}"#)
        let result = r?["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["type"] as? String, "text")
        XCTAssertEqual(content?.first?["text"] as? String, "echo: hi")
        XCTAssertEqual(result?["isError"] as? Bool, false)
    }
    func testUnknownMethodReturnsMinus32601() async {
        let r = await req(#"{"jsonrpc":"2.0","id":4,"method":"resources/list"}"#)
        XCTAssertEqual(((r?["error"] as? [String: Any])?["code"]) as? Int, -32601)
    }
    func testMissingToolNameReturnsMinus32602() async {
        let r = await req(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{}}"#)
        XCTAssertEqual(((r?["error"] as? [String: Any])?["code"]) as? Int, -32602)
    }
    func testGarbageLineNoCrashNoReply() async {
        let out = await server.handle("}{ total garbage")
        XCTAssertNil(out)     // unparseable -> cannot know id -> drop, log to stderr
    }
    func testPing() async {
        let r = await req(#"{"jsonrpc":"2.0","id":6,"method":"ping"}"#)
        XCTAssertNotNil(r?["result"])
    }
}
