import XCTest
@testable import MaxMiUI
import MaxMiCore

@MainActor
final class TrayHomeViewModelTests: XCTestCase {
    func testRefreshLoadsStatus() async {
        let expected = TrayStatusDTO(state: .paused, title: "Capture paused", detail: "For 1 hour", captureCount: 42)
        let viewModel = TrayHomeViewModel(loadStatus: { expected }, search: { _ in [] })
        await viewModel.refresh()
        XCTAssertEqual(viewModel.status, expected)
    }

    func testSearchLoadsResultsAndClearsForEmptyQuery() async throws {
        let result = TraySearchResultDTO(
            id: "thread", appLabel: "Notes", title: "Plan", snippet: "Project Firefly",
            contentKind: .document, capturedAtMs: 1, matchKind: "context"
        )
        let viewModel = TrayHomeViewModel(
            loadStatus: { TrayStatusDTO(state: .capturing, title: "Ready", detail: "", captureCount: 1) },
            search: { query in query == "firefly" ? [result] : [] }
        )
        viewModel.query = "firefly"
        viewModel.scheduleSearch()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(viewModel.results, [result])
        XCTAssertFalse(viewModel.isSearching)

        viewModel.query = ""
        viewModel.scheduleSearch()
        XCTAssertTrue(viewModel.results.isEmpty)
        XCTAssertFalse(viewModel.isSearching)
    }

    func testLatestQueryWinsDuringDebounce() async throws {
        let viewModel = TrayHomeViewModel(
            loadStatus: { TrayStatusDTO(state: .capturing, title: "Ready", detail: "", captureCount: 0) },
            search: { query in
                [TraySearchResultDTO(id: query, appLabel: "A", title: query, snippet: query,
                                     contentKind: .generic, capturedAtMs: 1, matchKind: "context")]
            }
        )
        viewModel.query = "old"
        viewModel.scheduleSearch()
        viewModel.query = "new"
        viewModel.scheduleSearch()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(viewModel.results.map(\.id), ["new"])
    }
}

