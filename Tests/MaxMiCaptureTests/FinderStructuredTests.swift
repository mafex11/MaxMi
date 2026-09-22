import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class FinderStructuredTests: XCTestCase {
    func node(_ role: String, value: String? = nil, title: String? = nil, url: String? = nil,
              identifier: String? = nil, selected: Bool = false,
              subrole: String? = nil, selectedText: String? = nil, focused: Bool = false,
              frame: CGRect, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: title, url: url, frame: frame, focused: focused,
               children: children, identifier: identifier, label: nil, subrole: subrole,
               headingLevel: nil, selected: selected, selectedText: selectedText)
    }

    func cell(_ text: String, x: CGFloat, y: CGFloat) -> AXNode {
        node("AXCell", frame: CGRect(x: x, y: y, width: 160, height: 20), children: [
            node("AXStaticText", value: text, frame: CGRect(x: x, y: y, width: 160, height: 16)),
        ])
    }

    /// Window 1200 wide: a source-list sidebar on the left, a file table in the middle, and a
    /// toolbar carrying a copy-progress status line.
    func window(status: String?, origin: CGPoint = .zero) -> AXNode {
        let x = origin.x
        let y = origin.y
        var toolbarKids = [node("AXButton", title: "Back",
                                frame: CGRect(x: x + 20, y: y + 8, width: 40, height: 24))]
        if let status {
            toolbarKids.append(node("AXStaticText", value: status,
                                    frame: CGRect(x: x + 400, y: y + 8, width: 260, height: 20)))
        }
        return node("AXWindow", title: "sample", url: "file:///Users/ada/code/sample",
                    frame: CGRect(origin: origin, size: CGSize(width: 1200, height: 800)),
                    children: [
            node("AXToolbar", frame: CGRect(x: x, y: y, width: 1200, height: 40),
                 children: toolbarKids),
            node("AXSplitGroup", frame: CGRect(x: x, y: y + 40, width: 1200, height: 760),
                 children: [
                node("AXGroup", identifier: "Finder.sidebar",
                     frame: CGRect(x: x, y: y + 40, width: 240, height: 760), children: [
                    node("AXOutline", frame: CGRect(x: x, y: y + 40, width: 240, height: 760),
                         children: [
                        node("AXRow", frame: CGRect(x: x + 10, y: y + 80, width: 220, height: 20),
                             children: [node("AXStaticText", value: "Downloads",
                                             frame: CGRect(x: x + 10, y: y + 80,
                                                           width: 200, height: 16))]),
                    ]),
                ]),
                node("AXTable", frame: CGRect(x: x + 240, y: y + 40, width: 960, height: 760),
                     children: [
                    node("AXRow", frame: CGRect(x: x + 240, y: y + 100, width: 960, height: 20),
                         children: [cell("Package.swift", x: x + 240, y: y + 100),
                                    cell("3 KB", x: x + 600, y: y + 100)]),
                    node("AXRow", selected: true,
                         frame: CGRect(x: x + 240, y: y + 130, width: 960, height: 20),
                         children: [cell("README.md", x: x + 240, y: y + 130),
                                    cell("12 KB", x: x + 600, y: y + 130)]),
                ]),
            ]),
        ])
    }

    func context(_ title: String?) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: ParserRegistry.finderBundleID, name: "Finder",
                                  windowTitle: title))
    }

    func page(_ content: CapturedContent?) throws -> GenericPage {
        guard case .generic(let page) = try XCTUnwrap(content) else {
            XCTFail("expected .generic, got \(String(describing: content))")
            throw NSError(domain: "ExpectedContentShape", code: 1)
        }
        return page
    }

    func blocks(_ page: GenericPage, _ kind: RegionKind) -> [Block] {
        page.regions.first { $0.kind == kind }?.blocks ?? []
    }

    func testConfigAndRegistration() {
        XCTAssertEqual(FinderParser.config.bundleIDs, [ParserRegistry.finderBundleID])
        XCTAssertEqual(FinderParser.config.app, "Finder")
        let registry = ParserRegistry()
        XCTAssertTrue(registry.structuredParser(for: ParserRegistry.finderBundleID) is FinderParser)
        XCTAssertTrue(registry.parser(for: ParserRegistry.finderBundleID) is FinderParser)
    }

    func testFolderPathComesFromAXDocumentThenTheWindowTitle() {
        XCTAssertEqual(FinderParser.folderPath(in: window(status: nil), windowTitle: "sample"),
                       "/Users/ada/code/sample")
        let noDocument = node("AXWindow", title: "Downloads",
                              frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(FinderParser.folderPath(in: noDocument, windowTitle: "Downloads"),
                       "Downloads")
        XCTAssertNil(FinderParser.folderPath(
            in: node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1, height: 1)),
            windowTitle: nil))
    }

    func testKeyIsPathScoped() {
        XCTAssertEqual(FinderParser.key(fromPath: "/Users/ada/code/sample", windowTitle: "sample"),
                       "finder:/users/ada/code/sample")
        XCTAssertEqual(FinderParser.key(fromPath: nil, windowTitle: "Downloads"),
                       "finder:downloads")
        XCTAssertEqual(FinderParser.key(fromPath: nil, windowTitle: nil), "finder:unknown")
    }

    func testFileRowsLandInMainAsJoinedTableRowsWithSelection() throws {
        let page = try page(FinderParser().parse(window(status: nil), context: context("sample")))
        XCTAssertEqual(blocks(page, .main).map(\.type), [
            .tableRow(cells: ["Package.swift", "3 KB"], selected: false),
            .tableRow(cells: ["README.md", "12 KB"], selected: true),
        ])
        XCTAssertEqual(ContentRenderer.renderBlock(blocks(page, .main)[1]), "* README.md | 12 KB")
    }

    func testSidebarFoldersLandInTheSidebarRegion() throws {
        let page = try page(FinderParser().parse(window(status: nil), context: context("sample")))
        XCTAssertEqual(blocks(page, .sidebar).map(\.text), ["Downloads"])
        XCTAssertFalse(blocks(page, .main).contains { $0.text.contains("Downloads") },
                       "the source list is not part of the folder listing")
    }

    func testTheCopyProgressStatusLandsInTheToolbarRegion() throws {
        let page = try page(FinderParser().parse(window(status: "Uploading 34 items"),
                                                context: context("sample")))
        XCTAssertEqual(blocks(page, .toolbar).map(\.text), ["Back", "Uploading 34 items"])
    }

    func testTheFolderPathIsCarriedAsTheUrl() throws {
        let page = try page(FinderParser().parse(window(status: nil), context: context("sample")))
        XCTAssertEqual(page.url, "/Users/ada/code/sample")
    }

    func testTheSourceListIsClassifiedAsSidebarEvenAtANonzeroWindowOrigin() throws {
        // Replaces a bare flush-vs-offset region comparison, which `GenericPageRegionTests`
        // already covers for `finder-offset-window.json` and which no Finder-parser change could
        // ever break (ruling F25). This asserts the thing that CAN break: that the rows the
        // structural anchor identifies as source-list rows are the rows the geometric §4e rules
        // put in `.sidebar`, and that none of them leak into the listing — at an origin where a
        // missing window-relative conversion would misclassify them.
        let offsetWindow = window(status: "Uploading 34 items", origin: CGPoint(x: 1_440, y: 220))
        let anchored = Set(FinderParser.sidebarRows(in: offsetWindow)
            .flatMap { AXQuery.collectStaticTexts(in: $0) })
        XCTAssertEqual(anchored, ["Downloads"], "the fixture's source list holds exactly one row")
        let page = try page(FinderParser().parse(offsetWindow, context: context("sample")))
        XCTAssertEqual(Set(blocks(page, .sidebar).map(\.text)), anchored)
        for text in anchored {
            XCTAssertFalse(blocks(page, .main).contains { $0.text.contains(text) },
                           "\(text) is source-list chrome, not a folder listing row")
        }
    }

    func testAnEmptyWindowIsRefused() throws {
        let bare = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        XCTAssertThrowsError(try FinderParser().parse(bare, context: context("sample"))) {
            XCTAssertEqual($0 as? ParserRefusal, ParserRefusal(reason: "unmatched-finder-window"))
        }
    }

    func testToolbarOnlyWindowsAreRefusedButUnrecognizedContentFallsThrough() throws {
        let toolbarOnly = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                               children: [
                                node("AXToolbar", frame: CGRect(x: 0, y: 0, width: 1200, height: 40),
                                     children: [
                                        node("AXButton", title: "Back",
                                             frame: CGRect(x: 20, y: 8, width: 40, height: 24)),
                                    ]),
                               ])
        let unrelated = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                             children: [
                                node("AXStaticText", value: "Name: Project plan",
                                     frame: CGRect(x: 100, y: 100, width: 300, height: 20)),
                             ])
        XCTAssertThrowsError(try FinderParser().parse(toolbarOnly, context: context("sample"))) {
            XCTAssertEqual($0 as? ParserRefusal, ParserRefusal(reason: "unmatched-finder-window"))
        }
        XCTAssertNil(try FinderParser().parse(unrelated, context: context("Get Info")))

        let app = AppInfo(bundleID: ParserRegistry.finderBundleID, name: "Finder",
                          windowTitle: "Get Info")
        guard case .parsedByFallback(let fallback, let parser) = CaptureDispatch.parseDetailed(
            window: unrelated, app: app, registry: ParserRegistry()
        ) else {
            return XCTFail("an unrecognized Finder window must use generic fallback")
        }
        XCTAssertEqual(parser, "FinderParser")
        XCTAssertEqual(fallback.sourceKey, "com.apple.finder:Get Info")
        XCTAssertTrue(fallback.content.contains("Name: Project plan"))
    }

    func testSourceParserSuppliesTheKeyAndTheGenericKind() throws {
        let app = AppInfo(bundleID: ParserRegistry.finderBundleID, name: "Finder",
                          windowTitle: "sample")
        let parsed = try XCTUnwrap(try FinderParser().parse(window: window(status: nil), app: app))
        XCTAssertEqual(parsed.sourceApp, "Finder")
        XCTAssertEqual(parsed.sourceKey, "finder:/users/ada/code/sample")
        XCTAssertEqual(parsed.contentKind, .generic)
        XCTAssertEqual(parsed.accumulationPolicy, .replace)
    }

    func testFinderListFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(FinderParser().parse(try fixture("finder-list"),
                                                       context: context("sample"))),
                     matches: "finder-list-golden")
    }

    func testOffsetFinderCopyFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(FinderParser().parse(try fixture("finder-offset-copy"),
                                                       context: context("sample"))),
                     matches: "finder-offset-copy-golden")
    }

    func testFinderOutputNeverLeaksSelectedTextFromAFocusedSecureField() throws {
        let secret = "reviewer-secret-selected-text"
        let secureField = node(
            "AXTextField", value: secret, subrole: "AXSecureTextField", selectedText: secret,
            focused: true, frame: CGRect(x: 260, y: 100, width: 300, height: 20)
        )
        let finder = node("AXWindow", title: "Passwords",
                          frame: CGRect(x: 0, y: 0, width: 1200, height: 800), children: [
            node("AXTable", frame: CGRect(x: 240, y: 40, width: 960, height: 760), children: [
                node("AXRow", frame: CGRect(x: 240, y: 100, width: 960, height: 20),
                     children: [secureField]),
            ]),
        ])
        let content = try XCTUnwrap(FinderParser().parse(finder, context: context("Passwords")))
        guard case .generic(let page) = content else { return XCTFail("expected generic page") }
        XCTAssertFalse(ContentRenderer.render(content, style: .full).contains(secret))
        XCTAssertNil(page.focused?.value)
        XCTAssertNil(page.focused?.selectedText)
        XCTAssertTrue(page.focused?.isSecure == true)
    }
}
