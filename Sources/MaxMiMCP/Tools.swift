import Foundation

public enum MaxMiToolsDefinitions {
    private static var retrievalProperties: [String: Any] {
        [
            "source_apps": ["type": "array", "items": ["type": "string"],
                            "description": "Exact source-app names, for example Web, Slack, Cursor, Calendar, Meeting, or Voice Note"],
            "lookback_minutes": ["type": "integer", "minimum": 1,
                                 "description": "Relative lookback from the fixed as_of time; cannot be combined with start_time/end_time"],
            "start_time": ["type": "string", "description": "Inclusive ISO-8601/RFC3339 timestamp with timezone"],
            "end_time": ["type": "string", "description": "Inclusive ISO-8601/RFC3339 timestamp with timezone"],
            "timezone": ["type": "string", "description": "IANA timezone for rendered metadata, for example Asia/Kolkata"],
            "cursor": ["type": "string", "description": "Opaque next cursor from a previous response; repeat the same query and filters"],
        ]
    }

    private static func properties(_ additions: [String: Any]) -> [String: Any] {
        retrievalProperties.merging(additions) { _, new in new }
    }

    public static var all: [[String: Any]] {
        [
            ["name": "search_memory",
             "description": "Semantic search over captured memory facts. Supports exact app/time filters and deterministic cursor pagination.",
             "inputSchema": ["type": "object",
                             "properties": properties([
                                "query": ["type": "string", "description": "What to search for"],
                                "limit": ["type": "integer", "minimum": 1, "maximum": 20,
                                          "description": "Max results (default 10, max 20)"],
                             ]),
                             "required": ["query"]]],
            ["name": "list_active_threads",
             "description": "Recently viewed threads with their latest facts. Supports exact app/time filters and deterministic cursor pagination.",
             "inputSchema": ["type": "object",
                             "properties": properties([
                                "limit": ["type": "integer", "minimum": 1, "maximum": 20,
                                          "description": "Max threads (default 10, max 20)"],
                             ]),
                             "required": [String]()]],
            ["name": "get_latest_context",
             "description": "Fetch freshness-ranked full raw context without semantic search. Supports per-app, structured-kind, thread, time, and cursor filters.",
             "inputSchema": ["type": "object",
                             "properties": properties([
                                "source": ["type": "string", "description": "Optional fuzzy app/title/source match (legacy convenience filter)"],
                                "thread_id": ["type": "string", "description": "Return context for one exact thread ID"],
                                "content_kinds": ["type": "array",
                                                  "items": ["type": "string", "enum": ["webpage", "conversation", "document", "terminal", "email", "calendar", "task", "meeting", "voiceNote", "generic"]],
                                                  "description": "Structured kinds to include"],
                                "limit": ["type": "integer", "minimum": 1, "maximum": 20,
                                          "description": "Max contexts (default 3, max 20)"],
                             ]),
                             "required": [String]()]],
            ["name": "meeting_memory",
             "description": "List, semantically search, or read captured meeting and voice-note transcripts with app/time/thread filters and cursors.",
             "inputSchema": ["type": "object",
                             "properties": properties([
                                "action": ["type": "string", "enum": ["list", "get_context", "search"]],
                                "query": ["type": "string", "description": "Semantic query for search; legacy meeting ID for get_context"],
                                "meeting_id": ["type": "string", "description": "Exact recording ID for get_context"],
                                "thread_id": ["type": "string", "description": "Exact memory thread ID"],
                                "limit": ["type": "integer", "minimum": 1, "maximum": 20,
                                          "description": "Max list/search results (default 10, max 20)"],
                             ]),
                             "required": ["action"]]],
        ]
    }
}
public struct MaxMiTools: ToolProvider {
    let queries: MemoryQueries
    public init(queries: MemoryQueries) { self.queries = queries }

    public var toolDefinitions: [[String: Any]] { MaxMiToolsDefinitions.all }

    public func call(name: String, arguments: [String: Any]) async -> ToolResult {
        let options: RetrievalOptions
        switch RetrievalOptions.parse(arguments) {
        case .success(let parsed): options = parsed
        case .failure(let error):
            return ToolResult(text: error.localizedDescription, isError: true)
        }

        switch name {
        case "search_memory":
            guard let query = arguments["query"] as? String else {
                return ToolResult(text: "search_memory requires a 'query' string", isError: true)
            }
            return await queries.searchMemory(query: query, limit: Self.intArg(arguments["limit"]), options: options)
        case "list_active_threads":
            return queries.listActiveThreads(limit: Self.intArg(arguments["limit"]), options: options)
        case "get_latest_context":
            return queries.getLatestContext(limit: Self.intArg(arguments["limit"]), options: options)
        case "meeting_memory":
            guard let action = arguments["action"] as? String,
                  ["list", "get_context", "search"].contains(action) else {
                return ToolResult(text: "meeting_memory requires action: list | get_context | search", isError: true)
            }
            return await queries.meetingMemory(
                action: action,
                query: arguments["query"] as? String,
                meetingID: arguments["meeting_id"] as? String,
                limit: Self.intArg(arguments["limit"]),
                options: options
            )
        default:
            return ToolResult(text: "Unknown tool: \(name)", isError: true)
        }
    }

    private static func intArg(_ value: Any?) -> Int? {
        RetrievalOptions.intArg(value)
    }
}
