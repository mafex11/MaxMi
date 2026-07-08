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
        // 400 lines; cap at 8000 chars, keep the tail (newest AppleScript lines are last)
        let raw = (1...400).map { "acct » sender\($0) | subject line number \($0) padding padding" }
            .joined(separator: "\n")
        let cap = try XCTUnwrap(MailParser.makeCapture(fromScriptOutput: raw, windowTitle: nil))
        XCTAssertLessThanOrEqual(cap.content.count, 8000)
        XCTAssertTrue(cap.content.contains("number 400"), "newest kept")
        XCTAssertFalse(cap.content.contains("number 1 "), "oldest dropped")
    }

    func testBlankLinesFiltered() throws {
        let raw = "iCloud » A <a@x.com> | subj A\n\n\nExchange » B <b@y.com> | subj B\n"
        let cap = try XCTUnwrap(MailParser.makeCapture(fromScriptOutput: raw, windowTitle: nil))
        XCTAssertEqual(cap.content, "iCloud » A <a@x.com> | subj A\nExchange » B <b@y.com> | subj B")
    }
}
