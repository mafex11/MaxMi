import XCTest
@testable import MaxMiCapture

final class EventPrivacyGateTests: XCTestCase {
    private let browserBundleID = "com.google.Chrome"

    func testBlockedBrowserURLWritesNoFocusOrTypingEvent() {
        let decision = EventPrivacyGate.decision(
            bundleID: browserBundleID,
            isAppEligible: true,
            browserURL: "https://accounts.google.com/signin",
            blockedDomains: [])

        XCTAssertFalse(decision.writesFocusEvent)
        XCTAssertFalse(decision.writesTypingEvent)
    }

    func testSensitiveAppWritesNoFocusOrTypingEvent() {
        let decision = EventPrivacyGate.decision(
            bundleID: "com.apple.keychainaccess",
            isAppEligible: true,
            browserURL: nil,
            blockedDomains: [])

        XCTAssertFalse(decision.writesFocusEvent)
        XCTAssertFalse(decision.writesTypingEvent)
    }

    func testUnresolvableBrowserURLWritesFocusWithoutTitleAndNoTypingEvent() {
        let decision = EventPrivacyGate.decision(
            bundleID: browserBundleID,
            isAppEligible: true,
            browserURL: nil,
            blockedDomains: [])

        XCTAssertTrue(decision.writesFocusEvent)
        XCTAssertFalse(decision.writesTypingEvent)
        XCTAssertFalse(decision.includesFocusWindowTitle)
    }

    func testAllowedAppKeepsFocusTitleAndTyping() {
        let decision = EventPrivacyGate.decision(
            bundleID: browserBundleID,
            isAppEligible: true,
            browserURL: "https://swift.org/documentation",
            blockedDomains: [])

        XCTAssertTrue(decision.writesFocusEvent)
        XCTAssertTrue(decision.writesTypingEvent)
        XCTAssertTrue(decision.includesFocusWindowTitle)
    }

    func testKnownAllowedURLUsesLookupWithoutSnapshotting() {
        var snapshotCalls = 0
        let decision = EventPrivacyGate.decision(
            bundleID: browserBundleID,
            isAppEligible: true,
            browserURLLookup: { "https://swift.org/documentation" },
            snapshot: { snapshotCalls += 1 },
            blockedDomains: []
        )

        XCTAssertEqual(decision, EventPrivacyGate.Decision(
            writesFocusEvent: true,
            writesTypingEvent: true,
            includesFocusWindowTitle: true
        ))
        XCTAssertEqual(snapshotCalls, 0)
    }

    func testKnownBlockedURLUsesLookupWithoutSnapshotting() {
        var snapshotCalls = 0
        let decision = EventPrivacyGate.decision(
            bundleID: browserBundleID,
            isAppEligible: true,
            browserURLLookup: { "https://accounts.google.com/signin" },
            snapshot: { snapshotCalls += 1 },
            blockedDomains: []
        )

        XCTAssertEqual(decision, EventPrivacyGate.Decision(
            writesFocusEvent: false,
            writesTypingEvent: false,
            includesFocusWindowTitle: false
        ))
        XCTAssertEqual(snapshotCalls, 0)
    }

    func testUnknownURLFailsClosedWithoutSnapshotting() {
        var snapshotCalls = 0
        let decision = EventPrivacyGate.decision(
            bundleID: browserBundleID,
            isAppEligible: true,
            browserURLLookup: { nil },
            snapshot: { snapshotCalls += 1 },
            blockedDomains: []
        )

        XCTAssertEqual(decision, EventPrivacyGate.Decision(
            writesFocusEvent: true,
            writesTypingEvent: false,
            includesFocusWindowTitle: false
        ))
        XCTAssertEqual(snapshotCalls, 0)
    }
}
