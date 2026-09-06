import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class TerminalSegmentationTests: XCTestCase {
    func window(_ blob: String, title: String? = "~/code/MaxMi") -> AXNode {
        AXNode(role: "AXWindow", value: nil, title: title, url: nil,
               frame: CGRect(x: 0, y: 0, width: 1_200, height: 800), focused: false,
               children: [AXNode(role: "AXTextArea", value: blob, title: nil, url: nil,
                                 frame: CGRect(x: 0, y: 0, width: 1_200, height: 800),
                                 focused: false, children: [])])
    }

    func app(_ title: String? = "~/code/MaxMi") -> AppInfo {
        AppInfo(bundleID: "dev.warp.Warp-Stable", name: "Warp", windowTitle: title)
    }

    func session(_ content: CapturedContent?) throws -> TerminalSession {
        guard case .terminal(let session) = try XCTUnwrap(content) else {
            XCTFail("expected .terminal")
            return TerminalSession(cwd: nil, segments: [])
        }
        return session
    }

    func testUserAtHostPromptSplitsCommandsAndOutput() throws {
        let blob = """
        dev@mac ~/code/MaxMi % swift build
        Compiling MaxMi
        Build complete
        dev@mac ~/code/MaxMi % swift test
        2 failures
        """
        let session = try session(try TerminalParser().parseStructured(window: window(blob), app: app()))
        XCTAssertEqual(session.segments.map(\.command), ["swift build", "swift test"])
        XCTAssertEqual(session.segments.map(\.output), ["Compiling MaxMi\nBuild complete", "2 failures"])
        XCTAssertEqual(session.segments.map(\.isRunning), [false, true],
                       "no trailing prompt means the last command is still running")
        XCTAssertEqual(session.cwd, "maxmi")
    }

    func testTrailingBarePromptMarksTheLastCommandFinished() throws {
        // Spelled as an array so the bare prompt's trailing space (what a shell actually leaves
        // after the marker) survives editors that strip trailing whitespace.
        let blob = [
            "dev@mac ~/code/MaxMi % swift test",
            "2 failures",
            "dev@mac ~/code/MaxMi % ",
        ].joined(separator: "\n")
        let session = try session(try TerminalParser().parseStructured(window: window(blob), app: app()))
        XCTAssertEqual(session.segments.map(\.command), ["swift test"])
        XCTAssertEqual(session.segments.map(\.isRunning), [false])
    }

    /// Amended per ruling F3: a TRAILING prompt that carries a command emits its own segment with
    /// `isRunning: true` (the command was entered, its output has not arrived yet). Only a BARE
    /// trailing prompt emits nothing.
    func testPathPromptPatternIsUsedWhenThereIsNoUserAtHost() throws {
        let blob = """
        ~/code/ShipCast ❯ git push
        Everything up-to-date
        ~/code/ShipCast ❯ git status
        """
        let session = try session(try TerminalParser().parseStructured(
            window: window(blob, title: "~/code/ShipCast"), app: app("~/code/ShipCast")))
        XCTAssertEqual(session.segments.map(\.command), ["git push", "git status"])
        XCTAssertEqual(session.segments.map(\.output), ["Everything up-to-date", ""])
        XCTAssertEqual(session.segments.map(\.isRunning), [false, true])
        XCTAssertEqual(session.cwd, "shipcast")
    }

    /// Ruling F2: the prompt match runs through the marker, so the command never carries the
    /// prompt's cwd or the `%` itself.
    func testCommandExcludesThePromptPrefix() throws {
        let blob = "dev@mac ~/code/MaxMi % git commit -m \"ship it\"\ndone"
        let session = try session(try TerminalParser().parseStructured(window: window(blob), app: app()))
        XCTAssertEqual(session.segments.map(\.command), ["git commit -m \"ship it\""])
        XCTAssertEqual(session.segments.map(\.output), ["done"])
    }

    func testOutputBeforeTheFirstPromptBecomesACommandlessSegment() throws {
        let blob = """
        welcome banner
        dev@mac ~/code/MaxMi % ls
        a b c
        """
        let session = try session(try TerminalParser().parseStructured(window: window(blob), app: app()))
        XCTAssertEqual(session.segments.map(\.command), [nil, "ls"])
        XCTAssertEqual(session.segments[0].output, "welcome banner")
        XCTAssertFalse(session.segments[0].isRunning, "history above the first prompt is finished")
    }

    func testUnrecognisedPromptFallsBackToOneCommandlessSegment() throws {
        let blob = "TUI frame\nspinner ⠋\nno prompt anywhere"
        let session = try session(try TerminalParser().parseStructured(window: window(blob), app: app()))
        XCTAssertEqual(session.segments.count, 1)
        XCTAssertNil(session.segments[0].command)
        XCTAssertEqual(session.segments[0].output, blob)
        XCTAssertFalse(session.segments[0].isRunning)
    }

    func testCaptureRendersTheSegmentsAndKeepsKeyKindAndPolicy() throws {
        let blob = """
        dev@mac ~/code/MaxMi % swift test
        2 failures
        """
        let capture = try XCTUnwrap(try TerminalParser().parse(window: window(blob), app: app()))
        XCTAssertEqual(capture.sourceApp, "Warp")
        XCTAssertEqual(capture.sourceKey, "terminal:warp/maxmi",
                       "the key is still derived from the RAW scrollback")
        XCTAssertEqual(capture.contentKind, .terminal)
        XCTAssertEqual(capture.accumulationPolicy, .appendItems)
        XCTAssertEqual(capture.content, "$ swift test\n2 failures\n… (running)")
        XCTAssertEqual(capture.content, ContentRenderer.render(
            try XCTUnwrap(capture.structured), style: .full))
    }

    func testEmptyScrollbackStillReturnsNil() throws {
        let empty = AXNode(role: "AXWindow", value: nil, title: nil, url: nil,
                           frame: CGRect(x: 0, y: 0, width: 100, height: 100), focused: false,
                           children: [])
        XCTAssertNil(try TerminalParser().parseStructured(window: empty, app: app(nil)))
        XCTAssertNil(try TerminalParser().parse(window: empty, app: app(nil)))
    }

    func testOversizeScrollbackDropsOldestSegments() throws {
        var lines: [String] = []
        for index in 0..<400 {
            lines.append("dev@mac ~/code/MaxMi % echo \(index)")
            lines.append(String(repeating: "y", count: 40))
        }
        let session = try session(try TerminalParser().parseStructured(
            window: window(lines.joined(separator: "\n")), app: app()))
        XCTAssertEqual(session.segments.last?.command, "echo 399")
        XCTAssertLessThan(session.segments.count, 400, "oldest segments are dropped")
        let capture = try XCTUnwrap(try TerminalParser().parse(
            window: window(lines.joined(separator: "\n")), app: app()))
        XCTAssertLessThanOrEqual(capture.content.count, TerminalParser.contentCap)
    }

    func testSelfBoundingCaptureReportsTruncation() throws {
        let small = try XCTUnwrap(try TerminalParser().parse(
            window: window("dev@mac ~/code/MaxMi % echo ready\nready"), app: app()))
        XCTAssertFalse(small.truncated)

        let oversize = try XCTUnwrap(try TerminalParser().parse(
            window: window((0..<400).flatMap {
                ["dev@mac ~/code/MaxMi % echo \($0)", String(repeating: "y", count: 40)]
            }.joined(separator: "\n")),
            app: app()
        ))
        XCTAssertTrue(oversize.truncated)
    }
}
