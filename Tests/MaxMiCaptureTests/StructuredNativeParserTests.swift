import XCTest
@testable import MaxMiCapture

final class StructuredNativeParserTests: XCTestCase {
    func fixture(_ name: String) throws -> AXNode {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
    }

    func testCalendarEventExtractsStructuredFields() throws {
        let app = AppInfo(bundleID: "com.apple.iCal", name: "Calendar", windowTitle: "Calendar")
        let capture = try XCTUnwrap(try CalendarParser().parse(
            window: fixture("calendar-event"), app: app
        ))
        XCTAssertEqual(capture.sourceApp, "Calendar")
        XCTAssertEqual(capture.sourceTitle, "Design review")
        XCTAssertTrue(capture.sourceKey.hasPrefix("calendar:event:"))
        XCTAssertEqual(capture.contentKind, .calendar)
        XCTAssertEqual(capture.accumulationPolicy, .replace)
        XCTAssertTrue(capture.content.contains("Event: Design review"))
        XCTAssertTrue(capture.content.contains("When: Tuesday, 3:00 PM"))
        XCTAssertTrue(capture.content.contains("Location: Studio room"))
        XCTAssertTrue(capture.content.contains("Calendar: Work"))
    }

    func testFantasticalUsesSameEventContractWithDistinctIdentity() throws {
        let app = AppInfo(
            bundleID: "com.flexibits.fantastical2.mac", name: "Fantastical", windowTitle: "Fantastical"
        )
        let capture = try XCTUnwrap(try FantasticalParser().parse(
            window: fixture("calendar-event"), app: app
        ))
        XCTAssertEqual(capture.sourceApp, "Fantastical")
        XCTAssertTrue(capture.sourceKey.hasPrefix("fantastical:event:"))
    }

    func testReminderIncludesStateListAndDueDate() throws {
        let app = AppInfo(bundleID: "com.apple.reminders", name: "Reminders", windowTitle: "Reminders")
        let capture = try XCTUnwrap(try RemindersParser().parse(
            window: fixture("reminder-task"), app: app
        ))
        XCTAssertEqual(capture.sourceTitle, "Submit project notes")
        XCTAssertEqual(capture.contentKind, .task)
        XCTAssertEqual(capture.accumulationPolicy, .replace)
        XCTAssertTrue(capture.content.contains("Status: open"))
        XCTAssertTrue(capture.content.contains("List: Work"))
        XCTAssertTrue(capture.content.contains("Due: Tomorrow, 5:00 PM"))
    }

    func testCompletedReminderState() throws {
        let checkbox = AXNode(
            role: "AXCheckBox", value: "1", title: nil, url: nil, frame: nil,
            focused: false, children: [], identifier: "completed-checkbox"
        )
        let heading = AXNode(
            role: "AXHeading", value: "Finished item", title: nil, url: nil, frame: nil,
            focused: false, children: [], identifier: "task-title"
        )
        let detail = AXNode(
            role: "AXGroup", value: nil, title: nil, url: nil, frame: nil,
            focused: false, children: [heading, checkbox], identifier: "reminder-detail"
        )
        let app = AppInfo(bundleID: "com.apple.reminders", name: "Reminders", windowTitle: nil)
        let capture = try XCTUnwrap(try RemindersParser().parse(window: detail, app: app))
        XCTAssertTrue(capture.content.contains("Status: completed"))
    }

    func testPagesDocumentUsesStableTitleAndLargerRollingPolicy() throws {
        let app = AppInfo(
            bundleID: "com.apple.iWork.Pages", name: "Pages", windowTitle: "Project brief — Pages"
        )
        let capture = try XCTUnwrap(try PagesParser().parse(
            window: fixture("pages-document"), app: app
        ))
        XCTAssertEqual(capture.sourceKey, "pages:project-brief")
        XCTAssertEqual(capture.contentKind, .document)
        XCTAssertEqual(capture.accumulationPolicy, .rollingText)
        XCTAssertEqual(capture.offscreenPolicy.maxSteps, 6)
        XCTAssertTrue(capture.content.contains("Implementation notes"))
    }

    func testOutlookVisibleMessageUsesEmailProfile() throws {
        let app = AppInfo(
            bundleID: "com.microsoft.Outlook", name: "Outlook", windowTitle: "Project update"
        )
        let capture = try XCTUnwrap(try OutlookParser().parse(
            window: fixture("pages-document"), app: app
        ))
        XCTAssertEqual(capture.contentKind, .email)
        XCTAssertTrue(capture.sourceKey.hasPrefix("outlook:message:"))
        XCTAssertEqual(capture.parserVersion, 2)
    }
}
