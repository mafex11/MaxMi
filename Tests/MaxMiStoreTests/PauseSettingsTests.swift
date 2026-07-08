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
}
