import XCTest
import MaxMiCore
@testable import MaxMiCapture

/// Spec §11 item 8 as a test: every registered parser is represented here. Structured parsers
/// have executable fixture/golden coverage; legacy-only routes are covered by their dedicated
/// parser tests but remain listed so a registry entry cannot silently escape this inventory.
final class PhaseDCoverageTests: XCTestCase {
    struct FixturePair {
        let fixture: String
        let golden: String
        let context: ParseContext
    }

    struct Coverage {
        let parser: (any StructuredParser)?
        let pairs: [FixturePair]
        let blankContext: ParseContext?

        static let legacy = Coverage(parser: nil, pairs: [], blankContext: nil)
    }

    static func context(
        bundleID: String,
        name: String,
        title: String?,
        url: String? = nil
    ) -> ParseContext {
        ParseContext(
            app: AppInfo(bundleID: bundleID, name: name, windowTitle: title),
            url: url,
            now: 1_790_078_400_000,
            timeZone: TimeZone(secondsFromGMT: 19_800)!
        )
    }

    static let coverage: [String: Coverage] = [
        "TerminalParser": Coverage(
            parser: TerminalParser(),
            pairs: [
                FixturePair(fixture: "warp-session", golden: "warp-session-golden",
                            context: context(bundleID: "dev.warp.Warp-Stable", name: "Warp",
                                             title: "~/code/sample")),
                FixturePair(fixture: "iterm-offset-session", golden: "iterm-offset-session-golden",
                            context: context(bundleID: "com.googlecode.iterm2", name: "iTerm2",
                                             title: "~/code/sample")),
            ],
            blankContext: context(bundleID: "dev.warp.Warp-Stable", name: "Warp", title: nil)
        ),
        "EditorParser": Coverage(
            parser: EditorParser(),
            pairs: [
                FixturePair(fixture: "vscode-editor", golden: "vscode-editor-golden",
                            context: context(bundleID: ParserRegistry.vsCodeBundleID, name: "VS Code",
                                             title: "sample.swift — sample")),
                FixturePair(fixture: "cursor-offset-editor", golden: "cursor-offset-editor-golden",
                            context: context(bundleID: ParserRegistry.cursorBundleID, name: "Cursor",
                                             title: "sample — sample.swift")),
            ],
            blankContext: context(bundleID: ParserRegistry.vsCodeBundleID, name: "VS Code",
                                  title: "Welcome")
        ),
        "SlackParser": Coverage(
            parser: SlackParser(),
            pairs: [
                FixturePair(fixture: "slack-dom-messages", golden: "slack-dom-messages-golden",
                            context: context(bundleID: ParserRegistry.slackBundleID, name: "Slack",
                                             title: "#general - Acme - Slack")),
                FixturePair(fixture: "slack-offset-dom-messages",
                            golden: "slack-offset-dom-messages-golden",
                            context: context(bundleID: ParserRegistry.slackBundleID, name: "Slack",
                                             title: "#general - Acme - Slack")),
                FixturePair(fixture: "slack-web-channel", golden: "slack-web-channel-golden",
                            context: context(bundleID: "com.google.Chrome", name: "Google Chrome",
                                             title: "general - Acme - Slack",
                                             url: "https://app.slack.com/client/T01/C02")),
                FixturePair(fixture: "slack-web-offset-dm", golden: "slack-web-offset-dm-golden",
                            context: context(bundleID: "com.google.Chrome", name: "Google Chrome",
                                             title: "Ada Lovelace - Acme - Slack",
                                             url: "https://app.slack.com/client/T01/D02")),
            ],
            blankContext: context(bundleID: ParserRegistry.slackBundleID, name: "Slack",
                                  title: "Slack")
        ),
        "DiscordParser": Coverage(
            parser: DiscordParser(),
            pairs: [
                FixturePair(fixture: "discord-messages", golden: "discord-messages-golden",
                            context: context(bundleID: ParserRegistry.discordBundleID, name: "Discord",
                                             title: "#general | Acme - Discord")),
                FixturePair(fixture: "discord-offset-messages", golden: "discord-messages-golden",
                            context: context(bundleID: ParserRegistry.discordBundleID, name: "Discord",
                                             title: "#general | Acme - Discord")),
            ],
            blankContext: context(bundleID: ParserRegistry.discordBundleID, name: "Discord",
                                  title: "Discord")
        ),
        "MessagesParser": Coverage(
            parser: MessagesParser(),
            pairs: [
                FixturePair(fixture: "messages-thread", golden: "messages-thread-golden",
                            context: context(bundleID: ParserRegistry.messagesBundleID, name: "Messages",
                                             title: "Priya Vantar")),
                FixturePair(fixture: "messages-offset-thread",
                            golden: "messages-offset-thread-golden",
                            context: context(bundleID: ParserRegistry.messagesBundleID, name: "Messages",
                                             title: "Priya Vantar")),
            ],
            blankContext: context(bundleID: ParserRegistry.messagesBundleID, name: "Messages",
                                  title: "Messages")
        ),
        "WhatsAppParser": Coverage(
            parser: WhatsAppParser(),
            pairs: [
                FixturePair(fixture: "whatsapp-bubbles", golden: "whatsapp-bubbles-golden",
                            context: context(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp",
                                             title: "WhatsApp")),
                FixturePair(fixture: "whatsapp-offset-bubbles",
                            golden: "whatsapp-offset-bubbles-golden",
                            context: context(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp",
                                             title: "WhatsApp")),
            ],
            blankContext: context(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp",
                                  title: "WhatsApp")
        ),
        "NotesParser": Coverage(
            parser: NotesParser(),
            pairs: [
                FixturePair(fixture: "notes-body", golden: "notes-body-golden",
                            context: context(bundleID: ParserRegistry.notesBundleID, name: "Notes",
                                             title: "Grocery list")),
                FixturePair(fixture: "notes-offset-shared", golden: "notes-offset-shared-golden",
                            context: context(bundleID: ParserRegistry.notesBundleID, name: "Notes",
                                             title: "Trip plan")),
            ],
            blankContext: context(bundleID: ParserRegistry.notesBundleID, name: "Notes",
                                  title: "Notes")
        ),
        "NotionParser": Coverage(
            parser: NotionParser(),
            pairs: [
                FixturePair(fixture: "notion-page", golden: "notion-page-golden",
                            context: context(bundleID: ParserRegistry.notionBundleID, name: "Notion",
                                             title: "Roadmap — Notion")),
                FixturePair(fixture: "notion-offset-peek", golden: "notion-offset-peek-golden",
                            context: context(bundleID: ParserRegistry.notionBundleID, name: "Notion",
                                             title: "Roadmap — Notion")),
            ],
            blankContext: context(bundleID: ParserRegistry.notionBundleID, name: "Notion",
                                  title: "Notion")
        ),
        "ObsidianParser": Coverage(
            parser: ObsidianParser(),
            pairs: [
                FixturePair(fixture: "obsidian-editor", golden: "obsidian-editor-golden",
                            context: context(bundleID: ParserRegistry.obsidianBundleID, name: "Obsidian",
                                             title: "Index rebuild - Research - Obsidian v1.5.3")),
                FixturePair(fixture: "obsidian-offset-preview",
                            golden: "obsidian-offset-preview-golden",
                            context: context(bundleID: ParserRegistry.obsidianBundleID, name: "Obsidian",
                                             title: "Index rebuild - Research - Obsidian v1.5.3")),
            ],
            blankContext: context(bundleID: ParserRegistry.obsidianBundleID, name: "Obsidian",
                                  title: "Obsidian")
        ),
        "GmailParser": Coverage(
            parser: GmailParser(),
            pairs: [
                FixturePair(fixture: "gmail-thread", golden: "gmail-thread-golden",
                            context: context(bundleID: "com.google.Chrome", name: "Google Chrome",
                                             title: nil,
                                             url: "https://mail.google.com/fixture/thread-alpha")),
                FixturePair(fixture: "gmail-offset-inbox", golden: "gmail-offset-inbox-golden",
                            context: context(bundleID: "com.google.Chrome", name: "Google Chrome",
                                             title: nil,
                                             url: "https://mail.google.com/fixture/inbox-alpha")),
            ],
            blankContext: context(bundleID: "com.google.Chrome", name: "Google Chrome", title: nil,
                                  url: "https://mail.google.com/fixture/inbox-alpha")
        ),
        "LinkedInMessagingParser": Coverage(
            parser: LinkedInMessagingParser(),
            pairs: [
                FixturePair(fixture: "linkedin-messaging", golden: "linkedin-messaging-golden",
                            context: context(bundleID: "com.google.Chrome", name: "Google Chrome",
                                             title: "Messaging | LinkedIn",
                                             url: "https://www.linkedin.com/messaging/thread/2-abc123def==")),
                FixturePair(fixture: "linkedin-offset-messaging",
                            golden: "linkedin-offset-messaging-golden",
                            context: context(bundleID: "com.google.Chrome", name: "Google Chrome",
                                             title: "Messaging | LinkedIn",
                                             url: "https://www.linkedin.com/messaging/thread/2-abc123def==")),
            ],
            blankContext: context(bundleID: "com.google.Chrome", name: "Google Chrome",
                                  title: "Messaging | LinkedIn",
                                  url: "https://www.linkedin.com/messaging")
        ),
        "TeamsWebParser": Coverage(
            parser: TeamsWebParser(),
            pairs: [
                FixturePair(fixture: "teams-web-chat", golden: "teams-web-chat-golden",
                            context: context(bundleID: "com.google.Chrome", name: "Google Chrome",
                                             title: "Chat | Microsoft Teams",
                                             url: "https://teams.microsoft.com/v2/#/conversations/19:abc?ctx=chat")),
                FixturePair(fixture: "teams-web-offset-chat", golden: "teams-web-offset-chat-golden",
                            context: context(bundleID: "com.google.Chrome", name: "Google Chrome",
                                             title: "Chat | Microsoft Teams",
                                             url: "https://teams.microsoft.com/v2/#/conversations/19:abc?ctx=chat")),
            ],
            blankContext: context(bundleID: "com.google.Chrome", name: "Google Chrome",
                                  title: "Chat | Microsoft Teams",
                                  url: "https://teams.microsoft.com/v2/")
        ),
        "OutlookWebParser": Coverage(
            parser: OutlookWebParser(),
            pairs: [
                FixturePair(fixture: "outlook-web-reading", golden: "outlook-web-reading-golden",
                            context: context(bundleID: "com.google.Chrome", name: "Google Chrome",
                                             title: "Quarterly index rebuild - Outlook",
                                             url: "https://outlook.office.com/mail/inbox/id/AAQkAD00?itemid=AAQkAD00&exvsurl=1")),
                FixturePair(fixture: "outlook-web-offset-list",
                            golden: "outlook-web-offset-list-golden",
                            context: context(bundleID: "com.google.Chrome", name: "Google Chrome",
                                             title: "Inbox - Outlook",
                                             url: "https://outlook.invalid/mail/inbox?itemid=fixture-item")),
            ],
            blankContext: context(bundleID: "com.google.Chrome", name: "Google Chrome",
                                  title: "Outlook", url: "https://outlook.office.com/mail/")
        ),
        "FinderParser": Coverage(
            parser: FinderParser(),
            pairs: [
                FixturePair(fixture: "finder-list", golden: "finder-list-golden",
                            context: context(bundleID: ParserRegistry.finderBundleID, name: "Finder",
                                             title: "project")),
                FixturePair(fixture: "finder-offset-copy", golden: "finder-offset-copy-golden",
                            context: context(bundleID: ParserRegistry.finderBundleID, name: "Finder",
                                             title: "project")),
            ],
            blankContext: context(bundleID: ParserRegistry.finderBundleID, name: "Finder",
                                  title: "Finder")
        ),
        "CalendarParser": Coverage(
            parser: CalendarParser(),
            pairs: [
                FixturePair(fixture: "calendar-event", golden: "calendar-event-golden",
                            context: context(bundleID: "com.apple.iCal", name: "Calendar",
                                             title: "Calendar")),
                FixturePair(fixture: "calendar-offset-event", golden: "calendar-offset-event-golden",
                            context: context(bundleID: "com.apple.iCal", name: "Calendar",
                                             title: "Calendar")),
            ],
            blankContext: context(bundleID: "com.apple.iCal", name: "Calendar", title: "Calendar")
        ),
        "FantasticalParser": Coverage(
            parser: FantasticalParser(),
            pairs: [
                FixturePair(fixture: "calendar-event", golden: "calendar-event-golden",
                            context: context(bundleID: "com.flexibits.fantastical2.mac",
                                             name: "Fantastical", title: "Fantastical")),
                FixturePair(fixture: "calendar-offset-event", golden: "calendar-offset-event-golden",
                            context: context(bundleID: "com.flexibits.fantastical2.mac",
                                             name: "Fantastical", title: "Fantastical")),
            ],
            blankContext: context(bundleID: "com.flexibits.fantastical2.mac", name: "Fantastical",
                                  title: "Fantastical")
        ),
        "RemindersParser": Coverage(
            parser: RemindersParser(),
            pairs: [
                FixturePair(fixture: "reminder-task", golden: "reminder-task-golden",
                            context: context(bundleID: "com.apple.reminders", name: "Reminders",
                                             title: "Reminders")),
                FixturePair(fixture: "reminders-offset-list", golden: "reminders-offset-list-golden",
                            context: context(bundleID: "com.apple.reminders", name: "Reminders",
                                             title: "Reminders")),
            ],
            blankContext: context(bundleID: "com.apple.reminders", name: "Reminders",
                                  title: "Reminders")
        ),
        // These parsers are registered in the legacy SourceParser bundle map rather than the
        // Phase D structured/host maps. Their route-specific tests remain the executable evidence.
        "MailParser": .legacy,
        "TeamsParser": .legacy,
        "MicrosoftToDoParser": .legacy,
        "TodoistParser": .legacy,
        "OmniFocusParser": .legacy,
        "TogglParser": .legacy,
        "WordParser": .legacy,
        "PagesParser": .legacy,
        "OutlookParser": .legacy,
        "SparkParser": .legacy,
    ]

