import XCTest
@testable import MaxMiCore

final class ContentRendererTests: XCTestCase {
    func full(_ content: CapturedContent) -> String { ContentRenderer.render(content, style: .full) }

    func testDocumentGolden() {
        let content = CapturedContent.document(Document(
            title: "Design notes",
            blocks: [
                Block(type: .paragraph, text: "Intro line"),
                Block(type: .heading(level: 2), text: "Regions"),
                Block(type: .listItem(depth: 0), text: "top"),
                Block(type: .listItem(depth: 1), text: "nested"),
            ],
            author: .user, url: nil
        ))
        XCTAssertEqual(full(content), "# Design notes\n\nIntro line\n## Regions\n- top\n  - nested")
    }

    func testDocumentWithNoBlocksIsJustTheTitle() {
        let content = CapturedContent.document(Document(title: "Empty", blocks: [], author: .unknown, url: nil))
        XCTAssertEqual(full(content), "# Empty")
    }

    func testConversationGoldenUsesYouAndSentClause() {
        let content = CapturedContent.conversation(Conversation(channel: "#maxmi-dev", isGroup: true, messages: [
            Message(id: "1", sender: "Ana", text: "ping", timestamp: nil, timeString: "09:20",
                    isUser: false, isDraft: false),
            Message(id: "2", sender: "Sudhanshu", text: "on it", timestamp: nil, timeString: nil,
                    isUser: true, isDraft: false),
            Message(id: "3", sender: "Sudhanshu", text: "typing this", timestamp: nil, timeString: nil,
                    isUser: true, isDraft: true),
        ]))
        XCTAssertEqual(full(content), """
        (From: Ana)(sent 09:20): ping
        (From: You): on it
        (From: You (draft)): typing this
        """)
    }

    func testConversationNeverRendersUserMarker() {
        let content = CapturedContent.conversation(Conversation(channel: "c", isGroup: false, messages: [
            Message(id: "1", sender: "[user]", text: "hi", timestamp: nil, timeString: nil,
                    isUser: true, isDraft: false),
        ]))
        XCTAssertFalse(full(content).contains("[user]"), "isUser renders as You, never as the internal marker")
        XCTAssertEqual(full(content), "(From: You): hi")
    }

    func testConversationFormatsTimestampWhenTimeStringMissing() {
        let date = Date(timeIntervalSince1970: 1_757_000_000)
        let content = CapturedContent.conversation(Conversation(channel: "c", isGroup: false, messages: [
            Message(id: "1", sender: "Ana", text: "hi", timestamp: date, timeString: nil,
                    isUser: false, isDraft: false),
        ]))
        XCTAssertEqual(full(content), "(From: Ana)(sent \(ContentRenderer.formatTimestamp(date))): hi")
        XCTAssertNotNil(ContentRenderer.formatTimestamp(date)
            .range(of: "^[A-Z][a-z]{2} [0-9]{1,2}, [0-9]{2}:[0-9]{2} .+$", options: .regularExpression),
            "MMM d, HH:mm zzz")
    }

    func testConversationIndentsContinuationLines() {
        let content = CapturedContent.conversation(Conversation(channel: "c", isGroup: false, messages: [
            Message(id: "1", sender: "Ana", text: "line one\nline two", timestamp: nil, timeString: nil,
                    isUser: false, isDraft: false),
        ]))
        XCTAssertEqual(full(content), "(From: Ana): line one\n  line two")
    }

    func testTasksGolden() {
        let content = CapturedContent.tasks([
            TaskItem(title: "Ship M8a", status: .open, due: nil, dueString: "Fri",
                     project: "MaxMi", tags: ["ship", "m8"], notes: "note a\nnote b"),
            TaskItem(title: "Done thing", status: .completed, due: nil, dueString: nil,
                     project: nil, tags: [], notes: nil),
            TaskItem(title: "Maybe", status: .unknown, due: nil, dueString: nil,
                     project: nil, tags: [], notes: nil),
        ])
        XCTAssertEqual(full(content), """
        - [ ] Ship M8a (due Fri) [MaxMi] #ship #m8
          note a
          note b
        - [x] Done thing
        - Maybe
        """)
    }

