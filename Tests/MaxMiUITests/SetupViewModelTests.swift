import XCTest
@testable import MaxMiUI

@MainActor
final class SetupViewModelTests: XCTestCase {
    private var snapshot: SetupSnapshot {
        SetupSnapshot(
            permissions: [SetupStatusItem(id: "accessibility", title: "Accessibility", detail: "Required", state: .attention, actionTitle: "Grant")],
            encryption: SetupStatusItem(id: "encryption", title: "Encryption", detail: "Ready", state: .ready),
            mcp: SetupStatusItem(id: "mcp", title: "MCP", detail: "Connected", state: .ready)
        )
    }

    func testRefreshAndPermissionAction() async {
        let expected = snapshot
        nonisolated(unsafe) var permission: SetupPermission?
        let viewModel = SetupViewModel(
            load: { expected }, onPermission: { permission = $0 },
            onCopyMCPSetup: { _ in "copied" }
        )
        await viewModel.refresh()
        XCTAssertEqual(viewModel.snapshot, expected)
        await viewModel.handlePermission("accessibility")
        guard case .accessibility = permission else { return XCTFail("wrong permission") }
    }

    func testCopyStatus() {
        let expected = snapshot
        let viewModel = SetupViewModel(
            load: { expected }, onPermission: { _ in },
            onCopyMCPSetup: { target in
                switch target { case .claudeCode: return "code copied"; case .claudeDesktop: return "desktop copied" }
            }
        )
        viewModel.copyMCPSetup(.claudeCode)
        XCTAssertEqual(viewModel.message, "code copied")
    }
}
