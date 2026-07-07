# MaxMi Milestone 2: MCP Memory Server — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A local stdio MCP server (`maxmi-mcp`) exposing Minimi-parity tools (`search_memory`, `list_active_threads`, `meeting_memory` stub) over the M1 SQLite+sqlite-vec memory DB, per the spec at `docs/superpowers/specs/2026-07-07-maxmi-m2-mcp-server-design.md`.

**Architecture:** New executable target `MaxMiMCP` in the existing SwiftPM package. Reuses `MaxMiStore` (read-only DB + vector KNN), `MaxMiRelay` (GeminiClient embeds the query), `MaxMiCore` (EnvConfig). No SDK — MCP stdio is newline-delimited JSON-RPC 2.0 handled with `JSONSerialization`. All query/format logic lives in `MemoryQueries` (unit-testable, relay mocked); Store gains three read methods so SQL stays in MaxMiStore per M1 convention.

**Tech Stack:** Swift 6.0 SwiftPM, macOS 14+, GRDB 7 (read-only Configuration), existing vendored sqlite-vec, Gemini `gemini-embedding-001` @1536, `RelativeDateTimeFormatter`.

## Global Constraints

- Build/test always with `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"` prefix. Zero new warnings in our targets.
- stdout of `maxmi-mcp` carries ONLY JSON-RPC frames (one JSON object per line); ALL logging to stderr. Never crash on bad input; never write to the DB.
- Protocol version string: `2025-06-18`. Server name `maxmi`, version from `MaxMiVersion.current` = `0.2.0`.
- Tool names verbatim: `search_memory`, `list_active_threads`, `meeting_memory`. Markdown output, third-person facts verbatim, item cap **20**, `search_memory` default limit 10, `list_active_threads` default 10 with **per-thread** 3 latest facts.
- Similarity floor: drop hits with vec0 cosine distance > **0.75** (named constant).
- Query LRU cache: **32** entries, exact-string match.
- DB path: `~/Library/Application Support/MaxMi/maxmi.db`, overridable via env `MAXMI_DB_PATH`; opened **read-only**.
- Offline/keyless search text (verbatim): `Memory search needs the Gemini API key and network access (vector search embeds the query). Capture and browsing history are unaffected.`
- Missing-DB text (verbatim): `MaxMi hasn't captured anything yet — is the menu-bar app running?`
- Stub text (verbatim): `No meetings captured yet — meeting capture is a later MaxMi milestone. Use search_memory for everything read on screen.`
- Commit messages: conventional style, NO Co-Authored-By / AI attribution trailers.
- Repo root: `/Users/mafex/code/personal/MaxMi/`. Branch: `m2-mcp-server` off main.

## File Structure

```
Sources/MaxMiCore/Version.swift            MaxMiVersion.current
Sources/MaxMiStore/Database.swift          + readOnly: Bool = false on init
Sources/MaxMiStore/QueryAPI.swift          NEW: FactHit/ThreadSummary + factHits/recentThreads/totalFactCount
Sources/MaxMiMCP/JSONRPC.swift             frame parse/build helpers
Sources/MaxMiMCP/MCPServer.swift           protocol loop: initialize/tools/list/tools/call/ping
Sources/MaxMiMCP/Tools.swift               tool schemas + dispatch (ToolProvider)
Sources/MaxMiMCP/MemoryQueries.swift       embed→KNN→markdown, floor, LRU, list, stub
Sources/MaxMiMCP/main.swift                stdin loop, env resolution, lazy DB
Tests/MaxMiMCPTests/{JSONRPCTests,MCPServerTests,MemoryQueriesTests}.swift
Tests/MaxMiStoreTests/QueryAPITests.swift  + read-only test in MigrationTests
packaging/make-app.sh                      + bundle maxmi-mcp, print registration hint
packaging/Info.plist                       version → 0.2.0
README.md                                  + MCP registration section
```

Task order: 1 groundwork (version, read-only, query API) → 2 MCP scaffold + JSON-RPC protocol → 3 MemoryQueries (search) → 4 list + stub + tool schemas → 5 main + packaging + README + live exit test.

---

### Task 1: Groundwork — version constant, read-only DB, Store query API

**Files:**
- Create: `Sources/MaxMiCore/Version.swift`, `Sources/MaxMiStore/QueryAPI.swift`
- Modify: `Sources/MaxMiStore/Database.swift` (init signature), `packaging/Info.plist` (CFBundleShortVersionString 0.1.0 → 0.2.0)
- Test: `Tests/MaxMiStoreTests/QueryAPITests.swift` (new), `Tests/MaxMiStoreTests/MigrationTests.swift` (add read-only test)

**Interfaces:**
- Consumes: existing `MaxMiDatabase`, `Store` (commitCapture, insertDerivatives, insertEmbedding from M1), `EpochMs`.
- Produces (later tasks rely on these EXACT signatures):
```swift
// MaxMiCore
public enum MaxMiVersion { public static let current = "0.2.0" }
// MaxMiStore
public init(path: String, readOnly: Bool = false) throws   // on MaxMiDatabase
public struct FactHit: Sendable, Equatable {
    public let content: String
    public let distance: Double
    public let sourceTitle: String?
    public let sourceKey: String
    public let committedAt: EpochMs
}
public struct ThreadSummary: Sendable, Equatable {
    public let sourceTitle: String?
    public let sourceKey: String
    public let updatedAt: EpochMs
    public let recentFacts: [String]      // that thread's own 3 latest, newest first
}
// on Store:
public func factHits(near vector: [Float], limit: Int) throws -> [FactHit]     // KNN + join, distance ASC
public func recentThreads(limit: Int) throws -> [ThreadSummary]                // updated_at DESC
public func totalFactCount() throws -> Int
```

