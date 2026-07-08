import XCTest
@testable import MaxMiCapture

final class NoSilentFallbackTests: XCTestCase {
    // A Slack window whose message area is empty -> SlackParser returns nil.
    func testRegisteredParserNilDoesNotFallThroughToGeneric() {
        // bare Slack window: has static text (so generic WOULD produce something) but no AXRow messages
        let win = AXNode(role: "AXWindow", value: nil, title: "x - y - Slack", url: nil, frame: nil, focused: false,
            children: [AXNode(role: "AXStaticText", value: "sidebar noise", title: nil, url: nil,
                              frame: CGRect(x:0,y:0,width:1,height:1), focused: false, children: [])])
        let app = AppInfo(bundleID: ParserRegistry.slackBundleID, name: "Slack", windowTitle: "x - y - Slack")
        // SlackParser finds no AXRow -> nil; dispatch must NOT run GenericAXParser (which would capture "sidebar noise")
        XCTAssertNil(CaptureDispatch.parse(window: win, app: app, registry: ParserRegistry()))
    }
    func testUnregisteredAppUsesGeneric() {
        let win = AXNode(role: "AXWindow", value: nil, title: "Note", url: nil, frame: nil, focused: false,
            children: [AXNode(role: "AXStaticText", value: "note body", title: nil, url: nil,
                              frame: CGRect(x:0,y:0,width:1,height:1), focused: false, children: [])])
        let app = AppInfo(bundleID: "com.apple.Notes", name: "Notes", windowTitle: "Note")
        let cap = CaptureDispatch.parse(window: win, app: app, registry: ParserRegistry())
        XCTAssertEqual(cap?.content, "note body")
        XCTAssertEqual(cap?.sourceApp, "Notes")
    }
}
