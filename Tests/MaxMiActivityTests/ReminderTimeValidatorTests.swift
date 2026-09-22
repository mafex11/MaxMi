import Foundation
import XCTest
@testable import MaxMiActivity
import MaxMiCore

final class ReminderTimeValidatorTests: XCTestCase {
    func testReminderTimeValidatorAcceptsFutureTimeAndHonorsOffset() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        let nowMs: EpochMs = 1_790_071_200_000

        let accepted = ReminderTimeValidator.accept(
            "2026-09-22T21:30:00+05:30",
            nowMs: nowMs,
            timeZone: zone
        )

        XCTAssertEqual(accepted, EpochMs(1_790_092_800_000))
    }

    func testReminderTimeValidatorRejectsPastTooFarAndMalformedValues() {
        let nowMs: EpochMs = 1_790_071_200_000
        let zone = TimeZone(secondsFromGMT: 0)!

        XCTAssertNil(ReminderTimeValidator.accept("2026-09-22T09:59:59Z", nowMs: nowMs, timeZone: zone))
        XCTAssertNil(ReminderTimeValidator.accept(
            "2026-09-24T10:00:01Z",
            nowMs: nowMs,
            timeZone: zone
        ))
        XCTAssertNil(ReminderTimeValidator.accept("tomorrow morning", nowMs: nowMs, timeZone: zone))
    }
}