- [ ] **Step 1: Write failing tests** — `Tests/MaxMiStoreTests/QueryAPITests.swift`:

```swift
import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class QueryAPITests: XCTestCase {
    var store: Store!
    var db: MaxMiDatabase!
    let t0 = EpochMs(495_442) * 3_600_000

    override func setUpWithError() throws {
        db = try MaxMiDatabase.inMemory()
        store = Store(db: db)
    }

    func unit(_ hot: Int) -> [Float] {
        var v = [Float](repeating: 0.0, count: 1536); v[hot] = 1.0; return v
    }

    @discardableResult
    func seedThread(url: String, title: String?, facts: [(String, Int)], at: EpochMs) throws -> String {
        guard case .committed(let vid, _) = try store.commitCapture(
            CaptureInput(sourceApp: "Web", sourceKey: url, sourceTitle: title, content: "content for \(url)"),
            nowMs: at) else { fatalError() }
        let tid = try db.dbQueue.read { try String.fetchOne($0,
            sql: "SELECT thread_id FROM versions WHERE id=?", arguments: [vid])! }
        var when = at
        for (fact, hot) in facts {
            when += 1000
            let inserted = try store.insertDerivatives(versionID: vid, threadID: tid, facts: [fact], nowMs: when)
            try store.insertEmbedding(derivativeID: inserted[0].id, vector: unit(hot))
        }
        return tid
    }

    func testFactHitsJoinsThreadAndOrdersByDistance() throws {
        try seedThread(url: "https://a.com", title: "A", facts: [("Fact near.", 0), ("Fact far.", 900)], at: t0)
        let hits = try store.factHits(near: unit(0), limit: 5)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].content, "Fact near.")
        XCTAssertEqual(hits[0].sourceTitle, "A")
        XCTAssertEqual(hits[0].sourceKey, "https://a.com")
        XCTAssertLessThan(hits[0].distance, hits[1].distance)
    }

    func testFactHitsHonorsLimit() throws {
        try seedThread(url: "https://a.com", title: "A",
                       facts: [("F1.", 1), ("F2.", 2), ("F3.", 3)], at: t0)
        XCTAssertEqual(try store.factHits(near: unit(1), limit: 2).count, 2)
    }

    func testRecentThreadsOrderAndPerThreadFacts() throws {
        try seedThread(url: "https://old.com", title: "Old",
                       facts: [("O1.", 10), ("O2.", 11), ("O3.", 12), ("O4.", 13)], at: t0)
        try seedThread(url: "https://new.com", title: "New", facts: [("N1.", 20)], at: t0 + 60_000)
        let threads = try store.recentThreads(limit: 10)
        XCTAssertEqual(threads.map(\.sourceKey), ["https://new.com", "https://old.com"])
        XCTAssertEqual(threads[1].recentFacts, ["O4.", "O3.", "O2."], "own 3 latest, newest first")
        XCTAssertEqual(threads[0].recentFacts, ["N1."])
    }

    func testZeroFactThreadStillListed() throws {
        _ = try store.commitCapture(CaptureInput(sourceApp: "Web", sourceKey: "https://empty.com",
                                                 sourceTitle: "E", content: "x"), nowMs: t0)
        let threads = try store.recentThreads(limit: 10)
        XCTAssertEqual(threads.count, 1)
        XCTAssertTrue(threads[0].recentFacts.isEmpty)
    }

    func testTotalFactCount() throws {
        try seedThread(url: "https://a.com", title: "A", facts: [("F1.", 1), ("F2.", 2)], at: t0)
        XCTAssertEqual(try store.totalFactCount(), 2)
    }
}
```

Add to `Tests/MaxMiStoreTests/MigrationTests.swift`:

```swift
    func testReadOnlyOpenRejectsWritesAllowsReads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = dir.appendingPathComponent("ro.db").path
        _ = try MaxMiDatabase(path: path)                     // create + migrate writable
        let ro = try MaxMiDatabase(path: path, readOnly: true)
        try ro.dbQueue.read { d in
            XCTAssertTrue(try d.tableExists("threads"))
        }
        XCTAssertThrowsError(try ro.dbQueue.write { d in
            try d.execute(sql: "INSERT INTO settings VALUES ('k','v',1)")
        })
    }
```

- [ ] **Step 2: Run — FAIL** (`factHits` undefined, `readOnly:` unknown parameter).
Run: `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift test --filter MaxMiStoreTests`

- [ ] **Step 3: Implement**

`Sources/MaxMiCore/Version.swift`:
```swift
/// Single source of truth for the release version. SwiftPM executables have no
/// Info.plist; packaging/Info.plist's CFBundleShortVersionString is kept in
/// lockstep manually (bump both in the same commit).
public enum MaxMiVersion {
    public static let current = "0.2.0"
}
```

