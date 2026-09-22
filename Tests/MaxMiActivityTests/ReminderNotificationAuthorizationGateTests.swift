import XCTest
@testable import MaxMiActivity

@MainActor
final class ReminderNotificationAuthorizationGateTests: XCTestCase {
    func testDeniedAuthorizationOnlyRequestsOnceAndNeverAllowsPosting() async {
        let requester = DeniedAuthorizationRequester()
        let gate = ReminderNotificationAuthorizationGate()

        let firstAttempt = await gate.allowsPosting(using: requester)
        let secondAttempt = await gate.allowsPosting(using: requester)

        XCTAssertFalse(firstAttempt)
        XCTAssertFalse(secondAttempt)
        XCTAssertEqual(requester.requestCount, 1)
    }
}

@MainActor
private final class DeniedAuthorizationRequester: ReminderNotificationAuthorizationRequester {
    private(set) var requestCount = 0

    func requestAuthorization() async -> Bool {
        requestCount += 1
        return false
    }
}
