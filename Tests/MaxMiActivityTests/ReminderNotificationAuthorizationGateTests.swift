import XCTest
@testable import MaxMiActivity

@MainActor
final class ReminderNotificationAuthorizationGateTests: XCTestCase {
    func testDeniedAuthorizationOnlyRequestsOnceAndReturnsDenied() async {
        let requester = DeniedAuthorizationRequester()
        let gate = ReminderNotificationAuthorizationGate()

        let firstAttempt = await gate.postOutcome(using: requester)
        let secondAttempt = await gate.postOutcome(using: requester)

        XCTAssertEqual(firstAttempt, .denied)
        XCTAssertEqual(secondAttempt, .denied)
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