    func testCalendarGolden() {
        let content = CapturedContent.calendar([
            CalendarEvent(title: "Daily Sync", dateString: "Mon 09:00", start: nil, end: nil,
                          organizer: "Ana", location: "Room 2", hasConference: true,
                          notes: "Bring the metrics"),
            CalendarEvent(title: "Solo block", dateString: "Mon 11:00", start: nil, end: nil,
                          organizer: nil, location: nil, hasConference: false, notes: nil),
        ])
        XCTAssertEqual(full(content), """
        Mon 09:00 — Daily Sync @Room 2 / Ana [conference]
        Details: Bring the metrics
        Mon 11:00 — Solo block
        """)
    }

    func testEventWithoutADateStringOmitsTheSeparator() {
        let content = CapturedContent.calendar([
            CalendarEvent(title: "Untimed reminder", dateString: "", start: nil, end: nil,
                          organizer: nil, location: "Room 2", hasConference: false, notes: nil),
        ])
        XCTAssertEqual(full(content), "Untimed reminder @Room 2",
                       "an absent date must not print as a leading em dash")
    }

    func testCalendarNotesKeepFurtherLinesIndented() {
        let content = CapturedContent.calendar([
            CalendarEvent(title: "Review", dateString: "Tue 14:00", start: nil, end: nil,
                          organizer: nil, location: nil, hasConference: false,
                          notes: "line one\nline two"),
        ])
        XCTAssertEqual(full(content), "Tue 14:00 — Review\nDetails: line one\n  line two")
    }

    func testTerminalGolden() {
        let content = CapturedContent.terminal(TerminalSession(cwd: "maxmi", segments: [
            TerminalSegment(command: "swift test", output: "2 failures", isRunning: false),
            TerminalSegment(command: "swift build", output: "compiling", isRunning: true),
        ]))
        XCTAssertEqual(full(content), "$ swift test\n2 failures\n\n$ swift build\ncompiling\n… (running)")
    }

    func testTerminalSegmentWithoutCommandRendersOutputOnly() {
        let content = CapturedContent.terminal(TerminalSession(cwd: nil, segments: [
            TerminalSegment(command: nil, output: "raw blob", isRunning: false),
        ]))
        XCTAssertEqual(full(content), "raw blob")
    }

    func testGenericRegionOrderAndHeaders() {
        let content = CapturedContent.generic(GenericPage(regions: [
            Region(kind: .footer, blocks: [Block(type: .paragraph, text: "foot")]),
            Region(kind: .sidebar, blocks: [Block(type: .label, text: "Downloads")]),
            Region(kind: .main, blocks: [Block(type: .paragraph, text: "body")]),
            Region(kind: .dialog, blocks: [Block(type: .paragraph, text: "Quit?")]),
            Region(kind: .navigation, blocks: [Block(type: .label, text: "Back")]),
            Region(kind: .toolbar, blocks: [Block(type: .paragraph, text: "Uploading 34 items")]),
            Region(kind: .banner, blocks: [Block(type: .paragraph, text: "Offline")]),
            Region(kind: .unknown, blocks: [Block(type: .paragraph, text: "stray")]),
        ], focused: nil, url: "https://example.com/a"))
        XCTAssertEqual(full(content), """
        URL: https://example.com/a
        body
        ## Dialog
        Quit?
        ## Sidebar
        Downloads
        ## Navigation
        Back
        ## Toolbar
        Uploading 34 items
        ## Banner
        Offline
        ## Footer
        foot
        ## Other
        stray
        """)
    }

