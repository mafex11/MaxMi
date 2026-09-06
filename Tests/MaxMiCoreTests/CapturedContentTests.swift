import XCTest
@testable import MaxMiCore

final class CapturedContentTests: XCTestCase {
    func roundTrip(_ content: CapturedContent) throws -> CapturedContent {
        let json = try CapturedContentEnvelope.encode(content)
        return try XCTUnwrap(CapturedContentEnvelope.decode(json))
    }

    func testDocumentRoundTrip() throws {
        let content = CapturedContent.document(Document(
            title: "Design notes",
            blocks: [
                Block(type: .heading(level: 1), text: "Design notes"),
                Block(type: .paragraph, text: "First paragraph"),
                Block(type: .listItem(depth: 1), text: "Nested bullet"),
            ],
            author: .other("Ana"),
            url: nil
        ))
        XCTAssertEqual(try roundTrip(content), content)
    }

    func testConversationRoundTripKeepsMessageIdentity() throws {
        let content = CapturedContent.conversation(Conversation(
            channel: "#maxmi-dev",
            isGroup: true,
            messages: [
                Message(id: Message.makeID(sender: "Ana", timeString: "09:20", text: "ping"),
                        sender: "Ana", text: "ping", timestamp: nil, timeString: "09:20",
                        isUser: false, isDraft: false),
                Message(id: "draft:composer", sender: "You", text: "on it",
                        timestamp: nil, timeString: nil, isUser: true, isDraft: true),
            ]
        ))
        XCTAssertEqual(try roundTrip(content), content)
    }

    func testTasksCalendarTerminalGenericRoundTrip() throws {
        let tasks = CapturedContent.tasks([
            TaskItem(title: "Ship M8a", status: .open, due: nil, dueString: "Fri",
                     project: "MaxMi", tags: ["ship"], notes: "two lines\nsecond"),
            TaskItem(title: "Done thing", status: .completed, due: nil, dueString: nil,
                     project: nil, tags: [], notes: nil),
        ])
        XCTAssertEqual(try roundTrip(tasks), tasks)

        let calendar = CapturedContent.calendar([
            CalendarEvent(title: "Daily Sync", dateString: "Mon 09:00", start: nil, end: nil,
                          organizer: "Ana", location: "Room 2", hasConference: true,
                          notes: "agenda line one\nagenda line two"),
            CalendarEvent(title: "Solo block", dateString: "Mon 11:00", start: nil, end: nil,
                          organizer: nil, location: nil, hasConference: false, notes: nil),
        ])
        XCTAssertEqual(try roundTrip(calendar), calendar)

        let terminal = CapturedContent.terminal(TerminalSession(cwd: "maxmi", segments: [
            TerminalSegment(command: "swift test", output: "2 failures", isRunning: false),
            TerminalSegment(command: nil, output: "raw blob", isRunning: true),
        ]))
        XCTAssertEqual(try roundTrip(terminal), terminal)

        let generic = CapturedContent.generic(GenericPage(
            regions: [
                Region(kind: .main, blocks: [Block(type: .tableRow(cells: ["a", "b"], selected: true), text: "a b")]),
                Region(kind: .sidebar, blocks: [Block(type: .label, text: "Downloads")]),
            ],
            focused: FocusedElement(role: "AXTextField", identifier: "search", value: "vec0",
                                    selectedText: "vec", isSecure: false),
            url: "https://example.com/a"
        ))
        XCTAssertEqual(try roundTrip(generic), generic)
    }

    func testAuthorshipAndInputPayloadsRoundTrip() throws {
        for author in [Authorship.user, .other("Ana"), .unknown] {
            let content = CapturedContent.document(Document(
                title: "T",
                blocks: [Block(type: .input(placeholder: "Search"), text: "", authoredByUser: true)],
                author: author, url: nil
            ))
            XCTAssertEqual(try roundTrip(content), content)
        }
    }

    func testEncodingIsDeterministic() throws {
        let content = CapturedContent.generic(GenericPage(
            regions: [Region(kind: .main, blocks: [
                Block(type: .paragraph, text: "slash / and unicode ✓"),
                Block(type: .heading(level: 3), text: "h3"),
            ])],
            focused: nil,
            url: "https://example.com/a/b"
        ))
        let first = try CapturedContentEnvelope.encode(content)
        let second = try CapturedContentEnvelope.encode(content)
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.contains("https://example.com/a/b"), "slashes are not escaped")
        XCTAssertTrue(first.hasPrefix("{\"content\""), "keys are sorted, so `content` precedes `v`")
    }

    func testDecodeRejectsFutureSchemaVersionAndGarbage() {
        XCTAssertNil(CapturedContentEnvelope.decode("{\"v\":2,\"content\":{\"generic\":{\"_0\":{\"regions\":[]}}}}"))
        XCTAssertNil(CapturedContentEnvelope.decode("not json"))
        XCTAssertNil(CapturedContentEnvelope.decode(""))
    }

    func testKindDefaultsPerShape() {
        XCTAssertEqual(CapturedContent.document(Document(title: "t", blocks: [], author: .unknown, url: nil)).kind, .document)
        XCTAssertEqual(CapturedContent.conversation(Conversation(channel: "c", isGroup: false, messages: [])).kind, .conversation)
        XCTAssertEqual(CapturedContent.tasks([]).kind, .task)
        XCTAssertEqual(CapturedContent.calendar([]).kind, .calendar)
        XCTAssertEqual(CapturedContent.terminal(TerminalSession(cwd: nil, segments: [])).kind, .terminal)
        XCTAssertEqual(CapturedContent.generic(GenericPage(regions: [], focused: nil, url: nil)).kind, .generic)
    }

    func testMakeIDIsStableAndOrderIndependent() {
        let a = Message.makeID(sender: "Ana", timeString: "09:20", text: "ping")
        let b = Message.makeID(sender: "Ana", timeString: "09:20", text: "ping")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 24)
        XCTAssertNotEqual(a, Message.makeID(sender: "Ana", timeString: nil, text: "ping"))
        XCTAssertNotEqual(a, Message.makeID(sender: "Bo", timeString: "09:20", text: "ping"))
    }

    func testBlockAuthoredByUserDefaultsFalseAndDecodesWhenAbsent() throws {
        XCTAssertFalse(Block(type: .paragraph, text: "x").authoredByUser)
        let decoder = JSONDecoder()
        let block = try decoder.decode(Block.self, from: Data("{\"type\":{\"paragraph\":{}},\"text\":\"x\"}".utf8))
        XCTAssertFalse(block.authoredByUser)
    }
}
