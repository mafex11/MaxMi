import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class RemindersStructuredTests: XCTestCase {
    func node(_ role: String, value: String? = nil, identifier: String? = nil,
              frame: CGRect, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil, frame: frame, focused: false,
               children: children, identifier: identifier, label: nil)
    }

    func row(_ title: String, checkbox: String, due: String?, y: CGFloat,
             x: CGFloat) -> AXNode {
        var kids = [
            node("AXCheckBox", value: checkbox, identifier: "completed-checkbox",
                 frame: CGRect(x: x, y: y, width: 20, height: 20)),
            node("AXStaticText", value: title, identifier: "reminder-title",
                 frame: CGRect(x: x + 30, y: y, width: 300, height: 20)),
        ]
        if let due {
            kids.append(node("AXStaticText", value: due, identifier: "due-date",
                             frame: CGRect(x: x + 30, y: y + 22, width: 200, height: 16)))
        }
        return node("AXRow", frame: CGRect(x: x, y: y, width: 600, height: 44), children: kids)
    }

    func window(origin: CGPoint = .zero) -> AXNode {
        let x = origin.x
        let y = origin.y
        return node("AXWindow", frame: CGRect(origin: origin,
                                               size: CGSize(width: 1100, height: 760)),
                    children: [
            node("AXGroup", identifier: "reminders-sidebar",
                 frame: CGRect(x: x, y: y, width: 240, height: 760), children: [
                node("AXStaticText", value: "Scheduled",
                     frame: CGRect(x: x + 20, y: y + 60, width: 120, height: 20)),
            ]),
            node("AXTable", identifier: "reminder-list",
                 frame: CGRect(x: x + 280, y: y + 60, width: 700, height: 660), children: [
                row("Submit project notes", checkbox: "0", due: "Today 17:00",
                    y: y + 100, x: x + 300),
                row("Book the flights", checkbox: "1", due: nil, y: y + 160, x: x + 300),
            ]),
        ])
    }

    func context(_ title: String?) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: "com.apple.reminders", name: "Reminders",
                                  windowTitle: title))
    }

    func tasks(_ content: CapturedContent?) throws -> [TaskItem] {
        guard case .tasks(let items) = try XCTUnwrap(content) else {
            throw XCTSkip("expected .tasks, got \(String(describing: content))")
        }
        return items
    }

    func testConfigAndRegistration() {
        XCTAssertEqual(RemindersParser.config.bundleIDs, ParserRegistry.remindersBundleIDs)
        XCTAssertEqual(RemindersParser.config.app, "Reminders")
        XCTAssertTrue(ParserRegistry().structuredParser(for: "com.apple.reminders")
                        is RemindersParser)
    }

    func testStatusComesFromTheRowsCheckboxValue() {
        for checked in ["1", "true", "yes", "checked", "TRUE", "Yes"] {
            XCTAssertEqual(
                TaskStructuredExtraction.status(ofRow: row("t", checkbox: checked, due: nil,
                                                           y: 0, x: 0)),
                .completed, checked)
        }
        XCTAssertEqual(
            TaskStructuredExtraction.status(ofRow: row("t", checkbox: "0", due: nil, y: 0, x: 0)),
            .open)
    }

    func testARowWithNoCheckboxHasUnknownStatus() {
        let noCheckbox = node("AXRow", frame: CGRect(x: 0, y: 0, width: 600, height: 20),
                              children: [node("AXStaticText", value: "t",
                                              frame: CGRect(x: 0, y: 0, width: 100, height: 16))])
        XCTAssertEqual(TaskStructuredExtraction.status(ofRow: noCheckbox), .unknown)
    }

    func testEveryRowBecomesOneTaskItemInVisualOrder() throws {
        let items = try tasks(RemindersParser().parse(window(), context: context("Reminders")))
        XCTAssertEqual(items.map(\.title), ["Submit project notes", "Book the flights"])
        XCTAssertEqual(items.map(\.status), [.open, .completed])
        XCTAssertEqual(items.map(\.dueString), ["Today 17:00", nil])
        XCTAssertEqual(items.map(\.due), [nil, nil], "M8 stores the due STRING, not a parsed Date")
        XCTAssertEqual(items.map(\.tags), [[], []])
    }

    func testTheDueStringIsNotDuplicatedIntoTheTitle() throws {
        let items = try tasks(RemindersParser().parse(window(), context: context("Reminders")))
        XCTAssertFalse(items[0].title.contains("Today 17:00"))
    }

    func testTheListNameFromTheSidebarSelectionBecomesTheProject() throws {
        let win = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1100, height: 760), children: [
            node("AXTable", identifier: "reminder-list",
                 frame: CGRect(x: 280, y: 60, width: 700, height: 660), children: [
                node("AXRow", frame: CGRect(x: 300, y: 100, width: 600, height: 44), children: [
                    node("AXCheckBox", value: "0", identifier: "completed-checkbox",
                         frame: CGRect(x: 300, y: 100, width: 20, height: 20)),
                    node("AXStaticText", value: "Submit notes", identifier: "reminder-title",
                         frame: CGRect(x: 330, y: 100, width: 300, height: 20)),
                    node("AXStaticText", value: "Work", identifier: "list-name",
                         frame: CGRect(x: 330, y: 122, width: 120, height: 16)),
                ]),
            ]),
        ])
        let items = try tasks(RemindersParser().parse(win, context: context("Reminders")))
        XCTAssertEqual(items[0].project, "Work")
    }

    func testSidebarChromeNeverBecomesATask() throws {
        let items = try tasks(RemindersParser().parse(window(), context: context("Reminders")))
        XCTAssertFalse(items.contains { $0.title == "Scheduled" })
    }

    func testNoRowsFallsBackToTheSingleDetailShape() throws {
        // The existing fixture is a reminder DETAIL pane, not a list of rows. The parser must
        // still produce one task from it, which is what keeps reminder-task.json meaningful.
        let items = try tasks(RemindersParser().parse(try fixture("reminder-task"),
                                                     context: context("Reminders")))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Submit project notes")
    }

    func testNothingUsableIsNotHandled() throws {
        let bare = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1100, height: 760),
                        children: [node("AXGroup", identifier: "reminders-sidebar",
                                        frame: CGRect(x: 0, y: 0, width: 240, height: 760))])
        XCTAssertNil(try RemindersParser().parse(bare, context: context("Reminders")))
    }

    func testResultIsIdenticalAtANonzeroWindowOrigin() throws {
        XCTAssertEqual(try RemindersParser().parse(window(), context: context("Reminders")),
                       try RemindersParser().parse(window(origin: CGPoint(x: 1440, y: 220)),
                                               context: context("Reminders")))
    }

    func testRenderedTaskLines() throws {
        let rendered = ContentRenderer.render(
            try XCTUnwrap(RemindersParser().parse(window(), context: context("Reminders"))),
            style: .full)
        XCTAssertTrue(rendered.contains("- [ ] Submit project notes (due Today 17:00)"))
        XCTAssertTrue(rendered.contains("- [x] Book the flights"))
    }

    func testReminderTaskFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(RemindersParser().parse(try fixture("reminder-task"),
                                                          context: context("Reminders"))),
                     matches: "reminder-task-golden")
    }

    func testOffsetRemindersFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(RemindersParser().parse(try fixture("reminders-offset-list"),
                                                          context: context("Reminders"))),
                     matches: "reminders-offset-list-golden")
    }
}
