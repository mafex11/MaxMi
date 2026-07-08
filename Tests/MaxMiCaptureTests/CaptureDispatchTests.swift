import XCTest
@testable import MaxMiCapture

final class CaptureDispatchTests: XCTestCase {
    func testShouldCommit_normalKeyAllowed() {
        let parsed = ParsedCapture(sourceApp: "Web", sourceKey: "https://example.com", sourceTitle: "Example", content: "foo")
        XCTAssertTrue(CaptureDispatch.shouldCommit(parsed: parsed, pausedThreads: []))
    }

    func testShouldCommit_pausedThreadSkipped() {
        let parsed = ParsedCapture(sourceApp: "Slack", sourceKey: "slack:acme/general", sourceTitle: "general", content: "foo")
        XCTAssertFalse(CaptureDispatch.shouldCommit(parsed: parsed, pausedThreads: ["slack:acme/general"]))
    }

    func testShouldCommit_denylistedKeySkipped() {
        let parsed = ParsedCapture(sourceApp: "Web", sourceKey: "chrome://settings", sourceTitle: "Settings", content: "foo")
        XCTAssertFalse(CaptureDispatch.shouldCommit(parsed: parsed, pausedThreads: []))
    }

    func testShouldCommit_unpausedThreadAllowed() {
        let parsed = ParsedCapture(sourceApp: "Slack", sourceKey: "slack:acme/general", sourceTitle: "general", content: "foo")
        XCTAssertTrue(CaptureDispatch.shouldCommit(parsed: parsed, pausedThreads: ["slack:acme/random"]))
    }
}
