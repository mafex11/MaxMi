import XCTest
@testable import MaxMiMeetings

final class ContractsTests: XCTestCase {
    func testPCMFrameRoundTrip() {
        let samples: [Float] = [0.1, 0.2, 0.3, 0.4]
        let hostTime: UInt64 = 123456789
        let frame = PCMFrame(samples: samples, hostTimeNs: hostTime)

        XCTAssertEqual(frame.samples, samples)
        XCTAssertEqual(frame.hostTimeNs, hostTime)
    }

    func testCaptureRequestRoundTrip() {
        let request = CaptureRequest(
            bundleID: "us.zoom.xos",
            pid: 12345,
            title: "Team Standup",
            captureSystem: true
        )

        XCTAssertEqual(request.bundleID, "us.zoom.xos")
        XCTAssertEqual(request.pid, 12345)
        XCTAssertEqual(request.title, "Team Standup")
        XCTAssertTrue(request.captureSystem)
    }

    func testAudioInputProcessRoundTrip() {
        let process = AudioInputProcess(pid: 9876, bundleID: "com.microsoft.teams2")

        XCTAssertEqual(process.pid, 9876)
        XCTAssertEqual(process.bundleID, "com.microsoft.teams2")
    }

    func testAudioInputProcessEquality() {
        let p1 = AudioInputProcess(pid: 100, bundleID: "app.test")
        let p2 = AudioInputProcess(pid: 100, bundleID: "app.test")
        let p3 = AudioInputProcess(pid: 200, bundleID: "app.test")

        XCTAssertEqual(p1, p2)
        XCTAssertNotEqual(p1, p3)
    }
}
