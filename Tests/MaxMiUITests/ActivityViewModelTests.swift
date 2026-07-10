import XCTest
@testable import MaxMiUI
import MaxMiCore

@MainActor
final class ActivityViewModelTests: XCTestCase {
    func testGroupsByDayNewestFirst() async {
        // Fixed "now" = 2026-01-15 10:00:00 UTC
        let now: EpochMs = 1_736_935_200_000

        // Today (2026-01-15): 2 sessions
        let s1 = TimelineSessionDTO(
            id: "s1",
            appLabel: "Cursor",
            summary: "Working on the parser",
            startedAtMs: now - 20 * 60_000, // 20m ago
            evidence: ["wrote parse logic"]
        )
        let s2 = TimelineSessionDTO(
            id: "s2",
            appLabel: "Chrome",
            summary: "Researching Swift concurrency",
            startedAtMs: now - 60 * 60_000, // 1h ago
            evidence: ["read documentation"]
        )

        // Yesterday (2026-01-14): 1 session
        let s3 = TimelineSessionDTO(
            id: "s3",
            appLabel: "Slack",
            summary: "Team sync",
            startedAtMs: now - 25 * 60 * 60_000, // 25h ago
            evidence: ["discussed roadmap"]
        )

        let load: @Sendable () async -> [TimelineSessionDTO] = {
            [s1, s2, s3]
        }
        let getNow: () -> Int64 = { now }

        let vm = ActivityViewModel(load: load, now: getNow)
        await vm.refresh()

        XCTAssertEqual(vm.groups.count, 2, "Should have 2 day groups")
        XCTAssertEqual(vm.groups[0].day, "Today")
        XCTAssertEqual(vm.groups[1].day, "Yesterday")

        // Today rows: newest first (s1, then s2)
        XCTAssertEqual(vm.groups[0].rows.count, 2)
        XCTAssertEqual(vm.groups[0].rows[0].id, "s1")
        XCTAssertEqual(vm.groups[0].rows[0].timeAgo, "20m ago")
        XCTAssertEqual(vm.groups[0].rows[1].id, "s2")
        XCTAssertEqual(vm.groups[0].rows[1].timeAgo, "1h ago")

        // Yesterday rows
        XCTAssertEqual(vm.groups[1].rows.count, 1)
        XCTAssertEqual(vm.groups[1].rows[0].id, "s3")
        XCTAssertEqual(vm.groups[1].rows[0].timeAgo, "25h ago")
    }

    func testNilSummaryRendersFallback() async {
        let now: EpochMs = 1_736_935_200_000
        let s1 = TimelineSessionDTO(
            id: "s1",
            appLabel: "Terminal",
            summary: nil,
            startedAtMs: now - 10 * 60_000,
            evidence: ["ran commands"]
        )

        let load: @Sendable () async -> [TimelineSessionDTO] = { [s1] }
        let getNow: () -> Int64 = { now }

        let vm = ActivityViewModel(load: load, now: getNow)
        await vm.refresh()

        XCTAssertEqual(vm.groups[0].rows[0].summary, "Activity in Terminal")
    }

    func testEvidencePreserved() async {
        let now: EpochMs = 1_736_935_200_000
        let evidence = ["line 1", "line 2", "line 3"]
        let s1 = TimelineSessionDTO(
            id: "s1",
            appLabel: "Xcode",
            summary: "Debugging",
            startedAtMs: now - 5 * 60_000,
            evidence: evidence
        )

        let load: @Sendable () async -> [TimelineSessionDTO] = { [s1] }
        let getNow: () -> Int64 = { now }

        let vm = ActivityViewModel(load: load, now: getNow)
        await vm.refresh()

        XCTAssertEqual(vm.groups[0].rows[0].evidence, evidence)
    }
}
