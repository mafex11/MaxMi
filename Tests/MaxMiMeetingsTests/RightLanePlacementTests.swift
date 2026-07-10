import XCTest
@testable import MaxMiMeetings

final class RightLanePlacementTests: XCTestCase {
    // macOS coordinate system: origin at bottom-left. visibleFrame.maxY = TOP edge.
    // "topInset: 80" means 80pt DOWN from the top edge = maxY - 80.

    func testOriginDocksRightEdgeAtTopInset() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let panelSize = CGSize(width: 300, height: 500)
        let topInset: CGFloat = 80
        let margin: CGFloat = 16

        let origin = RightLanePlacement.origin(inScreen: visibleFrame, panelSize: panelSize, topInset: topInset, margin: margin)

        // Right-docked: x = visibleFrame.maxX - panelSize.width - margin
        let expectedX = visibleFrame.maxX - panelSize.width - margin  // 1920 - 300 - 16 = 1604

        // Top inset 80pt FROM THE TOP: macOS coords have origin bottom-left, so top = maxY.
        // Panel's origin.y must be positioned so its TOP edge is at (maxY - topInset).
        // Panel origin.y is its BOTTOM edge, so: origin.y = (maxY - topInset) - panelSize.height
        let expectedY = visibleFrame.maxY - topInset - panelSize.height  // 1080 - 80 - 500 = 500

        XCTAssertEqual(origin.x, expectedX, accuracy: 0.1)
        XCTAssertEqual(origin.y, expectedY, accuracy: 0.1)
    }

    func testChooseScreenWithMeetingWindow() {
        let screen1 = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let screen2 = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        let screens = [screen1, screen2]

        let meetingWindow = CGRect(x: 2000, y: 100, width: 800, height: 600)  // on screen2
        let cursor = CGPoint(x: 100, y: 100)  // on screen1

        let chosen = RightLanePlacement.chooseScreen(meetingWindow: meetingWindow, screens: screens, cursor: cursor)

        XCTAssertEqual(chosen, screen2, "Must pick the screen containing the meeting window")
    }

    func testChooseScreenFallbackToCursorWhenMeetingWindowNil() {
        let screen1 = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let screen2 = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        let screens = [screen1, screen2]

        let cursor = CGPoint(x: 2000, y: 100)  // on screen2

        let chosen = RightLanePlacement.chooseScreen(meetingWindow: nil, screens: screens, cursor: cursor)

        XCTAssertEqual(chosen, screen2, "Must fall back to cursor's screen when meetingWindow is nil")
    }

    func testChooseScreenFallbackToCursorWhenMeetingWindowOffScreen() {
        let screen1 = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let screen2 = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        let screens = [screen1, screen2]

        let offScreenWindow = CGRect(x: 5000, y: 5000, width: 800, height: 600)
        let cursor = CGPoint(x: 100, y: 100)  // on screen1

        let chosen = RightLanePlacement.chooseScreen(meetingWindow: offScreenWindow, screens: screens, cursor: cursor)

        XCTAssertEqual(chosen, screen1, "Must fall back to cursor's screen when meeting window is off all screens")
    }

    func testChooseScreenFallbackToFirstScreenWhenCursorOffAll() {
        let screen1 = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let screen2 = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        let screens = [screen1, screen2]

        let offScreenCursor = CGPoint(x: -100, y: -100)

        let chosen = RightLanePlacement.chooseScreen(meetingWindow: nil, screens: screens, cursor: offScreenCursor)

        XCTAssertEqual(chosen, screen1, "Must fall back to first screen when cursor is off all screens")
    }
}
