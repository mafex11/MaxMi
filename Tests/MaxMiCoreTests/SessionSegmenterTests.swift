import XCTest
@testable import MaxMiCore

final class SessionSegmenterTests: XCTestCase {
    func testContinueSameAppWithinGap() {
        XCTAssertEqual(SessionSegmenter.decide(openApp: "a", lastActivityMs: 1000, eventApp: "a", eventMs: 2000),
                       SegmentDecision(closePrevious: false, openNew: false))
    }

    func testAppChangeClosesAndOpens() {
        XCTAssertEqual(SessionSegmenter.decide(openApp: "a", lastActivityMs: 1000, eventApp: "b", eventMs: 2000),
                       SegmentDecision(closePrevious: true, openNew: true))
    }

    func testSameAppAfterGapIsNewSession() {
        XCTAssertEqual(SessionSegmenter.decide(openApp: "a", lastActivityMs: 1000, eventApp: "a", eventMs: 1000 + 6*60_000),
                       SegmentDecision(closePrevious: true, openNew: true))
    }

    func testNoOpenSessionOpens() {
        XCTAssertEqual(SessionSegmenter.decide(openApp: nil, lastActivityMs: nil, eventApp: "a", eventMs: 1000),
                       SegmentDecision(closePrevious: false, openNew: true))
    }
}
