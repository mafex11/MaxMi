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
    func testBrowserMicrophoneUseRequiresURLVerification() {
        let d = MeetingDetector(); var fired = false
        d.onCandidate = { _, _ in fired = true }
        d.evaluate(active: [AudioInputProcess(pid: 2, bundleID: "com.google.Chrome")])
        XCTAssertFalse(fired, "browser microphone use alone is not proof of a meeting")
    }
    func testZenGoogleMeetURLFiresCandidate() {
        let detector = MeetingDetector(browserURLProvider: { bundleID, _ in
            bundleID == "app.zen-browser.zen" ? "https://meet.google.com/abc-defg-hij" : nil
        })
        var fired: String?
        detector.onCandidate = { bundleID, _ in fired = bundleID }
        detector.evaluate(active: [
            AudioInputProcess(pid: 12, bundleID: "app.zen-browser.zen")
        ])
        XCTAssertEqual(fired, "app.zen-browser.zen")
    }
    func testOrdinaryBrowserMicURLDoesNotFire() {
        let detector = MeetingDetector(browserURLProvider: { _, _ in
            "https://example.com/audio-recorder"
        })
        var fired = false
        detector.onCandidate = { _, _ in fired = true }
        detector.evaluate(active: [
            AudioInputProcess(pid: 13, bundleID: "com.google.Chrome")
        ])
        XCTAssertFalse(fired)
    }
    func testStrictMeetingURLRoutes() {
        XCTAssertEqual(
            MeetingURLClassifier.classify("https://meet.google.com/abc-defg-hij")?.platform,
            "Google Meet"
        )
        XCTAssertEqual(
            MeetingURLClassifier.classify("https://acme.webex.com/meet/person")?.platform,
            "Webex"
        )
        XCTAssertEqual(
            MeetingURLClassifier.classify("https://teams.microsoft.com/l/meetup-join/abc")?.platform,
            "Microsoft Teams"
        )
        XCTAssertNil(MeetingURLClassifier.classify("https://meet.google.com/"))
        XCTAssertNil(MeetingURLClassifier.classify("https://app.slack.com/client/T/C"))
        XCTAssertNil(MeetingURLClassifier.classify("https://zoom.us/profile"))
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
