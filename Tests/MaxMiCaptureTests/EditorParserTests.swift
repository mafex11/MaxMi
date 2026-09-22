import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class EditorParserTests: XCTestCase {
    func node(_ role: String, value: String? = nil, title: String? = nil,
              identifier: String? = nil, frame: CGRect? = nil,
              children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: title, url: nil,
               frame: frame ?? CGRect(x: 0, y: 0, width: 100, height: 100), focused: false,
               children: children, identifier: identifier, label: nil)
    }

    /// An editor group with the file, plus a panel group with the integrated terminal.
    func window(editor: String, panel: String?, origin: CGPoint = .zero) -> AXNode {
        var children = [
            node("AXGroup", identifier: "workbench.editor.main",
                 frame: CGRect(x: origin.x + 240, y: origin.y + 80, width: 1000, height: 600),
                 children: [
                     node("AXTextArea", value: editor,
                          frame: CGRect(x: origin.x + 240, y: origin.y + 80,
                                        width: 1000, height: 600)),
                 ]),
        ]
        if let panel {
            children.append(node("AXGroup", identifier: "workbench.panel.terminal",
                                 frame: CGRect(x: origin.x + 240, y: origin.y + 700,
                                               width: 1000, height: 200),
                                 children: [
                                     node("AXTextArea", value: panel,
                                          frame: CGRect(x: origin.x + 240, y: origin.y + 700,
                                                        width: 1000, height: 200)),
                                 ]))
        }
        return node("AXWindow", title: "app.swift — sample",
                    frame: CGRect(origin: origin, size: CGSize(width: 1440, height: 900)),
                    children: children)
    }

    func context(_ bundleID: String, _ title: String?) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: bundleID, name: "Editor", windowTitle: title))
    }

    func document(_ content: CapturedContent?) throws -> Document {
        guard case .document(let doc) = try XCTUnwrap(content) else {
            throw XCTSkip("expected .document, got \(String(describing: content))")
        }
        return doc
    }

    func testConfigAndRegistration() {
        XCTAssertEqual(Set(EditorParser.config.bundleIDs), Set(ParserRegistry.editorBundleIDs))
        XCTAssertEqual(EditorParser.config.app, "Editor")
        XCTAssertEqual(EditorParser.config.offscreenPolicy,
                       .accessibilityScroll(maxSteps: 6, maxCharacters: 32_000),
                       "the scroll ceiling equals the render cap — no unreachable ceiling (F11)")
        let registry = ParserRegistry()
        XCTAssertTrue(registry.structuredParser(for: ParserRegistry.cursorBundleID) is EditorParser)
        XCTAssertTrue(registry.structuredParser(for: ParserRegistry.vsCodeBundleID) is EditorParser)
        XCTAssertTrue(registry.parser(for: ParserRegistry.vsCodeBundleID) is EditorParser,
                      "the v1 map owns the thread key, so it must be registered too")
    }

    func testActiveTabTitleHandlesBothEditorTitleOrders() {
        // VS Code: "<file> — <workspace>". Cursor: "<workspace> — <file>".
        XCTAssertEqual(EditorParser.activeTabTitle(fromWindowTitle: "app.swift — sample"),
                       "app.swift")
        XCTAssertEqual(EditorParser.activeTabTitle(fromWindowTitle: "sample — app.swift"),
                       "app.swift")
        XCTAssertEqual(EditorParser.activeTabTitle(fromWindowTitle: "● app.swift — sample"),
                       "app.swift", "the unsaved marker is not part of the file name")
        XCTAssertEqual(EditorParser.activeTabTitle(fromWindowTitle: "Welcome"), "Welcome",
                       "with no file-looking component the first component is used")
        XCTAssertEqual(EditorParser.activeTabTitle(fromWindowTitle: nil), "untitled")
    }

    func testWorkspaceNameIsTheComponentThatIsNotTheFile() {
        XCTAssertEqual(EditorParser.workspaceName(fromWindowTitle: "app.swift — sample"), "sample")
        XCTAssertEqual(EditorParser.workspaceName(fromWindowTitle: "sample — app.swift"), "sample")
        XCTAssertNil(EditorParser.workspaceName(fromWindowTitle: "Welcome"))
    }

    func testKeyIsWorkspaceScopedWhenAWorkspaceIsKnown() {
        XCTAssertEqual(EditorParser.key(fromTitle: "app.swift — Sample Project"),
                       "editor:sample-project/app.swift")
        XCTAssertEqual(EditorParser.key(fromTitle: "Welcome"), "editor:welcome")
        XCTAssertEqual(EditorParser.key(fromTitle: nil), "editor:unknown")
    }

    func testEditorLinesBecomeParagraphBlocksAndTheTitleIsTheActiveTab() throws {
        let content = try EditorParser().parse(window(editor: "let a = 1\nlet b = 2", panel: nil),
                                               context: context(ParserRegistry.vsCodeBundleID,
                                                                "app.swift — sample"))
        let doc = try document(content)
        XCTAssertEqual(doc.title, "app.swift")
        XCTAssertEqual(doc.blocks.map(\.type), [.paragraph, .paragraph])
        XCTAssertEqual(doc.blocks.map(\.text), ["let a = 1", "let b = 2"])
        XCTAssertEqual(doc.author, .user)
        XCTAssertNil(doc.url)
    }

    func testIntegratedTerminalPanelIsDroppedWhenTheEditorAnchorResolves() throws {
        let content = try EditorParser().parse(
            window(editor: "let a = 1", panel: "ada@mac ~/code % swift test"),
            context: context(ParserRegistry.cursorBundleID, "sample — app.swift"))
        let doc = try document(content)
        XCTAssertEqual(doc.blocks.map(\.text), ["let a = 1"])
        XCTAssertFalse(ContentRenderer.render(try XCTUnwrap(content), style: .full)
                        .contains("swift test"),
                       "the panel is not the document the user is editing")
    }

    func testNoEditorAnchorIsNotHandledSoGenericPageExtractorTakesOver() throws {
        let welcome = node("AXWindow", title: "Welcome",
                           frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                           children: [node("AXGroup", identifier: "workbench.panel.terminal",
                                           children: [node("AXTextArea", value: "shell only")])])
        XCTAssertNil(try EditorParser().parse(welcome,
                                              context: context(ParserRegistry.cursorBundleID,
                                                               "Welcome")),
                     "nil routes to GenericPageExtractor, which will pick the panel up")
    }

    func testEmptyEditorIsNotHandled() throws {
        XCTAssertNil(try EditorParser().parse(window(editor: "   ", panel: nil),
                                              context: context(ParserRegistry.vsCodeBundleID,
                                                               "a.swift")))
    }

    func testResultIsIdenticalAtANonzeroWindowOrigin() throws {
        let flush = try EditorParser().parse(window(editor: "let a = 1", panel: nil),
                                             context: context(ParserRegistry.vsCodeBundleID,
                                                              "app.swift — sample"))
        let offset = try EditorParser().parse(
            window(editor: "let a = 1", panel: nil, origin: CGPoint(x: 1440, y: 220)),
            context: context(ParserRegistry.vsCodeBundleID, "app.swift — sample"))
        XCTAssertEqual(flush, offset)
    }

    func testSourceAppComesFromTheApplicationRegistryDisplayName() throws {
        let app = AppInfo(bundleID: ParserRegistry.cursorBundleID, name: "Cursor",
                          windowTitle: "sample — app.swift")
        let parsed = try XCTUnwrap(try EditorParser().parse(
            window: window(editor: "let a = 1", panel: nil), app: app))
        XCTAssertEqual(parsed.sourceApp, "Cursor")
        XCTAssertEqual(parsed.sourceKey, "editor:sample/app.swift")
        XCTAssertEqual(parsed.contentKind, .document)
        XCTAssertEqual(parsed.accumulationPolicy, .replace)
    }

    func testVSCodeFixtureMatchesItsGolden() throws {
        let content = try EditorParser().parse(try fixture("vscode-editor"),
                                               context: context(ParserRegistry.vsCodeBundleID,
                                                                "sample.swift — sample"))
        assertGolden(try XCTUnwrap(content), matches: "vscode-editor-golden")
    }

    func testOffsetCursorFixtureMatchesItsGolden() throws {
        let content = try EditorParser().parse(try fixture("cursor-offset-editor"),
                                               context: context(ParserRegistry.cursorBundleID,
                                                                "sample — sample.swift"))
        assertGolden(try XCTUnwrap(content), matches: "cursor-offset-editor-golden")
    }
}
