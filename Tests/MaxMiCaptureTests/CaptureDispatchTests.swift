import XCTest
@testable import MaxMiCapture

final class CaptureDispatchTests: XCTestCase {
    func testShouldCommit_normalKeyAllowed() {
        let parsed = ParsedCapture(sourceApp: "Web", sourceKey: "https://example.com", sourceTitle: "Example", content: "foo")
        XCTAssertTrue(CaptureDispatch.shouldCommit(parsed: parsed, cleanKey: "https://example.com", pausedThreads: []))
    }

    func testShouldCommit_pausedThreadSkipped() {
        let parsed = ParsedCapture(sourceApp: "Slack", sourceKey: "slack:acme/general", sourceTitle: "general", content: "foo")
        XCTAssertFalse(CaptureDispatch.shouldCommit(parsed: parsed, cleanKey: "slack:acme/general", pausedThreads: ["slack:acme/general"]))
    }

    func testShouldCommit_denylistedKeySkipped() {
        let parsed = ParsedCapture(sourceApp: "Web", sourceKey: "chrome://settings", sourceTitle: "Settings", content: "foo")
        XCTAssertFalse(CaptureDispatch.shouldCommit(parsed: parsed, cleanKey: "chrome://settings", pausedThreads: []))
        XCTAssertEqual(CaptureDispatch.decision(parsed: parsed, cleanKey: "chrome://settings", pausedThreads: []), .blocked)
    }

    func testDecisionDistinguishesPauseFromBlock() {
        let parsed = ParsedCapture(sourceApp: "Slack", sourceKey: "slack:acme/general", sourceTitle: nil, content: "x")
        XCTAssertEqual(
            CaptureDispatch.decision(parsed: parsed, cleanKey: parsed.sourceKey, pausedThreads: [parsed.sourceKey]),
            .paused
        )
        XCTAssertEqual(
            CaptureDispatch.decision(parsed: parsed, cleanKey: parsed.sourceKey, pausedThreads: []),
            .commit
        )
    }

    func testShouldCommit_unpausedThreadAllowed() {
        let parsed = ParsedCapture(sourceApp: "Slack", sourceKey: "slack:acme/general", sourceTitle: "general", content: "foo")
        XCTAssertTrue(CaptureDispatch.shouldCommit(parsed: parsed, cleanKey: "slack:acme/general", pausedThreads: ["slack:acme/random"]))
    }
}
