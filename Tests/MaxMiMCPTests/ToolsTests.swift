import XCTest
@testable import MaxMiMCP
import MaxMiStore
import MaxMiCore

final class ToolsTests: XCTestCase {
    func makeTools() throws -> MaxMiTools {
        let store = Store(db: try MaxMiDatabase.inMemory(), cipher: AESGCMFieldCipher.testCipher)
        let q = MemoryQueries(store: store, relay: MockRelay(.failure(RelayError.notConfigured)))
        return MaxMiTools(queries: q)
    }
    func testDefinitionsExactNamesAndRequireds() throws {
        let defs = try makeTools().toolDefinitions
        XCTAssertEqual(defs.map { $0["name"] as? String },
                       ["search_memory", "list_active_threads", "get_latest_context", "meeting_memory"])
        let search = defs[0]["inputSchema"] as? [String: Any]
        XCTAssertEqual(search?["required"] as? [String], ["query"])
        let meeting = defs[3]["inputSchema"] as? [String: Any]
        XCTAssertEqual(meeting?["required"] as? [String], ["action"])
    }
    func testDispatchUnknownToolIsError() async throws {
        let r = try await makeTools().call(name: "nope", arguments: [:])
        XCTAssertTrue(r.isError)
    }
    func testDispatchMissingRequiredArgIsError() async throws {
        let r = try await makeTools().call(name: "search_memory", arguments: [:])
        XCTAssertTrue(r.isError)
    }
    func testMeetingDispatch() async throws {
        let r = try await makeTools().call(name: "meeting_memory", arguments: ["action": "list"])
        XCTAssertTrue(r.text.contains("No meetings captured yet"))
    }
    func testToolDefinitionsConsistency() throws {
        let instance = try makeTools().toolDefinitions.map { $0["name"] as? String }
        let staticDefs = MaxMiToolsDefinitions.all.map { $0["name"] as? String }
        XCTAssertEqual(instance, staticDefs, "MaxMiTools.toolDefinitions must match MaxMiToolsDefinitions.all")
    }
}
