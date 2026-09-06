import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class CaptureSchedulingPolicyTests: XCTestCase {
    func testActivationUsesFastIndependentLane() {
        XCTAssertEqual(CaptureSchedulingPolicy.activationDelayMs, 180)
    }

    func testEveryActivationGetsShortRetryWindow() {
        XCTAssertEqual(
            CaptureSchedulingPolicy.retryAttempts(
                trigger: .appActivated,
                needsAccessibilityWarmup: false
            ),
            3
        )
        XCTAssertEqual(
            CaptureSchedulingPolicy.retryAttempts(
                trigger: .accessibilityChanged,
                needsAccessibilityWarmup: false
            ),
            1
        )
        XCTAssertEqual(
            CaptureSchedulingPolicy.retryAttempts(
                trigger: .conversationChanged,
                needsAccessibilityWarmup: false
            ),
            3
        )
    }

    func testWarmupAppsRetryForNonActivationChanges() {
        XCTAssertEqual(
            CaptureSchedulingPolicy.retryAttempts(
                trigger: .webContentChanged,
                needsAccessibilityWarmup: true
            ),
            3
        )
    }

    func testRetryBackoffStaysWithinAppSwitchWindow() {
        XCTAssertEqual(CaptureSchedulingPolicy.retryDelayMs(attemptsRemaining: 3), 350)
        XCTAssertEqual(CaptureSchedulingPolicy.retryDelayMs(attemptsRemaining: 2), 900)
    }
}
