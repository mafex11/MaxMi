import XCTest
@testable import MaxMiMeetings

final class MeetingDetectorTests: XCTestCase {
    func testClassifiesKnownApps() {
        XCTAssertEqual(MeetingAppList.classify(bundleID: "us.zoom.xos"), .native("Zoom"))
        XCTAssertEqual(MeetingAppList.classify(bundleID: "com.microsoft.teams2"), .native("Microsoft Teams"))
        XCTAssertEqual(MeetingAppList.classify(bundleID: "com.google.Chrome"), .browser("Chrome"))
        XCTAssertNil(MeetingAppList.classify(bundleID: "com.apple.Terminal"))
    }
    func testEvaluateFiresCandidateOnMeetingAppInput() {
        let d = MeetingDetector()
        var fired: String?
        d.onCandidate = { bid, _ in fired = bid }
        d.evaluate(active: [AudioInputProcess(pid: 123, bundleID: "us.zoom.xos")])
        XCTAssertEqual(fired, "us.zoom.xos")
    }
    func testEvaluateIgnoresNonMeetingInput() {
        let d = MeetingDetector(); var fired = false
        d.onCandidate = { _, _ in fired = true }
        d.evaluate(active: [AudioInputProcess(pid: 1, bundleID: "com.apple.VoiceMemos")])
        XCTAssertFalse(fired, "voice memo mic use is not a meeting")
    }
    func testEndFiresOnlyWhenAllMeetingProcsStop() {
        let d = MeetingDetector(); var ended: String?
        d.onEnded = { ended = $0 }
        // two zoom helper procs active; one stops -> NOT ended (Codex #3: multi-process state)
        d.evaluate(active: [AudioInputProcess(pid: 1, bundleID: "us.zoom.xos"),
                            AudioInputProcess(pid: 2, bundleID: "us.zoom.xos")])
        d.evaluate(active: [AudioInputProcess(pid: 2, bundleID: "us.zoom.xos")])
        XCTAssertNil(ended, "one of two zoom procs stopping is not meeting end")
        d.evaluate(active: [])
        XCTAssertEqual(ended, "us.zoom.xos", "all meeting procs stopped -> ended")
    }
}
