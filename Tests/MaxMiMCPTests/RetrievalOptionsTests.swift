import XCTest
@testable import MaxMiMCP
import MaxMiCore

final class RetrievalOptionsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testLookbackUsesStableAsOfAndTimezone() throws {
        let resolved = try RetrievalOptions(lookbackMinutes: 90, timezone: "Asia/Kolkata")
            .resolved(tool: "get_latest_context", now: now)
        XCTAssertEqual(resolved.asOfMs, 1_800_000_000_000)
        XCTAssertEqual(resolved.filter.startAtMs, 1_800_000_000_000 - 90 * 60_000)
        XCTAssertEqual(resolved.filter.endAtMs, resolved.asOfMs)
        XCTAssertEqual(resolved.timezone.identifier, "Asia/Kolkata")
    }

    func testExplicitRangeParsesRFC3339() throws {
        let resolved = try RetrievalOptions(
            startTime: "2027-01-15T07:00:00Z",
            endTime: "2027-01-15T08:00:00Z"
        ).resolved(tool: "list_active_threads", now: now)
        XCTAssertEqual(resolved.filter.startAtMs, 1_799_996_400_000)
        XCTAssertEqual(resolved.filter.endAtMs, 1_800_000_000_000)
    }

    func testLookbackAndExplicitRangeConflict() {
        XCTAssertThrowsError(try RetrievalOptions(lookbackMinutes: 60, startTime: "2027-01-15T07:00:00Z")
            .resolved(tool: "search_memory", query: "x", now: now))
    }

    func testCursorKeepsAsOfAndOffset() throws {
        let first = try RetrievalOptions(sourceApps: ["Slack"])
            .resolved(tool: "list_active_threads", now: now)
        let cursor = first.nextCursor(consumed: 4)
        let second = try RetrievalOptions(sourceApps: ["Slack"], cursor: cursor)
            .resolved(tool: "list_active_threads", now: now.addingTimeInterval(10_000))
        XCTAssertEqual(second.asOfMs, first.asOfMs)
        XCTAssertEqual(second.offset, 4)
    }

    func testCursorRejectsChangedScopeOrTool() throws {
        let first = try RetrievalOptions(sourceApps: ["Slack"])
            .resolved(tool: "list_active_threads", now: now)
        let cursor = first.nextCursor(consumed: 1)
        XCTAssertThrowsError(try RetrievalOptions(sourceApps: ["Mail"], cursor: cursor)
            .resolved(tool: "list_active_threads", now: now))
        XCTAssertThrowsError(try RetrievalOptions(sourceApps: ["Slack"], cursor: cursor)
            .resolved(tool: "get_latest_context", now: now))
    }

    func testMalformedCursorAndTimezoneReturnInputErrors() {
        XCTAssertThrowsError(try RetrievalOptions(cursor: "not-base64")
            .resolved(tool: "list_active_threads", now: now))
        XCTAssertThrowsError(try RetrievalOptions(timezone: "Mars/Olympus")
            .resolved(tool: "list_active_threads", now: now))
    }

    func testUnknownStructuredKindIsRejectedDuringParsing() {
        let result = RetrievalOptions.parse(["content_kinds": ["task", "bogus"]])
        guard case .failure(let error) = result else { return XCTFail("expected invalid kind") }
        XCTAssertTrue(error.localizedDescription.contains("unknown value"))
    }
}
