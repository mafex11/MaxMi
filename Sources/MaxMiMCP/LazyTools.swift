import Foundation
import MaxMiCore
import MaxMiStore
import MaxMiRelay

// Lazy DB + tools: the server must start (and answer initialize/tools/list)
// even when the DB does not exist yet. Tool calls re-check per invocation.
public final class LazyTools: ToolProvider, @unchecked Sendable {
    private var cached: MaxMiTools?
    private let lock = NSLock()
    private var lockedOut = false
    private let keyProvider: () throws -> Data

    public init(keyProvider: @escaping () throws -> Data = KeychainKeyStore.getOrCreate) {
        self.keyProvider = keyProvider
    }

    public var toolDefinitions: [[String: Any]] {
        // Schemas are static; build a throwaway provider only for definitions.
        staticDefinitions
    }
    private var staticDefinitions: [[String: Any]] {
        // mirrors MaxMiTools.toolDefinitions without needing a DB
        MaxMiToolsDefinitions.all
    }

    public func call(name: String, arguments: [String: Any]) async -> ToolResult {
        let validNames = MaxMiToolsDefinitions.all.compactMap { $0["name"] as? String }
        guard validNames.contains(name) else {
            return ToolResult(text: "Unknown tool: \(name)", isError: true)
        }
        guard let tools = resolve() else {
            if lockedOut {
                return ToolResult(text: "Memory is locked — open the MaxMi app once to unlock.", isError: true)
            }
            return ToolResult(text: MemoryQueries.noDBText, isError: false)
        }
        return await tools.call(name: name, arguments: arguments)
    }

    private func resolve() -> MaxMiTools? {
        lock.lock(); defer { lock.unlock() }
        lockedOut = false                                  // reset on each attempt (recovery without restart)
        if let cached { return cached }
        let dbPath = ProcessInfo.processInfo.environment["MAXMI_DB_PATH"]
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MaxMi/maxmi.db").path
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        do {
            let db = try MaxMiDatabase(path: dbPath, readOnly: true)
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MaxMi")
            var config = EnvConfig.load(searchPaths: [
                appSupport.appendingPathComponent(".env"),
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env"),
            ])
            if config.relayURL != nil, config.relayToken == nil,
               let token = try? RelayTokenStore.read() {
                config = config.replacingRelayToken(token)
            }
            let keyData: Data
            do { keyData = try keyProvider() }
            catch {
                SafeLogger.shared.log(
                    .error,
                    subsystem: .mcp,
                    event: .mcpKeychainUnavailable,
                    error: error
                )
                lockedOut = true
                return nil
            }
            let relay = RelayClientFactory.make(config: config)
            let queries = MemoryQueries(
                store: Store(db: db, cipher: AESGCMFieldCipher(keyData: keyData)),
                relay: relay
            )
            let tools = MaxMiTools(queries: queries)
            if config.aiServiceConfigured {
                cached = tools
            }
            return tools
        } catch {
            SafeLogger.shared.log(
                .error,
                subsystem: .mcp,
                event: .mcpDatabaseOpenFailed,
                error: error
            )
            return nil
        }
    }
}
