import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class MailComposeDraftTests: XCTestCase {
    func node(_ role: String, value: String? = nil, identifier: String? = nil,
              children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil,
               frame: CGRect(x: 0, y: 0, width: 600, height: 400), focused: false,
               children: children, identifier: identifier, label: nil)
    }

    /// A Mail compose window: the subject field plus the body text area.
    func composeWindow(subject: String, body: String?) -> AXNode {
        var children = [node("AXTextField", value: subject, identifier: "Mail.subjectField")]
        if let body { children.append(node("AXTextArea", value: body)) }
        return node("AXWindow", children: children)
    }

    func conversation(_ content: CapturedContent?) throws -> Conversation {
        guard case .conversation(let c) = try XCTUnwrap(content) else {
            throw XCTSkip("expected .conversation, got \(String(describing: content))")
        }
        return c
    }

    func testComposeWindowBecomesASingleUserDraftKeyedOnTheSubject() throws {
        let c = try conversation(MailParser.composeDraft(
            window: composeWindow(subject: "Re: index rebuild", body: "Shipping the fix today.")))
        XCTAssertEqual(c.channel, "Re: index rebuild")
        XCTAssertFalse(c.isGroup)
        XCTAssertEqual(c.messages.count, 1)
        let draft = c.messages[0]
        XCTAssertTrue(draft.isDraft)
        XCTAssertTrue(draft.isUser)
        XCTAssertEqual(draft.sender, "You")
        XCTAssertEqual(draft.text, "Shipping the fix today.")
    }

    func testAnEmptyBodyStillProducesADraftSoTheSubjectIsCaptured() throws {
        let c = try conversation(MailParser.composeDraft(
            window: composeWindow(subject: "Quick question", body: nil)))
        XCTAssertEqual(c.channel, "Quick question")
        XCTAssertEqual(c.messages[0].text, "")
    }

    func testAnEmptySubjectAndEmptyBodyIsNotADraft() {
        XCTAssertNil(MailParser.composeDraft(window: composeWindow(subject: "   ", body: "  ")),
                     "an untouched compose window carries no information")
    }

    func testEmptyComposeWindowRefusesThroughTheStructuredBridge() {
        let app = AppInfo(bundleID: ParserRegistry.mailBundleID, name: "Mail", windowTitle: "New Message")
        XCTAssertThrowsError(try MailParser().parseStructured(
            window: composeWindow(subject: "   ", body: "  "), app: app
        )) {
            XCTAssertEqual($0 as? ParserRefusal, ParserRefusal(reason: "empty-compose-draft"))
        }
    }

    func testAWindowWithoutTheSubjectFieldIsNotAComposeWindow() {
        let reading = node("AXWindow", children: [
            node("AXTextArea", value: "the message you are reading"),
            node("AXTextField", value: "search", identifier: "Mail.searchField"),
        ])
        XCTAssertNil(MailParser.composeDraft(window: reading),
                     "no Mail.subjectField means the AppleScript path must run untouched")
    }

    func testTheSubjectFieldIsMatchedByExactIdentifier() {
        let lookalike = node("AXWindow", children: [
            node("AXTextField", value: "x", identifier: "Mail.subjectFieldContainer"),
        ])
        XCTAssertNil(MailParser.composeDraft(window: lookalike))
    }

    func testParseStructuredPrefersTheComposeDraftOverTheAppleScriptBody() throws {
        let app = AppInfo(bundleID: ParserRegistry.mailBundleID, name: "Mail",
                          windowTitle: "Re: index rebuild")
        let content = try MailParser().parseStructured(
            window: composeWindow(subject: "Re: index rebuild", body: "Shipping the fix today."),
            app: app)
        let c = try conversation(content)
        XCTAssertEqual(c.channel, "Re: index rebuild")
        XCTAssertTrue(c.messages.allSatisfy(\.isDraft),
                      "a frontmost compose window is what the user is doing right now")
    }

    func testSourceParserBridgeRendersTheComposeDraft() throws {
        let app = AppInfo(bundleID: ParserRegistry.mailBundleID, name: "Mail",
                          windowTitle: "Re: index rebuild")
        let capture = try XCTUnwrap(try MailParser().parse(
            window: composeWindow(subject: "Re: index rebuild", body: "Shipping the fix today."),
            app: app
        ))
        XCTAssertEqual(capture.contentKind, .email)
        XCTAssertTrue(capture.content.contains("Shipping the fix today."))
        XCTAssertEqual(capture.structured, try MailParser().parseStructured(
            window: composeWindow(subject: "Re: index rebuild", body: "Shipping the fix today."),
            app: app
        ))
    }
}
