import XCTest
@testable import MaxMiCore

final class HourBucketTests: XCTestCase {
    func testBucketMath() {
        XCTAssertEqual(HourBucket.bucket(forMs: 0), 0)
        XCTAssertEqual(HourBucket.bucket(forMs: 3_599_999), 0)
        XCTAssertEqual(HourBucket.bucket(forMs: 3_600_000), 1)
        // 2026-07-07T10:30:00Z = 1783593000000 ms -> hour 495442
        XCTAssertEqual(HourBucket.bucket(forMs: 1_783_593_000_000), 495_442)
    }
}
