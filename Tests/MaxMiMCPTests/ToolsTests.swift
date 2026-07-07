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
}
