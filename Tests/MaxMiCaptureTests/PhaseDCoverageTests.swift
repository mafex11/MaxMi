import XCTest
import MaxMiCore
@testable import MaxMiCapture

/// Spec §11 item 8 as a test: every rewritten parser is registered, and every one has at least
/// two fixtures with goldens, at least one of them recorded at a nonzero window origin.
final class PhaseDCoverageTests: XCTestCase {
    /// Parser type name -> its two (fixture, golden) pairs.
    static let coverage: [String: [(fixture: String, golden: String)]] = [
        "TerminalParser": [("warp-session", "warp-session-golden"),
                           ("iterm-offset-session", "iterm-offset-session-golden")],
        "EditorParser": [("vscode-editor", "vscode-editor-golden"),
                         ("cursor-offset-editor", "cursor-offset-editor-golden")],
        // R-E rejects the former unanchored x-band fallback. This fixture keeps the verified
        // DOM anchors while exercising the same parser at a nonzero window origin.
        "SlackParser": [("slack-dom-messages", "slack-dom-messages-golden"),
                        ("slack-offset-dom-messages", "slack-offset-dom-messages-golden")],
        // Discord is geometry-free, so its offset fixture is pinned against the SAME golden
        // (Task 11, ruling F25) — the pair is (two fixtures, one golden).
        "DiscordParser": [("discord-messages", "discord-messages-golden"),
                          ("discord-offset-messages", "discord-messages-golden")],
        "MessagesParser": [("messages-thread", "messages-thread-golden"),
                           ("messages-offset-thread", "messages-offset-thread-golden")],
        "WhatsAppParser": [("whatsapp-bubbles", "whatsapp-bubbles-golden"),
                           ("whatsapp-offset-bubbles", "whatsapp-offset-bubbles-golden")],
        "NotesParser": [("notes-body", "notes-body-golden"),
                        ("notes-offset-shared", "notes-offset-shared-golden")],
        "NotionParser": [("notion-page", "notion-page-golden"),
                         ("notion-offset-peek", "notion-offset-peek-golden")],
        "ObsidianParser": [("obsidian-editor", "obsidian-editor-golden"),
                           ("obsidian-offset-preview", "obsidian-offset-preview-golden")],
        "GmailParser": [("gmail-thread", "gmail-thread-golden"),
                        ("gmail-offset-inbox", "gmail-offset-inbox-golden")],
        "FinderParser": [("finder-list", "finder-list-golden"),
                         ("finder-offset-copy", "finder-offset-copy-golden")],
        "CalendarParser": [("calendar-event", "calendar-event-golden"),
                           ("calendar-offset-event", "calendar-offset-event-golden")],
        "RemindersParser": [("reminder-task", "reminder-task-golden"),
                            ("reminders-offset-list", "reminders-offset-list-golden")],
    ]

    /// The exact registration list Task 5 declares and Tasks 7-20 fill in, restated here so a
    /// parser cannot be quietly dropped from `ParserRegistry.init()` (ruling F28). The four
    /// host-only parsers (Tasks 22-26) are NOT in this set — they are unreachable by bundle ID by
    /// design, and `hostCoverage` plus `testEveryHostRoutedParserIsReachableFromTheHostMap`
    /// (added in Task 22) cover them.
    static let registeredStructuredParserNames: Set<String> = [
        "TerminalParser", "EditorParser", "SlackParser", "DiscordParser", "MessagesParser",
        "WhatsAppParser", "NotesParser", "NotionParser", "ObsidianParser", "FinderParser",
        "CalendarParser", "FantasticalParser", "RemindersParser",
    ]

    /// Parser type name -> the hosts it claims. Host-routed parsers (§14b) are registered by
    /// host, not by bundle ID, so `testEveryCoveredParserIsRegisteredAsAStructuredParser`
    /// cannot see them.
    static let hostCoverage: [String: [String]] = [
        "GmailParser": ["mail.google.com"],
    ]

    func testTheRegistrationListIsExactlyTheThirteenBundleIDParsers() {
        let registry = ParserRegistry()
        var names = Set<String>()
        for bundleID in [
            ParserRegistry.slackBundleID, ParserRegistry.notionBundleID,
            ParserRegistry.obsidianBundleID, ParserRegistry.notesBundleID,
            ParserRegistry.discordBundleID, ParserRegistry.messagesBundleID,
            ParserRegistry.finderBundleID, ParserRegistry.cursorBundleID,
            ParserRegistry.vsCodeBundleID,
        ] + ParserRegistry.terminalBundleIDs + ParserRegistry.whatsAppBundleIDs
          + ParserRegistry.calendarBundleIDs + ParserRegistry.fantasticalBundleIDs
          + ParserRegistry.remindersBundleIDs {
            if let parser = registry.structuredParser(for: bundleID) {
                names.insert(String(describing: type(of: parser)))
            }
        }
        XCTAssertEqual(names, Self.registeredStructuredParserNames)
        XCTAssertNil(registry.structuredParser(for: ParserRegistry.mailBundleID),
                     "Mail stays AppleScript-sourced (§12 Q6) and is deliberately unregistered")
    }

