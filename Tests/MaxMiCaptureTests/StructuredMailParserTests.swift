import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class StructuredMailParserTests: XCTestCase {
    /// Two structured records in the MAXMI_MAIL_V2 wire format.
    func scriptOutput() -> String {
        let fs = MailParser.fieldSeparator
        let rs = MailParser.recordSeparator
        let first = ["<id-1>", "Taylor <taylor@example.com>", "Project update",
                     "Monday, 9 September 2026 at 09:20", "First body"].joined(separator: fs)
        let second = ["<id-2>", "Sam <sam@example.com>", "Project update",
                      "Monday, 9 September 2026 at 10:05", "Second body"].joined(separator: fs)
        return MailParser.structuredHeader + "\n" + [first, second].joined(separator: rs)
    }

    func testSelectedMessagesBecomeOneMessagePerRecord() throws {
        let extracted = try XCTUnwrap(MailParser.selectedMessageContent(
            fromScriptOutput: scriptOutput(), windowTitle: "Inbox"))
        guard case .conversation(let conversation) = extracted.content else {
            return XCTFail("expected .conversation")
        }
        XCTAssertEqual(conversation.channel, "Project update", "channel is the subject")
        XCTAssertFalse(conversation.isGroup)
        XCTAssertEqual(conversation.messages.map(\.sender),
                       ["Taylor <taylor@example.com>", "Sam <sam@example.com>"])
        XCTAssertEqual(conversation.messages.map(\.text), ["First body", "Second body"])
        XCTAssertEqual(conversation.messages.map(\.timeString),
                       ["Monday, 9 September 2026 at 09:20", "Monday, 9 September 2026 at 10:05"])
        XCTAssertTrue(extracted.sourceKey.hasPrefix("mail:thread:"))
        XCTAssertEqual(extracted.sourceTitle, "Project update")
    }

    func testSelectedMessageCaptureRendersTheConversationAndKeepsEmailKind() throws {
        let capture = try XCTUnwrap(MailParser.makeCapture(
            fromScriptOutput: scriptOutput(), windowTitle: "Inbox"))
        XCTAssertEqual(capture.contentKind, .email, "contentKind is not derived from the shape")
        XCTAssertEqual(capture.sourceApp, "Mail")
        XCTAssertEqual(capture.content, """
        (From: Taylor <taylor@example.com>)(sent Monday, 9 September 2026 at 09:20): First body
        (From: Sam <sam@example.com>)(sent Monday, 9 September 2026 at 10:05): Second body
        """)
        XCTAssertEqual(capture.content, ContentRenderer.render(
            try XCTUnwrap(capture.structured), style: .full))
    }

    func testMultiLineBodyKeepsItsLinesIndented() throws {
        let fs = MailParser.fieldSeparator
        let record = ["<id-3>", "Ana <ana@example.com>", "Two lines", "Tue 10:00",
                      "line one\nline two"].joined(separator: fs)
        let capture = try XCTUnwrap(MailParser.makeCapture(
            fromScriptOutput: MailParser.structuredHeader + "\n" + record, windowTitle: nil))
        XCTAssertEqual(capture.content,
                       "(From: Ana <ana@example.com>)(sent Tue 10:00): line one\n  line two")
    }

    func testInboxListingBecomesOneMessagePerLine() throws {
        let raw = "iCloud » A <a@x.com> | subj A\nExchange » B <b@y.com> | subj B"
        let capture = try XCTUnwrap(MailParser.makeCapture(fromScriptOutput: raw, windowTitle: nil))
        XCTAssertEqual(capture.sourceKey, "mail:inbox")
        XCTAssertEqual(capture.contentKind, .email)
        guard case .conversation(let conversation) = try XCTUnwrap(capture.structured) else {
            return XCTFail("expected .conversation")
        }
        XCTAssertEqual(conversation.channel, "Inbox")
        XCTAssertEqual(conversation.messages.map(\.sender), ["iCloud » A <a@x.com>", "Exchange » B <b@y.com>"])
        XCTAssertEqual(conversation.messages.map(\.text), ["subj A", "subj B"])
        XCTAssertEqual(capture.content, """
        (From: iCloud » A <a@x.com>): subj A
        (From: Exchange » B <b@y.com>): subj B
        """)
    }

    func testEmptyOutputStillReturnsNil() {
        XCTAssertNil(MailParser.makeCapture(fromScriptOutput: "", windowTitle: nil))
        XCTAssertNil(MailParser.makeCapture(fromScriptOutput: MailParser.structuredHeader, windowTitle: nil))
    }
}
