import XCTest
@testable import MaxMiCapture

final class MailParserTests: XCTestCase {
    // MailParser sources data via AppleScript (Mail's AX tree is too slow to walk), so tests
    // exercise the pure output→capture transform with realistic osascript output.

    func testParsesAccountAttributedLines() throws {
        let raw = """
        iCloud » Blinkist <hello@mail.blinkist.com> | Closes tomorrow — 75% off
        sudhanshu@layerpath.com » vercel[bot] <notifications@github.com> | Re: [PR #2106]
        paymafex@gmail.com » Team Razorpay <noreply@razorpay.com> | Update your KYC
        """
        let cap = try XCTUnwrap(MailParser.makeCapture(fromScriptOutput: raw, windowTitle: "Inbox"))
        XCTAssertEqual(cap.sourceApp, "Mail")
        XCTAssertEqual(cap.sourceKey, "mail:inbox")
        XCTAssertTrue(cap.content.contains("Blinkist"))
        XCTAssertTrue(cap.content.contains("layerpath.com » vercel[bot]"))
        XCTAssertTrue(cap.content.contains("Razorpay"))
    }

    func testEmptyOutputReturnsNil() {
        XCTAssertNil(MailParser.makeCapture(fromScriptOutput: "", windowTitle: "Inbox"))
        XCTAssertNil(MailParser.makeCapture(fromScriptOutput: "   \n  \n", windowTitle: "Inbox"))
    }

    func testContentCappedNewestPreserved() throws {
        // Large fallback feed is bounded and keeps its newest tail.
        let raw = (1...1_000).map { "acct » sender\($0) | subject line number \($0) padding padding" }
            .joined(separator: "\n")
        let cap = try XCTUnwrap(MailParser.makeCapture(fromScriptOutput: raw, windowTitle: nil))
        XCTAssertLessThanOrEqual(cap.content.count, 32_000)
        XCTAssertTrue(cap.content.contains("number 1000"), "newest kept")
        XCTAssertFalse(cap.content.contains("number 1 "), "oldest dropped")
    }

    func testBlankLinesFiltered() throws {
        let raw = "iCloud » A <a@x.com> | subj A\n\n\nExchange » B <b@y.com> | subj B\n"
        let cap = try XCTUnwrap(MailParser.makeCapture(fromScriptOutput: raw, windowTitle: nil))
        XCTAssertEqual(cap.content, "iCloud » A <a@x.com> | subj A\nExchange » B <b@y.com> | subj B")
    }

    func testSelectedVisibleMessageIncludesBodyAndStableHashedKey() throws {
        let fs = MailParser.fieldSeparator
        let rs = MailParser.recordSeparator
        let raw = "\(MailParser.structuredHeader)\nmessage-123\(fs)Taylor <t@example.com>\(fs)Project update\(fs)Tuesday, 14 July 2026\(fs)The milestone is ready for review.\(rs)"
        let capture = try XCTUnwrap(MailParser.makeCapture(
            fromScriptOutput: raw, windowTitle: "Inbox"
        ))
        XCTAssertEqual(capture.sourceTitle, "Project update")
        XCTAssertTrue(capture.sourceKey.hasPrefix("mail:thread:"))
        XCTAssertFalse(capture.sourceKey.contains("Taylor"))
        XCTAssertEqual(capture.content, """
        From: Taylor <t@example.com>
        Subject: Project update
        Date: Tuesday, 14 July 2026
        The milestone is ready for review.
        """)
        XCTAssertEqual(capture.parserVersion, 2)
    }

    func testSelectedThreadKeepsMessageBoundaries() throws {
        let fs = MailParser.fieldSeparator
        let rs = MailParser.recordSeparator
        let raw = "\(MailParser.structuredHeader)\na\(fs)Alex\(fs)Topic\(fs)Monday\(fs)First body\(rs)b\(fs)Sam\(fs)Re: Topic\(fs)Tuesday\(fs)Reply body\(rs)"
        let capture = try XCTUnwrap(MailParser.makeCapture(fromScriptOutput: raw, windowTitle: nil))
        XCTAssertTrue(capture.content.contains("First body\n\n---\n\nFrom: Sam"))
    }
}
