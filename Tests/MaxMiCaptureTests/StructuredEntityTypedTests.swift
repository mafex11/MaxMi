import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class StructuredEntityTypedTests: XCTestCase {
    func fixture(_ name: String) throws -> AXNode {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"
        ))
        return try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
    }

    func testCalendarEventFixtureBecomesATypedEvent() throws {
        let app = AppInfo(bundleID: "com.apple.iCal", name: "Calendar", windowTitle: "Calendar")
        let structured = try CalendarParser().parseStructured(window: try fixture("calendar-event"), app: app)
        guard case .calendar(let events) = try XCTUnwrap(structured) else {
            return XCTFail("expected .calendar")
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].title, "Design review")
        XCTAssertEqual(events[0].dateString, "Tuesday, 3:00 PM")
        XCTAssertEqual(events[0].location, "Studio room")
        XCTAssertEqual(events[0].organizer, "Work", "the calendar/account name lands in organizer")
        XCTAssertEqual(events[0].notes, "Review the interaction flow.",
                       "the leftover detail text becomes CalendarEvent.notes")
        XCTAssertFalse(events[0].hasConference)
        XCTAssertNil(events[0].start)
        XCTAssertNil(events[0].end)
    }

    func testCalendarCaptureKeepsItsKeyKindAndPolicyAndRendersTheEvent() throws {
        let app = AppInfo(bundleID: "com.apple.iCal", name: "Calendar", windowTitle: "Calendar")
        let capture = try XCTUnwrap(try CalendarParser().parse(window: try fixture("calendar-event"), app: app))
        XCTAssertEqual(capture.sourceApp, "Calendar")
        XCTAssertEqual(capture.sourceTitle, "Design review")
        XCTAssertTrue(capture.sourceKey.hasPrefix("calendar:event:"))
        XCTAssertEqual(capture.contentKind, .calendar)
        XCTAssertEqual(capture.accumulationPolicy, .replace)
        XCTAssertEqual(capture.parserVersion, 2)
        XCTAssertEqual(capture.content, """
        Tuesday, 3:00 PM — Design review @Studio room / Work
        Details: Review the interaction flow.
        """)
        XCTAssertEqual(capture.content, ContentRenderer.render(
            try XCTUnwrap(capture.structured), style: .full))
    }

    func testFantasticalUsesTheSameShapeWithItsOwnKeyPrefix() throws {
        let app = AppInfo(bundleID: "com.flexibits.fantastical2.mac", name: "Fantastical",
                          windowTitle: "Fantastical")
        let capture = try XCTUnwrap(try FantasticalParser().parse(window: try fixture("calendar-event"), app: app))
        XCTAssertEqual(capture.sourceApp, "Fantastical")
        XCTAssertTrue(capture.sourceKey.hasPrefix("fantastical:event:"))
        XCTAssertEqual(capture.contentKind, .calendar)
    }

    func testReminderFixtureBecomesATypedOpenTask() throws {
        let app = AppInfo(bundleID: "com.apple.reminders", name: "Reminders", windowTitle: "Reminders")
        let structured = try RemindersParser().parseStructured(window: try fixture("reminder-task"), app: app)
        guard case .tasks(let items) = try XCTUnwrap(structured) else {
            return XCTFail("expected .tasks")
        }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Submit project notes")
        XCTAssertEqual(items[0].status, .open)
        XCTAssertEqual(items[0].project, "Work")
        XCTAssertEqual(items[0].dueString, "Tomorrow, 5:00 PM")
        XCTAssertEqual(items[0].tags, [])
        XCTAssertNil(items[0].due)
    }

    func testReminderCaptureRendersTheTaskLine() throws {
        let app = AppInfo(bundleID: "com.apple.reminders", name: "Reminders", windowTitle: "Reminders")
        let capture = try XCTUnwrap(try RemindersParser().parse(window: try fixture("reminder-task"), app: app))
        XCTAssertEqual(capture.contentKind, .task)
        XCTAssertEqual(capture.accumulationPolicy, .replace)
        XCTAssertEqual(capture.sourceTitle, "Submit project notes")
        XCTAssertEqual(capture.content, """
        - [ ] Submit project notes (due Tomorrow, 5:00 PM) [Work]
          Attach the final screenshots.
        """)
    }

    func testCheckedCheckboxBecomesCompleted() throws {
        let window = AXNode(role: "AXWindow", value: nil, title: "Reminders", url: nil,
                            frame: CGRect(x: 0, y: 0, width: 800, height: 600), focused: false,
                            children: [
            AXNode(role: "AXGroup", value: nil, title: "task detail", url: nil,
                   frame: CGRect(x: 0, y: 0, width: 800, height: 600), focused: false, children: [
                AXNode(role: "AXHeading", value: "Send invoice", title: nil, url: nil,
                       frame: CGRect(x: 10, y: 10, width: 400, height: 24), focused: false, children: []),
                AXNode(role: "AXCheckBox", value: "1", title: nil, url: nil,
                       frame: CGRect(x: 10, y: 40, width: 24, height: 24), focused: false,
                       children: [], identifier: "completed"),
            ]),
        ])
        let app = AppInfo(bundleID: "com.apple.reminders", name: "Reminders", windowTitle: "Reminders")
        let capture = try XCTUnwrap(try RemindersParser().parse(window: window, app: app))
        XCTAssertTrue(capture.content.hasPrefix("- [x] Send invoice"))
    }

    func testTaskNotesCarryTheLeftoverDetailText() throws {
        let window = AXNode(role: "AXWindow", value: nil, title: "Todoist", url: nil,
                            frame: CGRect(x: 0, y: 0, width: 800, height: 600), focused: false,
                            children: [
            AXNode(role: "AXGroup", value: nil, title: "task detail", url: nil,
                   frame: CGRect(x: 0, y: 0, width: 800, height: 600), focused: false, children: [
                AXNode(role: "AXHeading", value: "Draft the brief", title: nil, url: nil,
                       frame: CGRect(x: 10, y: 10, width: 400, height: 24), focused: false, children: []),
                AXNode(role: "AXStaticText", value: "Include the pricing table", title: nil, url: nil,
                       frame: CGRect(x: 10, y: 60, width: 400, height: 16), focused: false, children: []),
            ]),
        ])
        let app = AppInfo(bundleID: "com.todoist.mac.Todoist", name: "Todoist", windowTitle: "Todoist")
        let capture = try XCTUnwrap(try TodoistParser().parse(window: window, app: app))
        XCTAssertTrue(capture.content.contains("\n  Include the pricing table"),
                      "leftover detail text becomes TaskItem.notes")
    }

    func testAllFourRemainingTaskAppsUseTheTasksShape() throws {
        let window = AXNode(role: "AXWindow", value: nil, title: "Tasks", url: nil,
                            frame: CGRect(x: 0, y: 0, width: 800, height: 600), focused: false,
                            children: [
            AXNode(role: "AXGroup", value: nil, title: "task detail", url: nil,
                   frame: CGRect(x: 0, y: 0, width: 800, height: 600), focused: false, children: [
                AXNode(role: "AXHeading", value: "Do the thing", title: nil, url: nil,
                       frame: CGRect(x: 10, y: 10, width: 400, height: 24), focused: false, children: []),
            ]),
        ])
        let cases: [(any SourceParser, String)] = [
            (MicrosoftToDoParser(), "com.microsoft.to-do-mac"),
            (TodoistParser(), "com.todoist.mac.Todoist"),
            (OmniFocusParser(), "com.omnigroup.OmniFocus4"),
            (TogglParser(), "com.toggl.toggldesktop"),
        ]
        for (parser, bundleID) in cases {
            let app = AppInfo(bundleID: bundleID, name: "Tasks", windowTitle: "Tasks")
            let structured = try XCTUnwrap(try parser.parseStructured(window: window, app: app), bundleID)
            XCTAssertEqual(structured.kind, .task, bundleID)
        }
    }

    func testUnparseableWindowStillReturnsNil() throws {
        let window = AXNode(role: "AXWindow", value: nil, title: nil, url: nil,
                            frame: CGRect(x: 0, y: 0, width: 800, height: 600), focused: false,
                            children: [])
        let app = AppInfo(bundleID: "com.apple.iCal", name: "Calendar", windowTitle: nil)
        XCTAssertNil(try CalendarParser().parseStructured(window: window, app: app))
        XCTAssertNil(try RemindersParser().parseStructured(window: window, app: app))
    }
}
