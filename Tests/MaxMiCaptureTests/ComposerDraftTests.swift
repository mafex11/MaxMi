import XCTest
@testable import MaxMiCapture
import MaxMiCore

final class ComposerDraftTests: XCTestCase {
    /// Same loader shape as `GenericPageBudgetTests.fixture`.
    private func fixture(_ name: String) throws -> AXNode {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"
        ))
        return try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
    }

    private func node(role: String, value: String?, identifier: String? = nil,
                      focused: Bool = false, subrole: String? = nil,
                      children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil, frame: nil, focused: focused,
               children: children, identifier: identifier, subrole: subrole)
    }

    func testPicksTheComposerAndNotTheFocusedRowTextArea() throws {
        let draft = try XCTUnwrap(ComposerDraft.draft(window: try fixture("slack-composer-draft")))
        XCTAssertEqual(draft.text, "shipping phase b today")
        XCTAssertEqual(draft.id, "draft:message-input")
        XCTAssertEqual(draft.sender, "You")
        XCTAssertTrue(draft.isUser)
        XCTAssertTrue(draft.isDraft)
        XCTAssertNil(draft.timestamp)
    }

    func testNoDraftWhenNothingIsFocused() {
        let window = node(role: "AXWindow", value: nil, children: [
            node(role: "AXTextArea", value: "not focused", identifier: "message-input"),
        ])
        XCTAssertNil(ComposerDraft.draft(window: window))
    }

    func testNoDraftForAnEmptyComposer() {
        let window = node(role: "AXWindow", value: nil, children: [
            node(role: "AXTextArea", value: "   ", identifier: "message-input", focused: true),
        ])
        XCTAssertNil(ComposerDraft.draft(window: window))
    }

    func testNoDraftForASecureField() {
        let window = node(role: "AXWindow", value: nil, children: [
            node(role: "AXTextField", value: "hunter2", identifier: "password", focused: true,
                 subrole: GenericPageExtractor.secureSubrole),
        ])
        XCTAssertNil(ComposerDraft.draft(window: window))
    }

    func testNoDraftForAFocusedFieldInsideAMessageListRow() {
        let window = node(role: "AXWindow", value: nil, children: [
            node(role: "AXList", value: nil, identifier: "message-list", children: [
                node(role: "AXRow", value: nil, children: [
                    node(role: "AXTextArea", value: "an edited bubble", identifier: "bubble",
                         focused: true),
                ]),
            ]),
        ])
        XCTAssertNil(ComposerDraft.draft(window: window))
    }

    /// The case the old rows/cells rule missed. Spec 5c disqualifies any descendant of the
    /// MESSAGE-LIST node, and plenty of chat surfaces parent an editable bubble directly to the
    /// list with no row wrapper — Electron re-renders in particular. Under a rows/cells-only test
    /// that field is read as the user's draft and attributed to `You`.
    func testNoDraftForAFocusedFieldParentedDirectlyByTheMessageList() {
        let window = node(role: "AXWindow", value: nil, children: [
            node(role: "AXList", value: nil, identifier: "message-list", children: [
                node(role: "AXTextArea", value: "somebody else's message, being edited",
                     identifier: "bubble", focused: true),
            ]),
        ])
        XCTAssertNil(ComposerDraft.draft(window: window))
    }

    /// A focused row OUTSIDE any list, table or outline is not a message list, so it is not
    /// disqualified — the rule is about the container, not about rows.
    func testAFocusedFieldInABareRowIsStillTheComposer() {
        let window = node(role: "AXWindow", value: nil, children: [
            node(role: "AXRow", value: nil, children: [
                node(role: "AXTextArea", value: "typed into a toolbar row", identifier: "input",
                     focused: true),
            ]),
        ])
        XCTAssertEqual(ComposerDraft.draft(window: window)?.text, "typed into a toolbar row")
    }

    func testMenuSubtreesAreNotSearched() {
        let window = node(role: "AXWindow", value: nil, children: [
            node(role: "AXMenu", value: nil, children: [
                node(role: "AXTextField", value: "spotlight query", focused: true),
            ]),
        ])
        XCTAssertNil(ComposerDraft.draft(window: window))
    }

    func testIdentifierFallsBackToTheRole() {
        let window = node(role: "AXWindow", value: nil, children: [
            node(role: "AXTextArea", value: "typed", focused: true),
        ])
        XCTAssertEqual(ComposerDraft.draft(window: window)?.id, "draft:AXTextArea")
    }

    func testSlackParserAppendsTheDraftAsTheLastMessage() throws {
        let app = AppInfo(bundleID: "com.tinyspeck.slackmacgap", name: "Slack",
                          windowTitle: "general - Invented Workspace - Slack")
        let content = try XCTUnwrap(
            SlackParser().parseStructured(window: try fixture("slack-composer-draft"), app: app))
        guard case .conversation(let conversation) = content else {
            return XCTFail("expected a conversation")
        }
        let last = try XCTUnwrap(conversation.messages.last)
        XCTAssertTrue(last.isDraft)
        XCTAssertEqual(last.text, "shipping phase b today")
        XCTAssertEqual(conversation.messages.filter(\.isDraft).count, 1)
        XCTAssertTrue(ContentRenderer.render(content, style: .full).contains("(draft)"))
    }
}