    static func registeredParserNames(in registry: ParserRegistry) -> Set<String> {
        registry.registeredParserTypeNames
    }

    func testCoverageTableMatchesEveryParserRegisteredInTheRegistry() {
        let registry = ParserRegistry()
        XCTAssertEqual(Set(Self.coverage.keys), Self.registeredParserNames(in: registry))
        XCTAssertNil(registry.structuredParser(for: ParserRegistry.mailBundleID),
                     "Mail is registered only through the legacy AppleScript/compose route")
    }

    func testEveryCoveredHostIsReachableFromTheHostMap() {
        let registry = ParserRegistry()
        for (name, coverage) in Self.coverage {
            guard let parser = coverage.parser else { continue }
            for configuredHost in type(of: parser).config.hosts {
                let host = configuredHost.hasPrefix(".") ? "example\(configuredHost)" : configuredHost
                guard let parser = registry.structuredParser(forHost: host) else {
                    return XCTFail("no structured parser registered for host \(host)")
                }
                XCTAssertEqual(String(describing: type(of: parser)), name,
                               "host \(host) resolves to the wrong parser")
            }
        }
    }

    func testEveryCoveredParserExecutesItsFixtureGoldensAndBlankOutcome() throws {
        let blank = AXNode(role: "AXWindow", value: nil, title: nil, url: nil,
                           frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                           focused: false, children: [])
        for (name, coverage) in Self.coverage {
            guard let parser = coverage.parser, let blankContext = coverage.blankContext else {
                continue
            }
            XCTAssertGreaterThanOrEqual(coverage.pairs.count, 2,
                                        "\(name) needs at least two fixture/golden cases")
            for pair in coverage.pairs {
                let actual = try XCTUnwrap(
                    try parser.parse(try fixture(pair.fixture), context: pair.context),
                    "\(name) did not parse \(pair.fixture)"
                )
                XCTAssertEqual(actual, try goldenCapturedContent(pair.golden),
                               "\(name): \(pair.fixture)")
            }

            do {
                let outcome = try parser.parse(blank, context: blankContext)
                XCTAssertNil(outcome,
                             "\(name) must not claim a blank surface")
            } catch is ParserRefusal {
                // Known blank/toolbar-only surfaces are intentionally refused.
            }
        }
    }

    func testEveryCoveredParserHasAtLeastOneNonzeroOriginFixture() throws {
        for (parser, coverage) in Self.coverage {
            guard coverage.parser != nil else { continue }
            var sawNonzeroOrigin = false
            for pair in coverage.pairs {
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
        for coverage in Self.coverage.values {
            for pair in coverage.pairs {
                var offenders: [String] = []
                func visit(_ node: AXNode) {
                    if node.isSecureField, let value = node.value, !value.isEmpty {
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
        // M9 (spec §12 amendment, 2026-09-22) sanctions exactly one `.flagsChanged`-only NSEvent
        // monitor for the Option double-tap gesture; TypingObserverTests pins its file and mask.
        let sanctionedMonitorFile = sources.appendingPathComponent("MaxMi/OptionDoubleTapMonitor.swift")
            .standardizedFileURL
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains("CGEventTap"), "\(url.lastPathComponent)")
            if url.standardizedFileURL != sanctionedMonitorFile {
                XCTAssertFalse(text.contains("addGlobalMonitorForEvents"), "\(url.lastPathComponent)")
            }
        }
    }
}
