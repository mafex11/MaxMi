import XCTest
@testable import MaxMiMeetings

final class MeetingLifecycleTests: XCTestCase {
    func testInterruptedMarkerIsContentFreeRestrictiveAndConsumed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaxMi-MeetingLifecycle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tracker = FileMeetingLifecycleTracker(directoryURL: directory)

        await tracker.recordingStarted(kind: .voiceNote, startedAtMs: 123_456)

        let markerURL = await tracker.markerURL
        let data = try Data(contentsOf: markerURL)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("voice_note"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("title"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("transcript"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("bundle"))
        let attributes = try FileManager.default.attributesOfItem(atPath: markerURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let recovered = await tracker.recoverInterrupted()
        XCTAssertEqual(recovered, InterruptedRecording(kind: .voiceNote, startedAtMs: 123_456))
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        let secondRecovery = await tracker.recoverInterrupted()
        XCTAssertNil(secondRecovery)
    }

    func testCorruptMarkerIsQuarantinedByDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaxMi-MeetingLifecycle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tracker = FileMeetingLifecycleTracker(directoryURL: directory)
        let markerURL = await tracker.markerURL
        try Data("not-json".utf8).write(to: markerURL)

        let recovery = await tracker.recoverInterrupted()
        XCTAssertNil(recovery)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testResourceCountersAreIdempotentlyBounded() {
        let tracker = MeetingResourceTracker()
        tracker.audioEngineStarted()
        tracker.deviceObserverStarted()
        tracker.screenStreamStarted()
        tracker.meetingDetectorStarted()
        XCTAssertEqual(
            tracker.snapshot(),
            MeetingResourceSnapshot(audioEngines: 1, screenStreams: 1, deviceObservers: 1, meetingDetectors: 1)
        )

        tracker.audioEngineStopped()
        tracker.audioEngineStopped()
        tracker.deviceObserverStopped()
        tracker.deviceObserverStopped()
        tracker.screenStreamStopped()
        tracker.screenStreamStopped()
        tracker.meetingDetectorStopped()
        tracker.meetingDetectorStopped()
        XCTAssertEqual(
            tracker.snapshot(),
            MeetingResourceSnapshot(audioEngines: 0, screenStreams: 0, deviceObservers: 0, meetingDetectors: 0)
        )
    }
}
