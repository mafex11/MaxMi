import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class GenericV2ParserTests: XCTestCase {
    func text(_ value: String, y: CGFloat) -> AXNode {
        AXNode(role: "AXStaticText", value: value, title: nil, url: nil,
               frame: CGRect(x: 300, y: y, width: 400, height: 16), focused: false, children: [])
    }

    func body(_ children: [AXNode], title: String?) -> AXNode {
        AXNode(role: "AXWindow", value: nil, title: title, url: nil,
               frame: CGRect(x: 0, y: 0, width: 1_200, height: 800), focused: false,
               children: children)
    }

    /// Every parser here keeps a contentKind that the `.generic` shape cannot imply.
    func testSevenPageParsersProduceGenericStructureWithTheirOwnKind() throws {
        let document = body([
            AXNode(role: "AXHeading", value: "Heading one", title: nil, url: nil,
                   frame: CGRect(x: 300, y: 10, width: 400, height: 24), focused: false,
                   children: [], headingLevel: 1),
            text("body line", y: 40),
        ], title: nil)
        let cases: [(parser: any SourceParser, app: AppInfo, kind: CaptureContentKind, label: String)] = [
            (NotesParser(), AppInfo(bundleID: "com.apple.Notes", name: "Notes", windowTitle: "Groceries"), .document, "Notes"),
            (NotionParser(), AppInfo(bundleID: "notion.id", name: "Notion", windowTitle: "June LP"), .document, "Notion"),
            (ObsidianParser(), AppInfo(bundleID: "md.obsidian", name: "Obsidian", windowTitle: "Welcome - My Vault - Obsidian v1.5"), .document, "Obsidian"),
            (WordParser(), AppInfo(bundleID: "com.microsoft.Word", name: "Word", windowTitle: "Brief - Microsoft Word"), .document, "Word"),
            (PagesParser(), AppInfo(bundleID: "com.apple.iWork.Pages", name: "Pages", windowTitle: "Brief - Pages"), .document, "Pages"),
            (OutlookParser(), AppInfo(bundleID: "com.microsoft.Outlook", name: "Outlook", windowTitle: "Project update"), .email, "Outlook"),
            (SparkParser(), AppInfo(bundleID: "com.readdle.SparkDesktop", name: "Spark", windowTitle: "Project update"), .email, "Spark"),
        ]
        for entry in cases {
            let structured = try XCTUnwrap(
                try entry.parser.parseStructured(window: document, app: entry.app), entry.label)
            XCTAssertEqual(structured.kind, .generic, entry.label)
            let capture = try XCTUnwrap(try entry.parser.parse(window: document, app: entry.app), entry.label)
            XCTAssertEqual(capture.contentKind, entry.kind,
                           "\(entry.label) must keep its contentKind override")
            XCTAssertEqual(capture.structured, structured, entry.label)
            XCTAssertEqual(capture.content, ContentRenderer.render(structured, style: .full), entry.label)
            // Whole-page v2 semantics: each extraction supersedes the previous one.
            XCTAssertEqual(capture.accumulationPolicy, .replace, entry.label)
        }
    }

    func testDocumentParsersNowSeeHeadingsAndKeepTheirKeys() throws {
        let window = body([
            AXNode(role: "AXHeading", value: "Groceries", title: nil, url: nil,
                   frame: CGRect(x: 300, y: 10, width: 400, height: 24), focused: false,
                   children: [], headingLevel: 2),
            text("milk", y: 40),
        ], title: "Groceries")
        let app = AppInfo(bundleID: "com.apple.Notes", name: "Notes", windowTitle: "Groceries")
        let capture = try XCTUnwrap(try NotesParser().parse(window: window, app: app))
        XCTAssertEqual(capture.sourceKey, "notes:groceries")
        XCTAssertEqual(capture.content, "## Groceries\nmilk",
                       "generic v2 sees the heading level DocumentExtraction threw away")
        XCTAssertEqual(capture.accumulationPolicy, .replace)
    }

    func testDiscordKeepsItsOwnChromeFilteringWrappedInGenericBlocks() throws {
        let window = body([
            text("Add Reaction", y: 10),
            text("Ana", y: 30),
            text("Great work everyone!", y: 50),
        ], title: "#general | Acme - Discord")
        let app = AppInfo(bundleID: ParserRegistry.discordBundleID, name: "Discord",
                          windowTitle: "#general | Acme - Discord")
        let capture = try XCTUnwrap(try DiscordParser().parse(window: window, app: app))
        XCTAssertEqual(capture.contentKind, .conversation)
        XCTAssertFalse(capture.content.contains("Add Reaction"),
                       "the app-specific chrome filter is preserved")
        XCTAssertTrue(capture.content.contains("Great work everyone!"))
        guard case .generic(let page) = try XCTUnwrap(capture.structured) else {
            return XCTFail("expected .generic")
        }
        XCTAssertEqual(page.regions.map(\.kind), [.main])
        XCTAssertEqual(page.regions[0].blocks.map(\.type),
                       Array(repeating: BlockType.paragraph, count: page.regions[0].blocks.count))
        XCTAssertEqual(capture.content, ContentRenderer.render(capture.structured!, style: .full))
        // Task 9's accumulation bridge keys on this pair, which is what keeps cross-window
        // appending alive until the anchored parser lands in Phase D.
        XCTAssertTrue(try XCTUnwrap(capture.structured).isLegacyShaped)
        XCTAssertEqual(capture.accumulationPolicy, .appendItems)
    }

    func testMessagesKeepsBubbleOrderWrappedInGenericBlocks() throws {
        let window = body([
            AXNode(role: "AXTextArea", value: "call me", title: nil, url: nil,
                   frame: CGRect(x: 300, y: 300, width: 400, height: 20), focused: false, children: []),
            AXNode(role: "AXTextArea", value: "hey are you free", title: nil, url: nil,
                   frame: CGRect(x: 300, y: 100, width: 400, height: 20), focused: false, children: []),
        ], title: "Harnish")
        let app = AppInfo(bundleID: ParserRegistry.messagesBundleID, name: "Messages",
                          windowTitle: "Harnish")
        let capture = try XCTUnwrap(try MessagesParser().parse(window: window, app: app))
        XCTAssertEqual(capture.sourceKey, "imessage:harnish")
        XCTAssertEqual(capture.contentKind, .conversation)
        XCTAssertEqual(capture.content, "hey are you free\ncall me")
        XCTAssertEqual(try XCTUnwrap(capture.structured).kind, .generic)
        // Same Task 9 bridge precondition as Discord.
        XCTAssertTrue(try XCTUnwrap(capture.structured).isLegacyShaped)
        XCTAssertEqual(capture.accumulationPolicy, .appendItems)
    }

    /// A note is a document, and the 8_000 default would trim one at a length Pages and Word
    /// keep whole. The three note apps therefore declare the same page budget and scroll ceiling.
    func testNoteAppsUseTheDocumentPageBudget() throws {
        let long = body((0..<400).map { index in
            text("paragraph \(index) " + String(repeating: "x", count: 40), y: CGFloat(20 * index))
        }, title: "Long note")
        let cases: [(parser: any SourceParser, app: AppInfo, label: String)] = [
            (NotesParser(), AppInfo(bundleID: "com.apple.Notes", name: "Notes", windowTitle: "Long note"), "Notes"),
            (NotionParser(), AppInfo(bundleID: "notion.id", name: "Notion", windowTitle: "Long note"), "Notion"),
            (ObsidianParser(), AppInfo(bundleID: "md.obsidian", name: "Obsidian", windowTitle: "Long note - My Vault - Obsidian v1.5"), "Obsidian"),
        ]
        for entry in cases {
            let capture = try XCTUnwrap(try entry.parser.parse(window: long, app: entry.app), entry.label)
            XCTAssertEqual(capture.offscreenPolicy.maxCharacters,
                           StructuredEntityExtraction.pageBudget, entry.label)
            XCTAssertGreaterThan(capture.content.count, 8_000,
                                 "\(entry.label) must not be trimmed at the 8_000 default")
            XCTAssertLessThanOrEqual(capture.content.count,
                                     StructuredEntityExtraction.pageBudget, entry.label)
        }
    }

    func testEmptyWindowsStillReturnNilEverywhere() throws {
        let empty = body([], title: "x")
        let apps: [(any SourceParser, AppInfo)] = [
            (NotesParser(), AppInfo(bundleID: "com.apple.Notes", name: "Notes", windowTitle: "x")),
            (PagesParser(), AppInfo(bundleID: "com.apple.iWork.Pages", name: "Pages", windowTitle: "x")),
            (OutlookParser(), AppInfo(bundleID: "com.microsoft.Outlook", name: "Outlook", windowTitle: "x")),
            (DiscordParser(), AppInfo(bundleID: ParserRegistry.discordBundleID, name: "Discord", windowTitle: "x")),
            (MessagesParser(), AppInfo(bundleID: ParserRegistry.messagesBundleID, name: "Messages", windowTitle: "x")),
        ]
        for (parser, app) in apps {
            XCTAssertNil(try parser.parseStructured(window: empty, app: app), app.name)
            XCTAssertNil(try parser.parse(window: empty, app: app), app.name)
        }
    }

    func testGenericV2LinesHelperMakesOneParagraphPerLine() throws {
        guard case .generic(let page) = try XCTUnwrap(GenericV2Content.lines(["a", "b"])) else {
            return XCTFail("expected .generic")
        }
        XCTAssertEqual(page.regions.count, 1)
        XCTAssertEqual(page.regions[0].kind, .main)
        XCTAssertEqual(page.regions[0].blocks.map(\.text), ["a", "b"])
        XCTAssertNil(GenericV2Content.lines([]))
    }
}
