import Foundation

public enum MaxMiToolsDefinitions {
    public static var all: [[String: Any]] {
        [
            ["name": "search_memory",
             "description": "Semantic search over everything the user has read on screen. Returns matching memory facts (third person) with sources, as markdown.",
             "inputSchema": ["type": "object",
                             "properties": ["query": ["type": "string", "description": "What to search for"],
                                            "limit": ["type": "number", "description": "Max results (default 10, max 20)"]],
                             "required": ["query"]]],
            ["name": "list_active_threads",
             "description": "Recently viewed pages/threads with their latest memory facts, as markdown.",
             "inputSchema": ["type": "object",
                             "properties": ["limit": ["type": "number", "description": "Max threads (default 10, max 20)"]],
                             "required": [String]()]],
            ["name": "meeting_memory",
             "description": "Query meeting memories. (No meetings are captured in this MaxMi version yet.)",
             "inputSchema": ["type": "object",
                             "properties": ["action": ["type": "string", "enum": ["list", "get_context", "search"]],
                                            "query": ["type": "string"]],
                             "required": ["action"]]],
        ]
    }
}

public struct MaxMiTools: ToolProvider {
    let queries: MemoryQueries
    public init(queries: MemoryQueries) { self.queries = queries }

    public var toolDefinitions: [[String: Any]] {
        MaxMiToolsDefinitions.all
    }

    public func call(name: String, arguments: [String: Any]) async -> ToolResult {
        switch name {
        case "search_memory":
            guard let query = arguments["query"] as? String else {
                return ToolResult(text: "search_memory requires a 'query' string", isError: true)
            }
            return await queries.searchMemory(query: query, limit: intArg(arguments["limit"]))
        case "list_active_threads":
            return queries.listActiveThreads(limit: intArg(arguments["limit"]))
        case "meeting_memory":
            guard let action = arguments["action"] as? String,
                  ["list", "get_context", "search"].contains(action) else {
                return ToolResult(text: "meeting_memory requires action: list | get_context | search", isError: true)
            }
            return queries.meetingMemory(action: action)
        default:
            return ToolResult(text: "Unknown tool: \(name)", isError: true)
        }
    }

    private func intArg(_ v: Any?) -> Int? {
        (v as? Int) ?? (v as? Double).map(Int.init) ?? (v as? NSNumber)?.intValue
    }
}
