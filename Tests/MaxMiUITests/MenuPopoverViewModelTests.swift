import XCTest
@testable import MaxMiUI

@MainActor
final class MenuPopoverViewModelTests: XCTestCase {
    func testNavigatesBetweenHomeAndSettings() {
        let viewModel = MenuPopoverViewModel()

        XCTAssertEqual(viewModel.page, .home)

        viewModel.showSettings()
        XCTAssertEqual(viewModel.page, .settings)

        viewModel.showHome()
        XCTAssertEqual(viewModel.page, .home)
    }
}
