import XCTest
@testable import MaxMiUI

@MainActor
final class SetupViewModelTests: XCTestCase {
    private var snapshot: SetupSnapshot {
        SetupSnapshot(
            permissions: [SetupStatusItem(id: "accessibility", title: "Accessibility", detail: "Required", state: .attention, actionTitle: "Grant")],
            apiKeyConfigured: false,
            encryption: SetupStatusItem(id: "encryption", title: "Encryption", detail: "Ready", state: .ready),
            mcp: SetupStatusItem(id: "mcp", title: "MCP", detail: "Connected", state: .ready)
        )
    }

    func testRefreshAndPermissionAction() async {
        let expected = snapshot
        nonisolated(unsafe) var permission: SetupPermission?
        let viewModel = SetupViewModel(
            load: { expected }, onPermission: { permission = $0 },
            onSaveAPIKey: { _ in "saved" }, onCopyMCPSetup: { _ in "copied" }
        )
        await viewModel.refresh()
        XCTAssertEqual(viewModel.snapshot, expected)
        await viewModel.handlePermission("accessibility")
        guard case .accessibility = permission else { return XCTFail("wrong permission") }
    }

    func testAPIKeyValidationClearsSecretAndRefreshes() async {
        let expected = snapshot
        nonisolated(unsafe) var savedKey: String?
        let viewModel = SetupViewModel(
            load: { expected }, onPermission: { _ in },
            onSaveAPIKey: { savedKey = $0; return "validated" }, onCopyMCPSetup: { _ in "copied" }
        )
        viewModel.apiKey = "  secret-key  "
        await viewModel.saveAPIKey()
        XCTAssertEqual(savedKey, "secret-key")
        XCTAssertEqual(viewModel.apiKey, "")
        XCTAssertEqual(viewModel.message, "validated")
        XCTAssertFalse(viewModel.isWorking)
    }

    func testEmptyKeyAndCopyStatus() async {
        let expected = snapshot
        let viewModel = SetupViewModel(
            load: { expected }, onPermission: { _ in },
            onSaveAPIKey: { _ in "saved" }, onCopyMCPSetup: { target in
                switch target { case .claudeCode: return "code copied"; case .claudeDesktop: return "desktop copied" }
            }
        )
        await viewModel.saveAPIKey()
        XCTAssertTrue(viewModel.message.contains("Enter"))
        viewModel.copyMCPSetup(.claudeCode)
        XCTAssertEqual(viewModel.message, "code copied")
    }
}

