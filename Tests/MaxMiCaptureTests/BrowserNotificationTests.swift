import XCTest
@testable import MaxMiCapture

final class BrowserNotificationTests: XCTestCase {
    func testBrowserNavigationNotificationsAreExplicit() {
        XCTAssertEqual(CaptureNotificationClassifier.trigger(
            notification: "AXTitleChanged", isBrowser: true
        ), .browserNavigation)
        XCTAssertEqual(CaptureNotificationClassifier.trigger(
            notification: "AXSelectedChildrenChanged", isBrowser: true
        ), .browserNavigation)
        XCTAssertEqual(CaptureNotificationClassifier.trigger(
            notification: "AXLoadComplete", isBrowser: true
        ), .browserNavigation)
    }

    func testSPAAndLiveRegionChangesUseWebContentTrigger() {
        XCTAssertEqual(CaptureNotificationClassifier.trigger(
            notification: "AXValueChanged", isBrowser: true
        ), .webContentChanged)
        XCTAssertEqual(CaptureNotificationClassifier.trigger(
            notification: "AXLiveRegionChanged", isBrowser: true
        ), .webContentChanged)
        XCTAssertEqual(CaptureNotificationClassifier.trigger(
            notification: "AXValueChanged", isBrowser: false
        ), .accessibilityChanged)
    }
}
