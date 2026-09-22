import XCTest
@testable import MaxMiCore

final class ActivityTimeTests: XCTestCase {
    func testDayBucketUsesInjectedTimeZoneAcrossLocalMidnight() throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 22, hour: 0, minute: 15
        )))
        let expectedStart = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 22, hour: 0, minute: 0
        )))

        XCTAssertEqual(
            ActivityTime.dayBucket(
                forMs: EpochMs(date.timeIntervalSince1970 * 1_000),
                timeZone: timeZone
            ),
            EpochMs(expectedStart.timeIntervalSince1970 * 1_000)
        )
    }

    func testAgeDescriptionUsesHoursThenDays() {
        XCTAssertEqual(ActivityTime.ageDescription(detectedAtMs: 0, nowMs: 3 * 3_600_000), "3h")
        XCTAssertEqual(ActivityTime.ageDescription(detectedAtMs: 0, nowMs: 2 * 86_400_000), "2d")
    }
}
