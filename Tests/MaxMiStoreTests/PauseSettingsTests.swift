import XCTest
@testable import MaxMiStore
import MaxMiCore

final class PauseSettingsTests: XCTestCase {
    var store: Store!
    let t0 = EpochMs(495_442) * 3_600_000
    override func setUpWithError() throws {
        store = Store(db: try MaxMiDatabase.inMemory(), cipher: AESGCMFieldCipher.testCipher)
    }
    func testDefaultsEmpty() throws {
        XCTAssertTrue(try store.pausedApps().isEmpty)
        XCTAssertTrue(try store.pausedThreads().isEmpty)
    }
    func testPauseAndUnpauseApp() throws {
        try store.setAppPaused("net.whatsapp.WhatsApp", paused: true, nowMs: t0)
        XCTAssertEqual(try store.pausedApps(), ["net.whatsapp.WhatsApp"])
        try store.setAppPaused("net.whatsapp.WhatsApp", paused: false, nowMs: t0 + 1)
        XCTAssertTrue(try store.pausedApps().isEmpty)
    }
    func testPauseThreadIsIdempotentAndAdditive() throws {
        try store.setThreadPaused("slack:acme/general", paused: true, nowMs: t0)
        try store.setThreadPaused("slack:acme/general", paused: true, nowMs: t0 + 1)  // idempotent
        try store.setThreadPaused("whatsapp:Mom", paused: true, nowMs: t0 + 2)
        XCTAssertEqual(try store.pausedThreads(), ["slack:acme/general", "whatsapp:Mom"])
    }

    func testGlobalPauseSupportsExpiryIndefiniteAndResume() throws {
        XCTAssertEqual(try store.capturePauseState(nowMs: t0), .inactive)
        try store.setCapturePaused(untilMs: t0 + 60_000, nowMs: t0)
        XCTAssertTrue(try store.capturePauseState(nowMs: t0 + 1).isPaused(at: t0 + 1))
        XCTAssertEqual(try store.capturePauseState(nowMs: t0 + 60_000), .inactive)

        try store.setCapturePaused(untilMs: nil, nowMs: t0)
        XCTAssertEqual(try store.capturePauseState(nowMs: t0 + 1_000_000), .active(untilMs: nil))
        try store.clearCapturePause(nowMs: t0 + 1)
        XCTAssertEqual(try store.capturePauseState(nowMs: t0 + 1), .inactive)
    }

    func testBlockedDomainsAreNormalizedAndDurable() throws {
        XCTAssertEqual(try store.setDomain("https://Sub.Example.com/path", blocked: true, nowMs: t0), "sub.example.com")
        XCTAssertEqual(try store.setDomain("*.example.org", blocked: true, nowMs: t0 + 1), "example.org")
        XCTAssertEqual(try store.blockedDomains(), ["sub.example.com", "example.org"])
        XCTAssertNil(try store.setDomain("not a domain", blocked: true, nowMs: t0 + 2))
        _ = try store.setDomain("example.org", blocked: false, nowMs: t0 + 3)
        XCTAssertEqual(try store.blockedDomains(), ["sub.example.com"])
    }

    func testPausedThreadInfoCanAlwaysBeManaged() throws {
        _ = try store.commitCapture(
            CaptureInput(sourceApp: "Slack", sourceKey: "slack:acme/general", sourceTitle: "General", content: "hello"),
            nowMs: t0
        )
        try store.setThreadPaused("slack:acme/general", paused: true, nowMs: t0 + 1)
        try store.setThreadPaused("missing:key", paused: true, nowMs: t0 + 2)
        let info = try store.pausedThreadInfo()
        XCTAssertEqual(info.map(\.id), ["missing:key", "slack:acme/general"])
        XCTAssertEqual(info.last?.sourceTitle, "General")
    }

    func testRetentionSettingRoundTrips() throws {
        XCTAssertNil(try store.retentionDays())
        try store.setRetentionDays(90, nowMs: t0)
        XCTAssertEqual(try store.retentionDays(), 90)
        try store.setRetentionDays(nil, nowMs: t0 + 1)
        XCTAssertNil(try store.retentionDays())
    }

    func testNewSourceIsHeldFromCloudUntilReviewed() throws {
        _ = try store.commitCapture(
            CaptureInput(sourceApp: "Web", sourceKey: "web:old", sourceTitle: "Old", content: "existing"),
            nowMs: t0
        )
        try store.bootstrapCloudProcessingReview(nowMs: t0 + 1)
        _ = try store.commitCapture(
            CaptureInput(sourceApp: "Slack", sourceKey: "slack:new", sourceTitle: "New", content: "new source"),
            nowMs: t0 + 2
        )
        XCTAssertEqual(try store.cloudProcessingState(for: "Web"), .allowed)
        XCTAssertEqual(try store.cloudProcessingState(for: "Slack"), .pendingReview)
        XCTAssertEqual(try store.pendingWork(nowMs: t0 + 600_000, idleThresholdMs: 300_000).map(\.sourceApp), ["Web"])
        XCTAssertEqual(try store.captureContextsNeedingSummary(nowMs: t0 + 20_000, settleMs: 10_000, limit: 10).map(\.appLabel), ["Web"])

        try store.setCloudProcessing("Slack", allowed: false, nowMs: t0 + 3)
        XCTAssertEqual(try store.cloudProcessingState(for: "Slack"), .localOnly)
        XCTAssertEqual(try store.pendingWork(nowMs: t0 + 600_000, idleThresholdMs: 300_000).map(\.sourceApp), ["Web"])

        try store.setCloudProcessing("Slack", allowed: true, nowMs: t0 + 4)
        XCTAssertEqual(try store.cloudProcessingState(for: "Slack"), .allowed)
        XCTAssertEqual(Set(try store.pendingWork(nowMs: t0 + 600_000, idleThresholdMs: 300_000).map(\.sourceApp)), Set(["Web", "Slack"]))
    }
}
