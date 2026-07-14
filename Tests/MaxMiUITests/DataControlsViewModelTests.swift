import XCTest
@testable import MaxMiUI

@MainActor
final class DataControlsViewModelTests: XCTestCase {
    func testActionsPublishStatus() async {
        let viewModel = DataControlsViewModel(
            onExport: { "exported" },
            onApplyRetention: { "pruned" },
            onDeleteAll: { "deleted" }
        )
        await viewModel.export()
        XCTAssertEqual(viewModel.status, "exported")
        await viewModel.applyRetention()
        XCTAssertEqual(viewModel.status, "pruned")
        await viewModel.deleteAll()
        XCTAssertEqual(viewModel.status, "deleted")
        XCTAssertFalse(viewModel.isWorking)
    }

    func testFailureIsVisible() async {
        let viewModel = DataControlsViewModel(
            onExport: { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"]) },
            onApplyRetention: { "" }, onDeleteAll: { "" }
        )
        await viewModel.export()
        XCTAssertTrue(viewModel.status.contains("boom"))
        XCTAssertFalse(viewModel.isWorking)
    }
}

