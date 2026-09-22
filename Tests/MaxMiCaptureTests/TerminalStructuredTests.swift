import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class TerminalStructuredTests: XCTestCase {
    func window(_ scrollback: String, origin: CGPoint = .zero,
                title: String? = "~/code/MaxMi") -> AXNode {
        AXNode(role: "AXWindow", value: nil, title: title, url: nil,
               frame: CGRect(origin: origin, size: CGSize(width: 900, height: 600)),
               focused: false,
               children: [AXNode(role: "AXTextArea", value: scrollback, title: nil, url: nil,
                                 frame: CGRect(x: origin.x, y: origin.y,
                                               width: 900, height: 600),
                                 focused: true, children: [])])
    }

    func context(_ title: String?) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: "dev.warp.Warp-Stable", name: "Warp",
                                  windowTitle: title))
    }

    func session(_ content: CapturedContent?) throws -> TerminalSession {
        guard case .terminal(let session) = try XCTUnwrap(content) else {
            XCTFail("expected a .terminal shape, got \(String(describing: content))")
            throw NSError(domain: "ExpectedContentShape", code: 1)
        }
        return session
    }

    // MARK: - Config

    func testConfigClaimsEveryTerminalBundleID() {
        // Four today: dev.warp.Warp-Stable, dev.warp.Warp, com.apple.Terminal, com.googlecode.iterm2.
        XCTAssertEqual(Set(TerminalParser.config.bundleIDs),
                       Set(ParserRegistry.terminalBundleIDs))
        XCTAssertEqual(TerminalParser.config.bundleIDs.count, 4)
        XCTAssertEqual(TerminalParser.config.app, "Terminal")
        XCTAssertEqual(TerminalParser.config.offscreenPolicy,
                       .visibleOnly(maxCharacters: 64_000))
        XCTAssertTrue(TerminalParser.config.attributeSet.isEmpty,
                      "a terminal is one AXTextArea; it needs no extra attributes")
    }

    func testRegistryRoutesEveryTerminalBundleIDToTerminalParser() {
        let registry = ParserRegistry()
        for bundleID in ParserRegistry.terminalBundleIDs {
            XCTAssertTrue(registry.structuredParser(for: bundleID) is TerminalParser, bundleID)
        }
    }

    // MARK: - Prompt shape

    func testPromptShapeIsLearnedFromTheFirstMatchingLine() {
        XCTAssertEqual(TerminalParser.promptShape(in: ["noise", "ada@mac ~/code %"]), .userHost)
        XCTAssertEqual(TerminalParser.promptShape(in: ["noise", "~/code % ls"]), .path)
        XCTAssertNil(TerminalParser.promptShape(in: ["just", "output"]))
    }

    func testCommandTextStripsThePromptAndTheCwd() {
        XCTAssertEqual(
            TerminalParser.commandText(in: "ada@mac ~/code/MaxMi % swift test", shape: .userHost),
            "swift test")
        XCTAssertEqual(TerminalParser.commandText(in: "~/code/MaxMi % swift test", shape: .path),
                       "swift test")
        XCTAssertEqual(TerminalParser.commandText(in: "ada@mac ~/code/MaxMi %", shape: .userHost),
                       "", "an idle prompt line yields an empty command, not nil")
        XCTAssertNil(TerminalParser.commandText(in: "  2 failures", shape: .userHost))
    }

    func testCommandTextKeepsAPromptCharacterInsideThePathShapeCommand() {
        XCTAssertEqual(TerminalParser.commandText(in: "~/code % echo \"$ five\"", shape: .path),
                       "echo \"$ five\"",
                       "the path shape already consumed the real terminator")
    }

    // MARK: - Segmentation

    func testSegmentsSplitOnEveryPromptOfTheLearnedShape() throws {
        let scrollback = """
        ada@mac ~/code/MaxMi % swift build
        Compiling MaxMi
        Build complete
        ada@mac ~/code/MaxMi % swift test
        Executed 689 tests, with 3 failures
        ada@mac ~/code/MaxMi %
        """
        let segments = TerminalParser.segments(fromScrollback: scrollback)
        XCTAssertEqual(segments.map(\.command), ["swift build", "swift test"])
        XCTAssertEqual(segments[0].output, "Compiling MaxMi\nBuild complete")
        XCTAssertEqual(segments[1].output, "Executed 689 tests, with 3 failures")
        XCTAssertFalse(segments[1].isRunning, "a trailing idle prompt means nothing is running")
    }

    func testLastSegmentIsRunningWhenNoTrailingPromptFollows() {
        let scrollback = """
        ada@mac ~/code/MaxMi % swift test
        Test Suite 'All tests' started
        """
        let segments = TerminalParser.segments(fromScrollback: scrollback)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].command, "swift test")
        XCTAssertTrue(segments[0].isRunning)
    }

    func testOutputBeforeTheFirstPromptBecomesALeadingCommandlessSegment() {
        let scrollback = """
        Welcome to Warp
        ada@mac ~/code % ls
        Package.swift
        ada@mac ~/code %
        """
        let segments = TerminalParser.segments(fromScrollback: scrollback)
        XCTAssertEqual(segments.map(\.command), [nil, "ls"])
        XCTAssertEqual(segments[0].output, "Welcome to Warp")
    }

    func testSegmentationFailureYieldsOneCommandlessSegmentCarryingTheWholeBuffer() {
        let blob = "a full-screen TUI with no prompt at all\nsecond line"
        let segments = TerminalParser.segments(fromScrollback: blob)
        XCTAssertEqual(segments.count, 1)
        XCTAssertNil(segments[0].command)
        XCTAssertEqual(segments[0].output, blob)
        XCTAssertFalse(segments[0].isRunning)
    }

    // MARK: - cwd

    func testCwdComesFromTheWindowTitleOnly() {
        XCTAssertEqual(
            TerminalParser.cwdPath(windowTitle: "~/code/MaxMi — -zsh",
                                   scrollback: "ada@mac ~/other %"),
            "~/code/MaxMi")
        XCTAssertNil(
            TerminalParser.cwdPath(windowTitle: "Claude Code",
                                   scrollback: "ada@mac ~/code/MaxMi % swift test"),
            "prompt text is untrusted captured content, not a cwd source")
        XCTAssertNil(TerminalParser.cwdPath(windowTitle: nil, scrollback: "no paths here"))
    }

    func testCwdIgnoresPathsThatAreNotPromptCwds() {
        XCTAssertNil(
            TerminalParser.cwdPath(windowTitle: nil,
                                   scrollback: "opened ~/code/MaxMi/Package.swift for editing"),
            "a path in output is not the shell's current directory")
    }

    // MARK: - End to end

    func testParseProducesATerminalSessionWithCwdAndSegments() throws {
        let scrollback = """
        ada@mac ~/code/MaxMi % swift build
        Build complete
        ada@mac ~/code/MaxMi %
        """
        let content = try TerminalParser().parse(window(scrollback), context: context("~/code/MaxMi"))
        let terminal = try session(content)
        XCTAssertEqual(terminal.cwd, "~/code/MaxMi")
        XCTAssertEqual(terminal.segments.map(\.command), ["swift build"])
        XCTAssertEqual(ContentRenderer.render(try XCTUnwrap(content), style: .full),
                       "$ swift build\nBuild complete")
    }

    func testSegmentationIsIdenticalAtANonzeroWindowOrigin() throws {
        let scrollback = "ada@mac ~/code % ls\nPackage.swift\nada@mac ~/code %"
        let flush = try TerminalParser().parse(window(scrollback), context: context("~/code"))
        let offset = try TerminalParser().parse(window(scrollback, origin: CGPoint(x: 1440, y: 220)),
                                                context: context("~/code"))
        XCTAssertEqual(flush, offset, "a terminal is text; its origin must not matter")
    }

    func testEmptyTerminalIsNotHandled() throws {
        let bare = AXNode(role: "AXWindow", value: nil, title: nil, url: nil,
                          frame: CGRect(x: 0, y: 0, width: 10, height: 10), focused: false,
                          children: [])
        XCTAssertNil(try TerminalParser().parse(bare, context: context(nil)),
                     "nil is NOT_HANDLED and routes to GenericPageExtractor")
    }

    func testParseStructuredBridgeMatchesTheStructuredParser() throws {
        let scrollback = "ada@mac ~/code % ls\nPackage.swift\nada@mac ~/code %"
        let app = AppInfo(bundleID: "dev.warp.Warp-Stable", name: "Warp", windowTitle: "~/code")
        XCTAssertEqual(try TerminalParser().parseStructured(window: window(scrollback), app: app),
                       try TerminalParser().parse(window(scrollback), context: context("~/code")))
    }

    // MARK: - Invariants moved here from TerminalSegmentationTests (ruling F8)

    /// Moved verbatim in intent from `TerminalSegmentationTests`: the ONLY coverage that the
    /// rendered capture is the render of the typed value and that the key/kind/policy trio is
    /// untouched by the anchored rewrite.
    func testCaptureRendersTheSegmentsAndKeepsKeyKindAndPolicy() throws {
        let blob = "dev@mac ~/code/MaxMi % swift test\n2 failures"
        let app = AppInfo(bundleID: "dev.warp.Warp-Stable", name: "Warp",
                          windowTitle: "~/code/MaxMi")
        let capture = try XCTUnwrap(try TerminalParser().parse(window: window(blob), app: app))
        XCTAssertEqual(capture.sourceApp, "Warp")
        XCTAssertEqual(capture.sourceKey, "terminal:warp/maxmi",
                       "the key is still derived from the RAW scrollback, not from the typed value")
        XCTAssertEqual(capture.contentKind, .terminal)
        XCTAssertEqual(capture.accumulationPolicy, .appendItems)
        XCTAssertEqual(capture.content, "$ swift test\n2 failures\n… (running)")
        XCTAssertEqual(capture.content, ContentRenderer.render(
            try XCTUnwrap(capture.structured), style: .full),
                       "one content path: `parse` renders exactly what `parseStructured` returned")
    }

    /// Moved from `TerminalSegmentationTests`: the ONLY coverage of the `contentCap` trim.
    func testOversizeScrollbackDropsOldestSegments() throws {
        var lines: [String] = []
        for index in 0..<400 {
            lines.append("dev@mac ~/code/MaxMi % echo \(index)")
            lines.append(String(repeating: "y", count: 40))
        }
        let blob = lines.joined(separator: "\n")
        let app = AppInfo(bundleID: "dev.warp.Warp-Stable", name: "Warp",
                          windowTitle: "~/code/MaxMi")
        let session = try session(try TerminalParser().parseStructured(window: window(blob), app: app))
        XCTAssertEqual(session.segments.last?.command, "echo 399", "newest-anchored")
        XCTAssertLessThan(session.segments.count, 400, "oldest segments are dropped")
        let capture = try XCTUnwrap(try TerminalParser().parse(window: window(blob), app: app))
        XCTAssertLessThanOrEqual(capture.content.count, TerminalParser.contentCap)
    }

    // MARK: - Golden fixtures

    func testWarpSessionFixtureMatchesItsGolden() throws {
        let content = try TerminalParser().parse(try fixture("warp-session"),
                                                 context: context("~/code/sample"))
        assertGolden(try XCTUnwrap(content), matches: "warp-session-golden")
    }

    func testOffsetITermSessionFixtureMatchesItsGolden() throws {
        let iterm = ParseContext(app: AppInfo(bundleID: "com.googlecode.iterm2", name: "iTerm2",
                                              windowTitle: "~/code/sample"))
        let content = try TerminalParser().parse(try fixture("iterm-offset-session"), context: iterm)
        assertGolden(try XCTUnwrap(content), matches: "iterm-offset-session-golden")
    }
}
