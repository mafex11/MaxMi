import XCTest
@testable import MaxMiCapture

final class DocumentParsersTests: XCTestCase {
    func n(_ role: String, _ value: String? = nil, _ y: CGFloat = 0, _ kids: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil,
               frame: CGRect(x: 0, y: y, width: 10, height: 10), focused: false, children: kids)
    }
    func win(_ body: [AXNode]) -> AXNode { n("AXWindow", nil, 0, body) }
    func genericWindow(_ body: [AXNode]) -> AXNode {
        AXNode(role: "AXWindow", value: nil, title: nil, url: nil,
               frame: CGRect(x: 0, y: 0, width: 800, height: 600),
               focused: false, children: body)
    }

    func testNotionWithoutFrameFallsThroughToGenericCapture() throws {
        let app = AppInfo(bundleID: "notion.id", name: "Notion", windowTitle: "June LP")
        let window = genericWindow([n("AXTextArea", "Anime list", 10)])
        XCTAssertNil(try NotionParser().parse(window: window, app: app))
        let expected = try XCTUnwrap(try GenericAXParser().parse(window: window, app: app))
        let capture = try XCTUnwrap(CaptureDispatch.parse(
            window: window, app: app, registry: ParserRegistry()))
        XCTAssertEqual(capture, expected)
        XCTAssertEqual(capture.sourceKey, "notion.id:June LP")
    }
    func testObsidianKeyFromTitleParts() throws {
        let app = AppInfo(bundleID: "md.obsidian", name: "Obsidian", windowTitle: "Welcome - My Vault - Obsidian 1.12.7")
        let cap = try XCTUnwrap(try ObsidianParser().parse(window: win([n("AXStaticText", "note body", 10)]), app: app))
        XCTAssertEqual(cap.sourceApp, "Obsidian")
        XCTAssertEqual(cap.sourceKey, "obsidian:my-vault/welcome")
    }
    func testObsidianUnexpectedTitleFallsBack() throws {
        let app = AppInfo(bundleID: "md.obsidian", name: "Obsidian", windowTitle: "Obsidian")
        let cap = try XCTUnwrap(try ObsidianParser().parse(window: win([n("AXStaticText", "x", 10)]), app: app))
        XCTAssertEqual(cap.sourceKey, "obsidian:obsidian")
    }
    func testObsidianNoteTitleWithDashes() throws {
        let app = AppInfo(bundleID: "md.obsidian", name: "Obsidian", windowTitle: "Meeting - Q4 - Work Vault - Obsidian 1.7")
        let cap = try XCTUnwrap(try ObsidianParser().parse(window: win([n("AXStaticText", "notes", 10)]), app: app))
        XCTAssertEqual(cap.sourceKey, "obsidian:work-vault/meeting---q4")
    }
    func testNotesWithoutBodyAnchorFallsThroughToGenericCapture() throws {
        let app = AppInfo(bundleID: "com.apple.Notes", name: "Notes", windowTitle: "Groceries")
        let window = genericWindow([n("AXStaticText", "milk eggs", 10)])
        XCTAssertNil(try NotesParser().parse(window: window, app: app))
        let expected = try XCTUnwrap(try GenericAXParser().parse(window: window, app: app))
        let capture = try XCTUnwrap(CaptureDispatch.parse(
            window: window, app: app, registry: ParserRegistry()))
        XCTAssertEqual(capture, expected)
        XCTAssertEqual(capture.sourceKey, "com.apple.Notes:Groceries")
    }
    func testEmptyBodyReturnsNil() throws {
        let app = AppInfo(bundleID: "notion.id", name: "Notion", windowTitle: "Empty")
        XCTAssertNil(try NotionParser().parse(window: win([n("AXButton")]), app: app))
    }
    func testNotesWithoutBodyAnchorAndTitleFallsThroughToGenericCapture() throws {
        let app = AppInfo(bundleID: "com.apple.Notes", name: "Notes", windowTitle: nil)
        let window = genericWindow([n("AXStaticText", "x", 10)])
        XCTAssertNil(try NotesParser().parse(window: window, app: app))
        let expected = try XCTUnwrap(try GenericAXParser().parse(window: window, app: app))
        let capture = try XCTUnwrap(CaptureDispatch.parse(
            window: window, app: app, registry: ParserRegistry()))
        XCTAssertEqual(capture, expected)
        XCTAssertEqual(capture.sourceKey, "com.apple.Notes:window")
    }
}
