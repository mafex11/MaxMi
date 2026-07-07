import Foundation

// Placeholder provider until Task 5 wires real queries.
struct NoTools: ToolProvider {
    var toolDefinitions: [[String: Any]] { [] }
    func call(name: String, arguments: [String: Any]) async -> ToolResult {
        ToolResult(text: "not wired yet", isError: true)
    }
}

let server = MCPServer(tools: NoTools())
while let line = readLine(strippingNewline: true) {
    if let reply = await server.handle(line) {
        print(reply)
        FileHandle.standardOutput.synchronizeFile()
    }
}
