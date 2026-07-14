import XCTest
@testable import MaxMiUI
import MaxMiCore

@MainActor
final class RecentCapturesViewModelTests: XCTestCase {
    func testRefreshShowsNewestCaptureFirst() async {
        let now: EpochMs = 2_000_000
        let captures = [
            RecentCaptureDTO(
                id: "old", appLabel: "Cursor", title: "Project",
                contentKind: .document, parserID: "GenericAXParser",
                capturedAtMs: now - 120_000, characterCount: 4_500, truncated: false
            ),
            RecentCaptureDTO(
                id: "new", appLabel: "Zen", title: "Article",
                contentKind: .webpage, parserID: "BrowserTabExtractor",
                capturedAtMs: now - 5_000, characterCount: 5_523, truncated: false,
                displaySummary: "You're reading about SQLite internals.", summaryStatus: "completed"
            ),
        ]
        let vm = RecentCapturesViewModel(load: { captures }, now: { now })

        await vm.refresh()

        XCTAssertEqual(vm.rows.map(\.id), ["new", "old"])
        XCTAssertEqual(vm.rows[0].timeAgo, "5s ago")
        XCTAssertTrue(vm.rows[0].detail.contains("5,523 characters"))
        XCTAssertTrue(vm.rows[0].detail.contains("BrowserTabExtractor"))
        XCTAssertEqual(vm.rows[0].summary, "You're reading about SQLite internals.")
    }

    func testMigratedContextHasUsefulFallback() async {
        let dto = RecentCaptureDTO(
            id: "legacy", appLabel: "Mail", title: nil,
            contentKind: .generic, parserID: "legacy",
            capturedAtMs: 1_000, characterCount: 0, truncated: false
        )
        let vm = RecentCapturesViewModel(load: { [dto] }, now: { 2_000 })

        await vm.refresh()

        XCTAssertEqual(vm.rows[0].sourceTitle, "Mail")
        XCTAssertTrue(vm.rows[0].detail.contains("Imported context"))
        XCTAssertEqual(vm.rows[0].summary, "Summarizing what you're doing…")
    }

    func testNewSourceReviewControlsCloudPolicy() async {
        let dto = RecentCaptureDTO(
            id: "new-source", appLabel: "New App", title: "Preview",
            contentKind: .document, parserID: "Parser", capturedAtMs: 1_000,
            characterCount: 100, truncated: false, cloudState: .pendingReview
        )
        nonisolated(unsafe) var decision: (String, Bool)?
        let vm = RecentCapturesViewModel(
            load: { [dto] }, now: { 2_000 },
            onSetCloudProcessing: { decision = ($0, $1) }
        )
        await vm.refresh()
        XCTAssertEqual(vm.rows[0].summary, "Review this new source before cloud processing.")
        XCTAssertEqual(vm.rows[0].cloudState, .pendingReview)
        await vm.setCloudProcessing(for: vm.rows[0], allowed: false)
        XCTAssertEqual(decision?.0, "New App")
        XCTAssertEqual(decision?.1, false)
    }
}
