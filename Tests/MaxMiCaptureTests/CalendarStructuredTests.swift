import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class CalendarStructuredTests: XCTestCase {
    func node(_ role: String, value: String? = nil, identifier: String? = nil,
              frame: CGRect, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil, frame: frame, focused: false,
               children: children, identifier: identifier, label: nil)
    }

    func field(_ role: String, _ value: String, _ identifier: String,
               y: CGFloat, x: CGFloat) -> AXNode {
        node(role, value: value, identifier: identifier,
             frame: CGRect(x: x, y: y, width: 300, height: 20))
    }

    /// A Calendar window with a sidebar and an event-detail popover.
    func window(origin: CGPoint = .zero, conference: Bool = false) -> AXNode {
        let x = origin.x
        let y = origin.y
        var detail = [
            field("AXHeading", "Design review", "event-title", y: y + 140, x: x + 420),
            field("AXStaticText", "Thursday 12 September, 14:00 to 15:00", "event-date",
                  y: y + 180, x: x + 420),
            field("AXStaticText", "Room 4", "event-location", y: y + 210, x: x + 420),
            field("AXStaticText", "ada@example.com", "event-organizer", y: y + 240, x: x + 420),
        ]
        if conference {
            detail.append(field("AXLink", "Join video call", "event-conference",
                                y: y + 270, x: x + 420))
        }
        return node("AXWindow", frame: CGRect(origin: origin,
                                             size: CGSize(width: 1200, height: 800)),
                    children: [
            node("AXGroup", identifier: "calendar-sidebar",
                 frame: CGRect(x: x, y: y, width: 220, height: 800), children: [
                node("AXStaticText", value: "Today",
                     frame: CGRect(x: x + 20, y: y + 80, width: 100, height: 20)),
            ]),
            node("AXPopover", identifier: "event-detail",
                 frame: CGRect(x: x + 400, y: y + 120, width: 480, height: 420),
                 children: detail),
        ])
    }

    func context(_ bundleID: String, _ title: String?) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: bundleID, name: "Calendar", windowTitle: title))
    }

    func events(_ content: CapturedContent?) throws -> [CalendarEvent] {
        guard case .calendar(let events) = try XCTUnwrap(content) else {
            throw XCTSkip("expected .calendar, got \(String(describing: content))")
        }
        return events
    }

    func testConfigsAndRegistration() {
        XCTAssertEqual(CalendarParser.config.bundleIDs, ParserRegistry.calendarBundleIDs)
        XCTAssertEqual(CalendarParser.config.app, "Calendar")
        XCTAssertEqual(FantasticalParser.config.bundleIDs, ParserRegistry.fantasticalBundleIDs)
        XCTAssertEqual(FantasticalParser.config.app, "Fantastical")
        let registry = ParserRegistry()
        XCTAssertTrue(registry.structuredParser(for: "com.apple.iCal") is CalendarParser)
        XCTAssertTrue(registry.structuredParser(for: "com.flexibits.fantastical2.mac")
                        is FantasticalParser)
    }

    func testEventDetailBecomesOneCalendarEvent() throws {
        let list = try events(CalendarParser().parse(window(),
                                                   context: context("com.apple.iCal", "Calendar")))
        XCTAssertEqual(list.count, 1)
        let event = list[0]
        XCTAssertEqual(event.title, "Design review")
        XCTAssertEqual(event.dateString, "Thursday 12 September, 14:00 to 15:00")
        XCTAssertEqual(event.location, "Room 4")
        XCTAssertEqual(event.organizer, "ada@example.com")
        XCTAssertFalse(event.hasConference)
        XCTAssertNil(event.notes, "all four fields were claimed, so nothing is left for notes")
        XCTAssertNil(event.start, "M8 stores the date STRING; parsing it is not in scope")
        XCTAssertNil(event.end)
    }

    func testAConferenceLinkSetsHasConference() throws {
        let list = try events(CalendarParser().parse(window(conference: true),
                                                    context: context("com.apple.iCal", "Calendar")))
        XCTAssertTrue(list[0].hasConference,
                      "the field's identifier names it as the conference link")
        XCTAssertEqual(list[0].notes, "Join video call",
                       "an unclaimed detail field is the notes body, exactly as Phase A built it")
    }

    func testDateFallsBackToADateLookingFieldWithoutAMetadataHint() throws {
        let win = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1200, height: 800), children: [
            node("AXPopover", identifier: "event-detail",
                 frame: CGRect(x: 400, y: 120, width: 480, height: 420), children: [
                field("AXHeading", "Standup", "no-hint-title", y: 140, x: 420),
                field("AXStaticText", "Tomorrow 09:30 AM", "unlabelled", y: 180, x: 420),
            ]),
        ])
        let list = try events(CalendarParser().parse(win, context: context("com.apple.iCal", nil)))
        XCTAssertEqual(list[0].dateString, "Tomorrow 09:30 AM")
    }

    func testSidebarChromeNeverBecomesAnEventTitle() throws {
        let list = try events(CalendarParser().parse(window(),
                                                   context: context("com.apple.iCal", "Calendar")))
        XCTAssertFalse(list.contains { $0.title == "Today" })
    }

    func testNoDetailRootIsNotHandled() throws {
        let bare = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                        children: [node("AXGroup", identifier: "calendar-sidebar",
                                        frame: CGRect(x: 0, y: 0, width: 220, height: 800))])
        XCTAssertNil(try CalendarParser().parse(bare, context: context("com.apple.iCal", "Calendar")))
    }

    func testResultIsIdenticalAtANonzeroWindowOrigin() throws {
        XCTAssertEqual(try CalendarParser().parse(window(), context: context("com.apple.iCal", "Calendar")),
                       try CalendarParser().parse(window(origin: CGPoint(x: 1440, y: 220)),
                                              context: context("com.apple.iCal", "Calendar")))
    }

    func testFantasticalUsesTheSameExtraction() throws {
        let list = try events(FantasticalParser().parse(
            window(), context: context("com.flexibits.fantastical2.mac", "Fantastical")))
        XCTAssertEqual(list[0].title, "Design review")
    }

    func testRenderedCalendarLine() throws {
        let rendered = ContentRenderer.render(
            try XCTUnwrap(CalendarParser().parse(window(conference: true),
                                                 context: context("com.apple.iCal", "Calendar"))),
            style: .full)
        XCTAssertEqual(rendered,
                       "Thursday 12 September, 14:00 to 15:00 — Design review @Room 4 "
                       + "/ ada@example.com [conference]\nDetails: Join video call",
                       "renderEvent appends the notes body it was given")
    }

    func testCalendarEventFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(CalendarParser().parse(try fixture("calendar-event"),
                                                         context: context("com.apple.iCal",
                                                                          "Calendar"))),
                     matches: "calendar-event-golden")
    }

    func testOffsetCalendarFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(CalendarParser().parse(try fixture("calendar-offset-event"),
                                                         context: context("com.apple.iCal",
                                                                          "Calendar"))),
                     matches: "calendar-offset-event-golden")
    }
}
