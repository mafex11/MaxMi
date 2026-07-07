import Foundation
import MaxMiCore
import MaxMiStore
import MaxMiRelay

// Lazy DB + tools: the server must start (and answer initialize/tools/list)
// even when the DB does not exist yet. Tool calls re-check per invocation.
final class LazyTools: ToolProvider, @unchecked Sendable {
    private var cached: MaxMiTools?
    private let lock = NSLock()

    var toolDefinitions: [[String: Any]] {
        // Schemas are static; build a throwaway provider only for definitions.
        staticDefinitions
    }
    private var staticDefinitions: [[String: Any]] {
        // mirrors MaxMiTools.toolDefinitions without needing a DB
        MaxMiToolsDefinitions.all
    }

    func call(name: String, arguments: [String: Any]) async -> ToolResult {
        let validNames = MaxMiToolsDefinitions.all.compactMap { $0["name"] as? String }
        guard validNames.contains(name) else {
            return ToolResult(text: "Unknown tool: \(name)", isError: true)
        }
        guard let tools = resolve() else {
            return ToolResult(text: MemoryQueries.noDBText, isError: false)
        }
        return await tools.call(name: name, arguments: arguments)
    }

    private func resolve() -> MaxMiTools? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let dbPath = ProcessInfo.processInfo.environment["MAXMI_DB_PATH"]
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MaxMi/maxmi.db").path
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        do {
            let db = try MaxMiDatabase(path: dbPath, readOnly: true)
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MaxMi")
            let config = EnvConfig.load(searchPaths: [
                appSupport.appendingPathComponent(".env"),
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env"),
            ])
            let queries = MemoryQueries(store: Store(db: db), relay: GeminiClient(config: config))
            let tools = MaxMiTools(queries: queries)
            if config.geminiAPIKey != nil {
                cached = tools
            }
            return tools
        } catch {
            logStderr("DB open failed: \(error)")
            return nil
        }
    }
}

let server = MCPServer(tools: LazyTools())
while let line = readLine(strippingNewline: true) {
    if let reply = await server.handle(line) {
        print(reply)
        fflush(stdout)
    }
}
