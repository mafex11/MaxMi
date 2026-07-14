import XCTest
@testable import MaxMiUI

@MainActor
final class CapturePrivacyViewModelTests: XCTestCase {
    private var empty: CapturePrivacySnapshot {
        CapturePrivacySnapshot(
            isPaused: false, pauseDescription: "Capture is active", blockedDomains: [],
            blockedApps: [], pausedThreads: [], retentionDays: nil
        )
    }

    func testPauseActionPersistsAndRefreshes() async {
        let snapshot = empty
        nonisolated(unsafe) var choice: CapturePauseChoice?
        nonisolated(unsafe) var loads = 0
        let viewModel = CapturePrivacyViewModel(
            load: { loads += 1; return snapshot },
            onPause: { choice = $0 },
            onSetDomain: { _, _ in true },
            onResumeApp: { _ in }, onResumeThread: { _ in }, onSetRetention: { _ in }
        )
        await viewModel.setPause(.minutes(60))
        guard case .minutes(60) = choice else { return XCTFail("wrong pause choice") }
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(viewModel.message, "Capture pause updated")
    }

    func testDomainValidationAndRemoval() async {
        let snapshot = empty
        nonisolated(unsafe) var calls: [(String, Bool)] = []
        let viewModel = CapturePrivacyViewModel(
            load: { snapshot }, onPause: { _ in },
            onSetDomain: { domain, blocked in calls.append((domain, blocked)); return domain.contains(".") },
            onResumeApp: { _ in }, onResumeThread: { _ in }, onSetRetention: { _ in }
        )
        viewModel.newDomain = "invalid"
        await viewModel.addDomain()
        XCTAssertTrue(viewModel.message?.contains("valid domain") == true)
        viewModel.newDomain = "example.com"
        await viewModel.addDomain()
        await viewModel.removeDomain("example.com")
        XCTAssertEqual(calls.map(\.1), [true, true, false])
        XCTAssertEqual(viewModel.newDomain, "")
    }

    func testResumeAndRetentionActions() async {
        let snapshot = empty
        nonisolated(unsafe) var app: String?
        nonisolated(unsafe) var thread: String?
        nonisolated(unsafe) var retention: Int?
        let viewModel = CapturePrivacyViewModel(
            load: { snapshot }, onPause: { _ in }, onSetDomain: { _, _ in true },
            onResumeApp: { app = $0 }, onResumeThread: { thread = $0 },
            onSetRetention: { retention = $0 }
        )
        await viewModel.resumeApp("app")
        await viewModel.resumeThread("thread")
        await viewModel.setRetention(90)
        XCTAssertEqual(app, "app")
        XCTAssertEqual(thread, "thread")
        XCTAssertEqual(retention, 90)
    }
}
