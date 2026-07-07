import Foundation
import MaxMiCore

public struct ToolResult: Sendable {
    public let text: String
    public let isError: Bool
    public init(text: String, isError: Bool = false) {
        self.text = text; self.isError = isError
    }
}

public protocol ToolProvider: Sendable {
    var toolDefinitions: [[String: Any]] { get }
    func call(name: String, arguments: [String: Any]) async -> ToolResult
}

public struct MCPServer {
    let tools: any ToolProvider
    public init(tools: any ToolProvider) { self.tools = tools }

    /// One frame in, at most one frame out. nil = no reply (notification or unparseable).
    public func handle(_ line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let msg = JSONRPC.parse(trimmed) else {
            if !trimmed.isEmpty { logStderr("dropped unparseable frame") }
            return nil
        }
        let id = msg["id"]
        guard let method = msg["method"] as? String else {
            return id.map { _ in JSONRPC.error(id: id, code: -32600, message: "missing method") }
        }
        if id == nil { return nil }                       // notifications never get replies

        switch method {
        case "initialize":
            return JSONRPC.response(id: id!, result: [
                "protocolVersion": "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "maxmi", "version": MaxMiVersion.current],
            ])
        case "ping":
            return JSONRPC.response(id: id!, result: [String: Any]())
        case "tools/list":
            return JSONRPC.response(id: id!, result: ["tools": tools.toolDefinitions])
        case "tools/call":
            let params = msg["params"] as? [String: Any] ?? [:]
            guard let name = params["name"] as? String else {
                return JSONRPC.error(id: id, code: -32602, message: "tools/call requires params.name")
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            let result = await tools.call(name: name, arguments: args)
            return JSONRPC.response(id: id!, result: [
                "content": [["type": "text", "text": result.text]],
                "isError": result.isError,
            ])
        default:
            return JSONRPC.error(id: id, code: -32601, message: "method not found: \(method)")
        }
    }
}

func logStderr(_ message: String) {
    FileHandle.standardError.write(Data("maxmi-mcp: \(message)\n".utf8))
}