    func testEveryCoveredParserIsRegisteredAsAStructuredParser() {
        let registry = ParserRegistry()
        var registered = Set<String>()
        for bundleID in [
            ParserRegistry.slackBundleID, ParserRegistry.notionBundleID,
            ParserRegistry.obsidianBundleID, ParserRegistry.notesBundleID,
            ParserRegistry.discordBundleID, ParserRegistry.messagesBundleID,
            ParserRegistry.finderBundleID, ParserRegistry.cursorBundleID,
            ParserRegistry.vsCodeBundleID,
        ] + ParserRegistry.terminalBundleIDs + ParserRegistry.whatsAppBundleIDs
          + ParserRegistry.calendarBundleIDs + ParserRegistry.fantasticalBundleIDs
          + ParserRegistry.remindersBundleIDs {
            guard let parser = registry.structuredParser(for: bundleID) else {
                return XCTFail("no structured parser registered for \(bundleID)")
            }
            registered.insert(String(describing: type(of: parser)))
        }
        for name in Self.coverage.keys {
            XCTAssertTrue(registered.contains(name) || Self.hostCoverage[name] != nil,
                          "\(name) is reachable neither by bundle id nor by host")
        }
        XCTAssertTrue(registered.contains("FantasticalParser"),
                      "Fantastical shares Calendar's fixtures but must still be registered")
    }

    func testEveryHostRoutedParserIsReachableFromTheHostMap() {
        let registry = ParserRegistry()
        for (name, hosts) in Self.hostCoverage {
            for host in hosts {
                guard let parser = registry.structuredParser(forHost: host) else {
                    return XCTFail("no structured parser registered for host \(host)")
                }
                XCTAssertEqual(String(describing: type(of: parser)), name,
                               "host \(host) resolves to the wrong parser")
            }
        }
    }

    func testEveryCoveredParserHasTwoFixturesAndTwoGoldens() throws {
        for (parser, pairs) in Self.coverage {
            XCTAssertGreaterThanOrEqual(pairs.count, 2, "\(parser) needs at least two fixtures")
            for pair in pairs {
                XCTAssertNoThrow(try fixture(pair.fixture), "\(parser): \(pair.fixture)")
                XCTAssertNoThrow(try goldenCapturedContent(pair.golden), "\(parser): \(pair.golden)")
            }
        }
    }

    func testEveryCoveredParserHasAtLeastOneNonzeroOriginFixture() throws {
        for (parser, pairs) in Self.coverage {
            var sawNonzeroOrigin = false
            for pair in pairs {
                let frame = try fixture(pair.fixture).frame
                if let frame, frame.minX != 0 || frame.minY != 0 { sawNonzeroOrigin = true }
            }
            XCTAssertTrue(sawNonzeroOrigin,
                          "\(parser) has no fixture recorded at a nonzero window origin — "
                          + "AXFrame is global, so a flush-at-origin fixture cannot catch a "
                          + "missing window-relative conversion")
        }
    }

    func testNoFixtureCarriesASecureFieldValue() throws {
        // Spec §8: a secure field's value is never read, so it can never reach a fixture either.
        for pairs in Self.coverage.values {
            for pair in pairs {
                var offenders: [String] = []
                func visit(_ node: AXNode) {
                    if node.subrole == "AXSecureTextField", let value = node.value, !value.isEmpty {
                        offenders.append(value)
                    }
                    for child in node.children { visit(child) }
                }
                visit(try fixture(pair.fixture))
                XCTAssertTrue(offenders.isEmpty,
                              "\(pair.fixture) carries a secure field value")
            }
        }
    }

    func testTheBinaryContainsNoKeystrokeTap() throws {
        // Spec §11 item 5, asserted here because Phase D is the last phase to touch capture.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaxMiCaptureTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains("CGEventTap"), "\(url.lastPathComponent)")
            XCTAssertFalse(text.contains("addGlobalMonitorForEvents"), "\(url.lastPathComponent)")
        }
    }
}
