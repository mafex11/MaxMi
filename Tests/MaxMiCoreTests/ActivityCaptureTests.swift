import XCTest
@testable import MaxMiCore

final class ActivityCaptureTests: XCTestCase {
    func testGenerationMatchEligible() {
        XCTAssertTrue(shouldRecordActivity(captureGeneration: 5, currentGeneration: 5, eligible: true))
    }

    func testGenerationMismatchDiscardsEvidence() {
        // Start under generation N, current advances to N+1 before completion
        XCTAssertFalse(shouldRecordActivity(captureGeneration: 5, currentGeneration: 6, eligible: true),
                       "Evidence must be discarded when generation advances during async capture")
    }

    func testIneligibleDiscardsEvidence() {
        // Even with generation match, ineligible apps don't record activity
        XCTAssertFalse(shouldRecordActivity(captureGeneration: 5, currentGeneration: 5, eligible: false),
                       "Evidence must be discarded for ineligible apps")
    }

    func testBothMismatchAndIneligible() {
        XCTAssertFalse(shouldRecordActivity(captureGeneration: 5, currentGeneration: 6, eligible: false))
    }
}