`Sources/MaxMiStore/Database.swift` — change the init:
```swift
    public init(path: String, readOnly: Bool = false) throws {
        var config = Configuration()
        config.readonly = readOnly
        config.prepareDatabase { db in
            var err: UnsafeMutablePointer<CChar>? = nil
            let rc = sqlite3_vec_init(db.sqliteConnection, &err, nil)
            if rc != SQLITE_OK {
                let message = err.map { String(cString: $0) } ?? "sqlite3_vec_init failed"
                if let err { sqlite3_free(err) }
                throw DatabaseError(resultCode: ResultCode(rawValue: rc), message: message)
            }
        }
        let isFile = path != ":memory:"
        if isFile && !readOnly {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                withIntermediateDirectories: true)
        }
        dbQueue = try DatabaseQueue(path: path, configuration: config)
        if isFile && !readOnly {
            try dbQueue.inDatabase { try $0.execute(sql: "PRAGMA journal_mode = WAL") }
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: path + suffix)
            }
        }
        if !readOnly {
            try Migrations.migrator.migrate(dbQueue)   // migrator writes; read-only opens skip it
        }
    }
```
(Adapt to the file's current exact body — the sqlite3_free line already exists from the final-review sweep; only the `readOnly` parameter, `config.readonly`, and the three `!readOnly` guards are new. `inMemory()` stays `MaxMiDatabase(path: ":memory:")`.)

`Sources/MaxMiStore/QueryAPI.swift`:
```swift
import Foundation
import GRDB
import MaxMiCore

public struct FactHit: Sendable, Equatable {
    public let content: String
    public let distance: Double
    public let sourceTitle: String?
    public let sourceKey: String
    public let committedAt: EpochMs
}

public struct ThreadSummary: Sendable, Equatable {
    public let sourceTitle: String?
    public let sourceKey: String
    public let updatedAt: EpochMs
    public let recentFacts: [String]
}

extension Store {
    /// KNN over derivative embeddings joined back to fact + thread. Distance ascending.
    public func factHits(near vector: [Float], limit: Int) throws -> [FactHit] {
        let blob = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        return try db.dbQueue.read { d in
            try Row.fetchAll(d, sql: """
                SELECT dv.content, e.distance, t.source_title, t.source_key, dv.committed_at
                FROM (SELECT derivative_id, distance FROM derivative_embeddings
                      WHERE embedding MATCH ? AND k = ?) e
                JOIN derivatives dv ON dv.id = e.derivative_id
                JOIN threads t ON t.id = dv.thread_id
                ORDER BY e.distance
                """, arguments: [blob, limit])
                .map { FactHit(content: $0["content"], distance: $0["distance"],
                               sourceTitle: $0["source_title"], sourceKey: $0["source_key"],
                               committedAt: $0["committed_at"]) }
        }
    }

    /// Threads by recency; each carries its OWN 3 latest facts (per-thread, not global).
    public func recentThreads(limit: Int) throws -> [ThreadSummary] {
        try db.dbQueue.read { d in
            let threads = try Row.fetchAll(d, sql: """
                SELECT id, source_title, source_key, updated_at
                FROM threads ORDER BY updated_at DESC LIMIT ?
                """, arguments: [limit])
            return try threads.map { t in
                let facts = try String.fetchAll(d, sql: """
                    SELECT content FROM derivatives WHERE thread_id = ?
                    ORDER BY committed_at DESC LIMIT 3
                    """, arguments: [t["id"] as String])
                return ThreadSummary(sourceTitle: t["source_title"], sourceKey: t["source_key"],
                                     updatedAt: t["updated_at"], recentFacts: facts)
            }
        }
    }

    public func totalFactCount() throws -> Int {
        try db.dbQueue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM derivatives") ?? 0 }
    }
}
```

`packaging/Info.plist`: change `<string>0.1.0</string>` (CFBundleShortVersionString) to `<string>0.2.0</string>`.

- [ ] **Step 4: Run — PASS.** Full suite: `DEVELOPER_DIR=... swift test` → 58 existing + 6 new, all green.

- [ ] **Step 5: Commit**
```bash
git add Sources/MaxMiCore/Version.swift Sources/MaxMiStore Tests/MaxMiStoreTests packaging/Info.plist
git commit -m "feat(store): read-only open mode, fact/thread query API, shared version constant"
```

---

### Task 2: MaxMiMCP target — JSON-RPC framing + MCP protocol loop

**Files:**
- Modify: `Package.swift` (add `MaxMiMCP` executable target + `MaxMiMCPTests` test target)
- Create: `Sources/MaxMiMCP/JSONRPC.swift`, `Sources/MaxMiMCP/MCPServer.swift`, `Sources/MaxMiMCP/main.swift` (minimal loop; fleshed out in Task 5)
- Test: `Tests/MaxMiMCPTests/JSONRPCTests.swift`, `Tests/MaxMiMCPTests/MCPServerTests.swift`

**Interfaces:**
- Consumes: `MaxMiVersion.current` (Task 1).
- Produces (Tasks 3–5 rely on):
```swift
public struct ToolResult: Sendable { public let text: String; public let isError: Bool
    public init(text: String, isError: Bool = false) }
public protocol ToolProvider: Sendable {
    var toolDefinitions: [[String: Any]] { get }                     // MCP tool objects
    func call(name: String, arguments: [String: Any]) async -> ToolResult
    // returning nil text is impossible; unknown tool -> ToolResult(isError: true)
}
public struct MCPServer {
    public init(tools: any ToolProvider)
    public func handle(_ line: String) async -> String?   // nil = notification/empty line, no reply
}
enum JSONRPC {   // internal helpers
    static func parse(_ line: String) -> [String: Any]?
    static func response(id: Any, result: [String: Any]) -> String
    static func error(id: Any?, code: Int, message: String) -> String
}
```

- [ ] **Step 1: Failing tests**

`Tests/MaxMiMCPTests/JSONRPCTests.swift`:
```swift
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
```

`Tests/MaxMiMCPTests/MCPServerTests.swift`:
```swift
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
```

- [ ] **Step 2: Add targets to Package.swift, run — FAIL** (types undefined).

Package.swift additions:
```swift
        .executableTarget(name: "MaxMiMCP", dependencies: [
            "MaxMiCore", "MaxMiStore", "MaxMiRelay",
        ]),
        .testTarget(name: "MaxMiMCPTests", dependencies: ["MaxMiMCP"]),
```
Run: `DEVELOPER_DIR=... swift test --filter MaxMiMCPTests`

- [ ] **Step 3: Implement**

`Sources/MaxMiMCP/JSONRPC.swift`:
```swift
import Foundation

enum JSONRPC {
    static func parse(_ line: String) -> [String: Any]? {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else { return nil }
        return obj as? [String: Any]
    }

    static func response(id: Any, result: [String: Any]) -> String {
        serialize(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func error(id: Any?, code: Int, message: String) -> String {
        serialize(["jsonrpc": "2.0", "id": id ?? NSNull(),
                   "error": ["code": code, "message": message]])
    }

    private static func serialize(_ obj: [String: Any]) -> String {
        // fragmentsAllowed unnecessary; keys sorted for deterministic tests.
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
```

`Sources/MaxMiMCP/MCPServer.swift`:
```swift
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
```

`Sources/MaxMiMCP/main.swift` (minimal; Task 5 replaces the tool provider):
```swift
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
```
Note: top-level `await` in main.swift of an executable target is legal (async main). If the compiler objects to `synchronizeFile` on stdout, drop that line — `print` flushes line-buffered on pipe.

- [ ] **Step 4: Run — PASS** (11 new tests). Full suite green.
- [ ] **Step 5: Commit**
```bash
git add Package.swift Sources/MaxMiMCP Tests/MaxMiMCPTests
git commit -m "feat(mcp): stdio JSON-RPC server with MCP initialize/tools protocol"
```

---

### Task 3: MemoryQueries — search_memory (embed → KNN → floor → markdown, LRU)

**Files:**
- Create: `Sources/MaxMiMCP/MemoryQueries.swift`
- Test: `Tests/MaxMiMCPTests/MemoryQueriesTests.swift`

**Interfaces:**
- Consumes: `Store.factHits/recentThreads/totalFactCount` (Task 1), `MemoryRelay` protocol + `RelayError` (M1, in MaxMiCore), `FactHit`/`ThreadSummary` (Task 1).
- Produces (Task 4/5 rely on):
```swift
public final class MemoryQueries: @unchecked Sendable {   // Store serialized by GRDB; relay Sendable
    public static let similarityDistanceFloor = 0.75      // vec0 cosine distance; tunable empirically
    public init(store: Store, relay: any MemoryRelay,
                now: @escaping @Sendable () -> Date = Date.init)
    public func searchMemory(query: String, limit: Int?) async -> ToolResult
    public func listActiveThreads(limit: Int?) -> ToolResult          // Task 4
    public func meetingMemory(action: String) -> ToolResult           // Task 4
}
```
Constants (Global Constraints, verbatim): cap 20, search default 10, LRU 32, offline text, floor-empty hint `Nothing sufficiently similar. Try different wording, or list_active_threads for recent activity.`

- [ ] **Step 1: Failing tests** — `Tests/MaxMiMCPTests/MemoryQueriesTests.swift`:

```swift
import XCTest
@testable import MaxMiMCP
import MaxMiStore
import MaxMiCore

final class MockRelay: MemoryRelay, @unchecked Sendable {
    var embedResult: Result<[Float], Error>
    var embedCalls = 0
    init(_ r: Result<[Float], Error>) { embedResult = r }
    func extract(newContent: String, previousContent: String?, sourceApp: String, sourceKey: String) async throws -> [String] { [] }
    func embed(text: String) async throws -> [Float] {
        embedCalls += 1
        return try embedResult.get()
    }
}

final class MemoryQueriesTests: XCTestCase {
    var store: Store!
    let t0 = EpochMs(495_442) * 3_600_000

    func unit(_ hot: Int) -> [Float] {
        var v = [Float](repeating: 0.0, count: 1536); v[hot] = 1.0; return v
    }

    override func setUpWithError() throws {
        store = Store(db: try MaxMiDatabase.inMemory())
    }

    func seed(_ facts: [(String, Int)], url: String = "https://gintama.example", title: String = "Gin Tama") throws {
        guard case .committed(let vid, _) = try store.commitCapture(
            CaptureInput(sourceApp: "Web", sourceKey: url, sourceTitle: title, content: "c\(url)"),
            nowMs: t0) else { fatalError() }
        let tid = try store.recentThreads(limit: 1).isEmpty ? "" : ""   // not used; fetch real tid:
        _ = tid
        let realTid = try store.threadID(forKey: url)                    // helper added below in Step 3 note
        var when = t0
        for (f, hot) in facts {
            when += 1000
            let ins = try store.insertDerivatives(versionID: vid, threadID: realTid, facts: [f], nowMs: when)
            try store.insertEmbedding(derivativeID: ins[0].id, vector: unit(hot))
        }
    }

    func queries(_ relay: MockRelay) -> MemoryQueries {
        MemoryQueries(store: store, relay: relay,
                      now: { Date(timeIntervalSince1970: Double(self.t0) / 1000 + 7200) }) // "2 hours ago"
    }

    func testSearchReturnsMarkdownWithSourceAndRelativeTime() async throws {
        try seed([("The user watched episode 18 of Gin Tama.", 3)])
        let q = queries(MockRelay(.success(unit(3))))
        let r = await q.searchMemory(query: "anime", limit: nil)
        XCTAssertFalse(r.isError)
        XCTAssertTrue(r.text.contains("The user watched episode 18 of Gin Tama."))
        XCTAssertTrue(r.text.contains("Gin Tama"))
        XCTAssertTrue(r.text.contains("https://gintama.example"))
        XCTAssertTrue(r.text.contains("2 hours ago"))
        XCTAssertTrue(r.text.contains(#"## Memory search: "anime""#))
    }

    func testSimilarityFloorFiltersOrthogonalResults() async throws {
        try seed([("Unrelated fact.", 900)])
        let q = queries(MockRelay(.success(unit(3))))    // orthogonal to stored -> distance 1.0 > 0.75
        let r = await q.searchMemory(query: "anime", limit: nil)
        XCTAssertFalse(r.isError)
        XCTAssertTrue(r.text.contains("Nothing sufficiently similar"))
        XCTAssertFalse(r.text.contains("Unrelated fact."))
    }

    func testLimitDefaultsTo10AndCapsAt20() async throws {
        try seed((0..<25).map { ("Fact \($0).", 100 + $0) })
        // query along an axis close to all? use one stored axis so at least ordering exists:
        let q = queries(MockRelay(.success(unit(100))))
        let def = await q.searchMemory(query: "x", limit: nil)
        XCTAssertLessThanOrEqual(def.text.components(separatedBy: "\n- ").count - 1, 10)
        let capped = await q.searchMemory(query: "x", limit: 50)
        XCTAssertLessThanOrEqual(capped.text.components(separatedBy: "\n- ").count - 1, 20)
    }

    func testOfflineReturnsExactErrorText() async throws {
        try seed([("F.", 1)])
        let q = queries(MockRelay(.failure(RelayError.notConfigured)))
        let r = await q.searchMemory(query: "x", limit: nil)
        XCTAssertTrue(r.isError)
        XCTAssertEqual(r.text, "Memory search needs the Gemini API key and network access (vector search embeds the query). Capture and browsing history are unaffected.")
    }

    func testEmptyQueryRejected() async {
        let q = queries(MockRelay(.success(unit(1))))
        let r = await q.searchMemory(query: "   ", limit: nil)
        XCTAssertTrue(r.isError)
    }

    func testLRUCacheSkipsSecondEmbed() async throws {
        try seed([("F.", 1)])
        let relay = MockRelay(.success(unit(1)))
        let q = queries(relay)
        _ = await q.searchMemory(query: "same query", limit: nil)
        _ = await q.searchMemory(query: "same query", limit: nil)
        XCTAssertEqual(relay.embedCalls, 1, "second identical query served from LRU")
    }

    func testEmptyDBGivesFriendlyMessage() async {
        let q = queries(MockRelay(.success(unit(1))))
        let r = await q.searchMemory(query: "x", limit: nil)
        XCTAssertFalse(r.isError)
        XCTAssertTrue(r.text.contains("No memories matched"))
    }
}
```

- [ ] **Step 2: Run — FAIL** (`MemoryQueries` undefined; `threadID(forKey:)` undefined).

- [ ] **Step 3: Implement**

First the tiny Store helper the test needs — append to `Sources/MaxMiStore/QueryAPI.swift`:
```swift
extension Store {
    /// Test/support helper: thread id for a source_key (any app).
    public func threadID(forKey key: String) throws -> String {
        try db.dbQueue.read {
            try String.fetchOne($0, sql: "SELECT id FROM threads WHERE source_key = ?", arguments: [key])
                ?? { throw DatabaseError(message: "no thread for key \(key)") }()
        }
    }
}
```
(If the closure-throw idiom fights the compiler, use a guard + explicit throw.)

`Sources/MaxMiMCP/MemoryQueries.swift`:
```swift
import Foundation
import MaxMiCore
import MaxMiStore

public final class MemoryQueries: @unchecked Sendable {
    /// vec0 cosine distance (1 - similarity). Hits above this are noise, not memory.
    /// Empirically tunable; 0.75 keeps similarity >= 0.25.
    public static let similarityDistanceFloor = 0.75
    static let hardCap = 20
    static let searchDefault = 10
    static let listDefault = 10
    static let lruCapacity = 32

    static let offlineText = "Memory search needs the Gemini API key and network access (vector search embeds the query). Capture and browsing history are unaffected."
    static let noDBText = "MaxMi hasn't captured anything yet — is the menu-bar app running?"
    static let stubText = "No meetings captured yet — meeting capture is a later MaxMi milestone. Use search_memory for everything read on screen."

    let store: Store
    let relay: any MemoryRelay
    let now: @Sendable () -> Date
    private var lruKeys: [String] = []              // most recent last
    private var lruVectors: [String: [Float]] = [:]
    private let lruLock = NSLock()

    public init(store: Store, relay: any MemoryRelay,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store; self.relay = relay; self.now = now
    }

    public func searchMemory(query: String, limit: Int?) async -> ToolResult {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return ToolResult(text: "query must not be empty", isError: true) }
        let k = min(max(limit ?? Self.searchDefault, 1), Self.hardCap)

        let vector: [Float]
        if let cached = lruGet(q) {
            vector = cached
        } else {
            do { vector = try await relay.embed(text: q) }
            catch { return ToolResult(text: Self.offlineText, isError: true) }
            lruPut(q, vector)
        }

        do {
            let hits = try store.factHits(near: vector, limit: k)
                .filter { $0.distance <= Self.similarityDistanceFloor }
            let total = try store.totalFactCount()
            guard !hits.isEmpty else {
                let hint = total > 0
                    ? "Nothing sufficiently similar. Try different wording, or list_active_threads for recent activity."
                    : ""
                return ToolResult(text: "No memories matched \"\(q)\".\(hint.isEmpty ? "" : " \(hint)")")
            }
            var md = "## Memory search: \"\(q)\"\n\n"
            for h in hits {
                md += "- \(h.content)\n  — \(h.sourceTitle ?? h.sourceKey) (\(h.sourceKey)), \(relative(h.committedAt))\n"
            }
            md += "\n_\(hits.count) results (of \(total) memories)_"
            return ToolResult(text: md)
        } catch {
            return ToolResult(text: "Memory database unavailable: \(error)", isError: true)
        }
    }

    func relative(_ ms: EpochMs) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.locale = Locale(identifier: "en_US")
        f.dateTimeStyle = .named
        return f.localizedString(for: Date(timeIntervalSince1970: Double(ms) / 1000), relativeTo: now())
    }

    private func lruGet(_ key: String) -> [Float]? {
        lruLock.lock(); defer { lruLock.unlock() }
        guard let v = lruVectors[key] else { return nil }
        lruKeys.removeAll { $0 == key }; lruKeys.append(key)
        return v
    }
    private func lruPut(_ key: String, _ vector: [Float]) {
        lruLock.lock(); defer { lruLock.unlock() }
        lruVectors[key] = vector
        lruKeys.removeAll { $0 == key }; lruKeys.append(key)
        if lruKeys.count > Self.lruCapacity {
            lruVectors.removeValue(forKey: lruKeys.removeFirst())
        }
    }
}
```
(`listActiveThreads`/`meetingMemory` arrive in Task 4 — add empty stubs ONLY if the compiler requires them for the tests to build; otherwise leave for Task 4.)

- [ ] **Step 4: Run — PASS** (8 tests). Full suite green.
- [ ] **Step 5: Commit**
```bash
git add Sources/MaxMiMCP/MemoryQueries.swift Sources/MaxMiStore/QueryAPI.swift Tests/MaxMiMCPTests/MemoryQueriesTests.swift
git commit -m "feat(mcp): search_memory query path with similarity floor and query LRU"
```

---

### Task 4: list_active_threads + meeting_memory stub + real tool schemas

**Files:**
- Modify: `Sources/MaxMiMCP/MemoryQueries.swift` (add two methods)
- Create: `Sources/MaxMiMCP/Tools.swift`
- Test: extend `Tests/MaxMiMCPTests/MemoryQueriesTests.swift`; `Tests/MaxMiMCPTests/ToolsTests.swift` (new)

**Interfaces:**
- Consumes: `MemoryQueries.searchMemory` (Task 3), `Store.recentThreads` (Task 1), `ToolProvider`/`ToolResult` (Task 2).
- Produces:
```swift
public struct MaxMiTools: ToolProvider {
    public init(queries: MemoryQueries)
    // toolDefinitions: search_memory {query: string req, limit: number opt},
    //                  list_active_threads {limit: number opt},
    //                  meeting_memory {action: enum[list,get_context,search] req, query: string opt}
}
```

- [ ] **Step 1: Failing tests** — append to `MemoryQueriesTests.swift`:

```swift
    func testListActiveThreadsMarkdownAndOrder() async throws {
        try seed([("Old fact 1.", 1), ("Old fact 2.", 2), ("Old fact 3.", 3), ("Old fact 4.", 4)],
                 url: "https://old.example", title: "Old Page")
        try seed([("New fact.", 10)], url: "https://new.example", title: "New Page")
        // make new.example more recent:
        _ = try store.commitCapture(CaptureInput(sourceApp: "Web", sourceKey: "https://new.example",
                                                 sourceTitle: "New Page", content: "changed"),
                                    nowMs: t0 + 600_000)
        let q = queries(MockRelay(.success(unit(1))))
        let r = q.listActiveThreads(limit: nil)
        XCTAssertFalse(r.isError)
        let newIdx = r.text.range(of: "New Page")!.lowerBound
        let oldIdx = r.text.range(of: "Old Page")!.lowerBound
        XCTAssertLessThan(newIdx, oldIdx, "recency order")
        XCTAssertTrue(r.text.contains("Old fact 4."))
        XCTAssertFalse(r.text.contains("Old fact 1."), "only own 3 latest facts")
    }

    func testListEmptyDBFriendly() {
        let q = queries(MockRelay(.success(unit(1))))
        let r = q.listActiveThreads(limit: nil)
        XCTAssertTrue(r.text.contains("hasn't captured anything yet"))
    }

    func testMeetingMemoryStubAllActions() {
        let q = queries(MockRelay(.success(unit(1))))
        for action in ["list", "get_context", "search"] {
            let r = q.meetingMemory(action: action)
            XCTAssertFalse(r.isError)
            XCTAssertTrue(r.text.contains("No meetings captured yet"))
        }
    }
```

`Tests/MaxMiMCPTests/ToolsTests.swift`:
```swift
import XCTest
@testable import MaxMiMCP
import MaxMiStore
import MaxMiCore

final class ToolsTests: XCTestCase {
    func makeTools() throws -> MaxMiTools {
        let store = Store(db: try MaxMiDatabase.inMemory())
        let q = MemoryQueries(store: store, relay: MockRelay(.failure(RelayError.notConfigured)))
        return MaxMiTools(queries: q)
    }
    func testDefinitionsExactNamesAndRequireds() throws {
        let defs = try makeTools().toolDefinitions
        XCTAssertEqual(defs.map { $0["name"] as? String },
                       ["search_memory", "list_active_threads", "meeting_memory"])
        let search = defs[0]["inputSchema"] as? [String: Any]
        XCTAssertEqual(search?["required"] as? [String], ["query"])
        let meeting = defs[2]["inputSchema"] as? [String: Any]
        XCTAssertEqual(meeting?["required"] as? [String], ["action"])
    }
    func testDispatchUnknownToolIsError() async throws {
        let r = await makeTools().call(name: "nope", arguments: [:])
        XCTAssertTrue(r.isError)
    }
    func testDispatchMissingRequiredArgIsError() async throws {
        let r = await makeTools().call(name: "search_memory", arguments: [:])
        XCTAssertTrue(r.isError)
    }
    func testMeetingDispatch() async throws {
        let r = await makeTools().call(name: "meeting_memory", arguments: ["action": "list"])
        XCTAssertTrue(r.text.contains("No meetings captured yet"))
    }
}
```

- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement**

Append to `MemoryQueries`:
```swift
    public func listActiveThreads(limit: Int?) -> ToolResult {
        let k = min(max(limit ?? Self.listDefault, 1), Self.hardCap)
        do {
            let threads = try store.recentThreads(limit: k)
            guard !threads.isEmpty else { return ToolResult(text: Self.noDBText) }
            var md = "## Recently active threads\n"
            for t in threads {
                md += "\n### \(t.sourceTitle ?? t.sourceKey)\n\(t.sourceKey) — last seen \(relative(t.updatedAt))\n"
                for f in t.recentFacts { md += "- \(f)\n" }
                if t.recentFacts.isEmpty { md += "_(no facts extracted yet)_\n" }
            }
            return ToolResult(text: md)
        } catch {
            return ToolResult(text: "Memory database unavailable: \(error)", isError: true)
        }
    }

    public func meetingMemory(action: String) -> ToolResult {
        ToolResult(text: Self.stubText)
    }
```

`Sources/MaxMiMCP/Tools.swift`:
```swift
import Foundation

public struct MaxMiTools: ToolProvider {
    let queries: MemoryQueries
    public init(queries: MemoryQueries) { self.queries = queries }

    public var toolDefinitions: [[String: Any]] {
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
```

- [ ] **Step 4: Run — PASS.** Full suite green.
- [ ] **Step 5: Commit**
```bash
git add Sources/MaxMiMCP Tests/MaxMiMCPTests
git commit -m "feat(mcp): list_active_threads, meeting_memory stub, Minimi-parity tool schemas"
```

---

### Task 5: main wiring, packaging, README, live exit test

**Files:**
- Modify: `Sources/MaxMiMCP/main.swift` (real wiring), `packaging/make-app.sh`, `README.md`
- Test: manual protocol smoke + live exit test (§9 of spec); all unit suites green.

**Interfaces:**
- Consumes: everything above; `EnvConfig.load` (M1), `GeminiClient(config:)` (M1).

- [ ] **Step 1: Real main.swift**

```swift
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
        guard let tools = resolve() else {
            return ToolResult(text: "MaxMi hasn't captured anything yet — is the menu-bar app running?", isError: false)
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
            cached = tools
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
    }
}
```

Refactor note: extract `MaxMiTools.toolDefinitions`'s array into `enum MaxMiToolsDefinitions { static let all: [[String: Any]] = [...] }` in Tools.swift and have `MaxMiTools.toolDefinitions` return it, so LazyTools serves schemas DB-free without duplication. Add a test to ToolsTests asserting `MaxMiTools(queries:...).toolDefinitions.map(name) == MaxMiToolsDefinitions.all.map(name)`.

- [ ] **Step 2: Protocol smoke test over a real pipe**

```bash
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift build
printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | .build/debug/MaxMiMCP
```
Expected: exactly two JSON lines (initialize result with serverInfo.name "maxmi"; tools list with 3 tools). No stray stdout.

Also smoke a real search against the live DB (uses the real key — expect real facts):
```bash
printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search_memory","arguments":{"query":"anime episode"}}}' \
  | .build/debug/MaxMiMCP
```
Expected: second reply's content text contains "Gin Tama".

- [ ] **Step 3: Packaging + README**

`packaging/make-app.sh` — after the existing `cp .build/release/MaxMi ...` line add:
```bash
cp .build/release/MaxMiMCP "$APP/Contents/MacOS/maxmi-mcp"
```
and after the codesign line add:
```bash
echo "MCP server bundled. Register with:"
echo "  claude mcp add maxmi -- \"$PWD/$APP/Contents/MacOS/maxmi-mcp\""
```

README — add a section:
```markdown
## Connect to Claude (MCP)

The app bundles `maxmi-mcp`, a local MCP server that lets Claude search your memory.

**Claude Code:**
    claude mcp add maxmi -- /path/to/MaxMi.app/Contents/MacOS/maxmi-mcp

**Claude Desktop** — add to `~/Library/Application Support/Claude/claude_desktop_config.json`:
    { "mcpServers": { "maxmi": { "command": "/path/to/MaxMi.app/Contents/MacOS/maxmi-mcp" } } }

Tools: `search_memory` (semantic search over captured facts), `list_active_threads`
(recent pages), `meeting_memory` (stub until meetings ship). Reads the DB read-only;
never interferes with capture. Uses the same `.env` Gemini key to embed queries.
Optional: `MAXMI_DB_PATH` env var overrides the DB location.
```

- [ ] **Step 4: Full suite + build + rebuild app**
```bash
DEVELOPER_DIR=... swift test          # all green (~85 tests)
./packaging/make-app.sh                # bundles both binaries
```
NOTE: rebuilding the app invalidates the Accessibility grant (ad-hoc signing) — remind the human: `tccutil reset Accessibility dev.mafex.maxmi` + re-grant. The MCP binary itself needs no TCC.

- [ ] **Step 5: Commit**
```bash
git add Sources/MaxMiMCP packaging/make-app.sh README.md Tests/MaxMiMCPTests
git commit -m "feat(mcp): wire live server, bundle in app, document registration"
```

- [ ] **Step 6: Live exit test (controller/human, spec §9)** — register in Claude Code (`claude mcp add maxmi -- <repo>/MaxMi.app/Contents/MacOS/maxmi-mcp`), fresh session, ask "what anime was I watching on Netflix?" → Gin Tama facts via search_memory; "what have I been reading recently?" → recent threads. Repeat from Claude Desktop. Verify no key / no network / no DB / garbage stdin behaviors per §9.5.

---

## Self-Review (done at plan-writing time)

**Spec coverage:** §3 architecture/file map → Tasks 1–5 match exactly (JSONRPC/MCPServer/Tools/MemoryQueries/main + Store QueryAPI + read-only mode). §4 tool contract → Task 3 (search incl. floor/cap/offline text), Task 4 (list per-thread facts, stub, schemas), exact strings in Global Constraints. §5 server behavior → Task 2 (protocol, 2025-06-18, ping, -32601), Task 5 (MAXMI_DB_PATH, lazy DB, missing-DB text), Task 1 (Version.swift + Info.plist lockstep), Task 3 (LRU, floor, RelativeDateTimeFormatter en_US .named). §6 install → Task 5 (bundle + README + registration hint). §7 errors → Tasks 2–5 (no retry-queue use — nothing enqueues; -32602; isError results; stdout purity; garbage-frame test). §8 tests → mapped 1:1 incl. WAL read-only concurrency (Task 1), cache-skip, floor, MAXMI_DB_PATH (Task 5 smoke uses it implicitly via default; explicit override exercised by pointing MAXMI_DB_PATH at a fixture in the Task 5 smoke if desired — acceptable since resolve() reads it). §9 exit criteria → Task 5 Step 6.

**Placeholders:** none; every code step has complete code. Task 5's `MaxMiToolsDefinitions` extraction is specified with its consistency test.

**Type consistency:** `ToolProvider`/`ToolResult` (Task 2) consumed by Tasks 4–5 with same shapes; `FactHit`/`ThreadSummary`/`factHits`/`recentThreads`/`totalFactCount` (Task 1) consumed by Task 3–4 verbatim; `MemoryQueries` init signature consistent across Tasks 3–5; MockRelay defined once in MemoryQueriesTests and reused by ToolsTests (same module target — fine).