    func testBlockRenderingRules() {
        XCTAssertEqual(ContentRenderer.renderBlock(Block(type: .heading(level: 3), text: "h")), "### h")
        XCTAssertEqual(ContentRenderer.renderBlock(Block(type: .heading(level: 9), text: "h")), "###### h")
        XCTAssertEqual(ContentRenderer.renderBlock(Block(type: .heading(level: 0), text: "h")), "# h")
        XCTAssertEqual(ContentRenderer.renderBlock(Block(type: .label, text: "Send")), "Send")
        XCTAssertEqual(
            ContentRenderer.renderBlock(Block(type: .tableRow(cells: ["a", "b", "c"], selected: false), text: "")),
            "a | b | c")
        XCTAssertEqual(
            ContentRenderer.renderBlock(Block(type: .tableRow(cells: ["a", "b"], selected: true), text: "")),
            "* a | b")
        XCTAssertEqual(ContentRenderer.renderBlock(Block(type: .input(placeholder: "Search"), text: "")), "«Search»")
        XCTAssertEqual(ContentRenderer.renderBlock(Block(type: .input(placeholder: nil), text: "")), "«empty field»")
        XCTAssertEqual(ContentRenderer.renderBlock(Block(type: .input(placeholder: "Search"), text: "vec0")), "vec0")
    }

    func testCompactBoundsWithHeadAndTail() {
        let messages = (0..<40).map {
            Message(id: "\($0)", sender: "Ana", text: "message number \($0)", timestamp: nil,
                    timeString: nil, isUser: false, isDraft: false)
        }
        let content = CapturedContent.conversation(Conversation(channel: "c", isGroup: true, messages: messages))
        let compact = ContentRenderer.render(content, style: .compact(maxChars: 300))
        XCTAssertEqual(compact.count, 300)
        XCTAssertTrue(compact.contains("\n…\n"))
        XCTAssertTrue(compact.hasPrefix("(From: Ana): message number 0"), "identity-bearing head survives")
        XCTAssertTrue(compact.hasSuffix("message number 39"), "recent tail survives")
    }

    func testMainOnlyKeepsMainAndDialogWithoutHeaders() {
        let content = CapturedContent.generic(GenericPage(regions: [
            Region(kind: .sidebar, blocks: [Block(type: .label, text: "Downloads")]),
            Region(kind: .main, blocks: [Block(type: .paragraph, text: "body")]),
            Region(kind: .dialog, blocks: [Block(type: .paragraph, text: "Quit?")]),
        ], focused: nil, url: "https://example.com/a"))
        XCTAssertEqual(ContentRenderer.render(content, style: .mainOnly(maxChars: 1_000)), "body\nQuit?")
    }

    func testMainOnlyConcatenatesEveryMainAndDialogRegionInOrder() {
        let content = CapturedContent.generic(GenericPage(regions: [
            Region(kind: .dialog, blocks: [Block(type: .paragraph, text: "Quit?")]),
            Region(kind: .main, blocks: [Block(type: .paragraph, text: "first")]),
            Region(kind: .sidebar, blocks: [Block(type: .label, text: "Downloads")]),
            Region(kind: .main, blocks: [Block(type: .paragraph, text: "second")]),
        ], focused: nil, url: nil))
        XCTAssertEqual(ContentRenderer.render(content, style: .mainOnly(maxChars: 1_000)),
                       "first\nsecond\nQuit?",
                       "every region of a kind is kept, in regionOrder, like .full does")
    }

    func testMainOnlyFallsBackToCompactForNonGenericShapes() {
        let content = CapturedContent.terminal(TerminalSession(cwd: nil, segments: [
            TerminalSegment(command: "ls", output: "a", isRunning: false),
        ]))
        XCTAssertEqual(ContentRenderer.render(content, style: .mainOnly(maxChars: 1_000)),
                       ContentRenderer.render(content, style: .compact(maxChars: 1_000)))
    }

    func testEmptyGenericPageRendersEmptyString() {
        XCTAssertEqual(full(.generic(GenericPage(regions: [], focused: nil, url: nil))), "")
    }
}
