import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class ParserFallthroughTests: XCTestCase {
    func text(_ value: String, y: CGFloat = 0, x: CGFloat = 0) -> AXNode {
        AXNode(role: "AXStaticText", value: value, title: nil, url: nil,
               frame: CGRect(x: x, y: y, width: 100, height: 16), focused: false, children: [])
    }

    func window(_ children: [AXNode], title: String?) -> AXNode {
        AXNode(role: "AXWindow", value: nil, title: title, url: nil,
               frame: CGRect(x: 0, y: 0, width: 1_200, height: 800), focused: false,
               children: children)
    }

    /// A Slack window with sidebar text but no AXRow messages: SlackParser returns nil.
    func testRegisteredParserReturningNilNowFallsThroughToGenericContent() {
        let win = window([text("sidebar noise")], title: "general - Acme - Slack")
        let app = AppInfo(bundleID: ParserRegistry.slackBundleID, name: "Slack",
                          windowTitle: "general - Acme - Slack")
        let result = CaptureDispatch.parseDetailed(window: win, app: app, registry: ParserRegistry())
        guard case .parsedByFallback(let capture, let failedParser) = result else {
            return XCTFail("expected a generic fallback, got \(result)")
        }
        XCTAssertEqual(failedParser, "SlackParser")
        XCTAssertEqual(capture.content, "sidebar noise")
        XCTAssertEqual(capture.resolvedStructured.kind, .generic)
        XCTAssertNotNil(CaptureDispatch.parse(window: win, app: app, registry: ParserRegistry()),
                        "the convenience form returns the fallback capture too")
    }

    /// The 8 health-ledger marker has exactly one spelling, produced by exactly one function,
    /// so the Capture Health window and this assertion cannot drift apart.
    func testFallbackHealthMarkerIsComposedFromTheFailedParserName() {
        XCTAssertEqual(CaptureDispatch.fallbackParserID(failedParser: "SlackParser"),
                       "GenericPageExtractor.v2/fallback/SlackParser")
    }

    func testTheDispatchedFallbacksParserNameFeedsTheMarker() {
        let win = window([text("sidebar noise")], title: "general - Acme - Slack")
        let app = AppInfo(bundleID: ParserRegistry.slackBundleID, name: "Slack",
                          windowTitle: "general - Acme - Slack")
        guard case .parsedByFallback(_, let failedParser) = CaptureDispatch.parseDetailed(
            window: win, app: app, registry: ParserRegistry()
        ) else { return XCTFail("expected a generic fallback") }
        XCTAssertEqual(CaptureDispatch.fallbackParserID(failedParser: failedParser),
                       "GenericPageExtractor.v2/fallback/SlackParser")
    }

    // MARK: - Refusal versus not-handled (4f rule 3 refinement)

    /// Returns nil: "I can't read this shape". The generic extractor stands in.
    private struct NotHandling: SourceParser {
        func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? { nil }
    }

    /// Throws `ParserRefusal`: "this window must not be stored at all".
    private struct Refusing: SourceParser {
        func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
            throw ParserRefusal(reason: "test-refusal")
        }
    }

    /// Throws something else: a bug, not a decision. Degrade rather than lose the capture.
    private struct Breaking: SourceParser {
        struct Boom: Error {}
        func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? { throw Boom() }
    }

    private func dispatch(_ parser: any SourceParser) -> CaptureDispatch.ParseResult {
        // Readable generic content is present, so a fallback would definitely produce a capture:
        // .noContent below can only mean the fallback was never attempted.
        let win = window([text("readable body")], title: "Some Window")
        let app = AppInfo(bundleID: "com.example.seam", name: "Seam", windowTitle: "Some Window")
        return CaptureDispatch.parseDetailed(
            window: win, app: app,
            registry: ParserRegistry(parsers: ["com.example.seam": parser])
        )
    }

    func testRefusingParserYieldsNoContentAndNoGenericCapture() {
        XCTAssertEqual(dispatch(Refusing()), .noContent)
    }

    func testNilReturningParserStillFallsThroughToTheGenericExtractor() {
        guard case .parsedByFallback(let capture, let failedParser) = dispatch(NotHandling()) else {
            return XCTFail("expected .parsedByFallback")
        }
        XCTAssertEqual(failedParser, "NotHandling")
        XCTAssertEqual(capture.content, "readable body")
    }

    func testParserThrowingANonRefusalErrorStillFallsThroughToTheGenericExtractor() {
        guard case .parsedByFallback(let capture, let failedParser) = dispatch(Breaking()) else {
            return XCTFail("expected .parsedByFallback")
        }
        XCTAssertEqual(failedParser, "Breaking")
        XCTAssertEqual(capture.content, "readable body")
    }

    /// The gate this protects in production is `AppWiring.whatsAppIdentity`, which rejects a
    /// `.parsedByFallback` confirmation. That method is private to the MaxMi app target and reads
    /// `NSWorkspace.frontmostApplication` and `AXReader`, so it is not reachable from
    /// MaxMiCaptureTests. What IS testable — and what makes the gate moot for the shipping
    /// parser — is that WhatsApp refuses instead of falling through in the first place.
    func testWhatsAppWithNoChatIdentityRefusesRatherThanBeingRekeyedByTheFallback() {
        let win = window([text("Archived"), text("Some Contact", y: 60)], title: "WhatsApp")
        let app = AppInfo(bundleID: ParserRegistry.whatsAppBundleIDs[0], name: "WhatsApp",
                          windowTitle: "WhatsApp")
        XCTAssertEqual(
            CaptureDispatch.parseDetailed(window: win, app: app, registry: ParserRegistry()),
            .noContent
        )
    }

    func testNoContentIsStillReportedWhenEvenTheGenericPathFindsNothing() {
        let win = window([AXNode(role: "AXButton", value: nil, title: nil, url: nil,
                                 frame: CGRect(x: 0, y: 0, width: 10, height: 10),
                                 focused: false, children: [])],
                         title: "general - Acme - Slack")
        let app = AppInfo(bundleID: ParserRegistry.slackBundleID, name: "Slack",
                          windowTitle: "general - Acme - Slack")
        XCTAssertEqual(CaptureDispatch.parseDetailed(window: win, app: app,
                                                    registry: ParserRegistry()), .noContent)
    }

    func testUnregisteredAppStillUsesTheGenericPathAsParsed() {
        let win = window([text("note body")], title: "Note")
        let app = AppInfo(bundleID: "com.example.unknown", name: "Unknown", windowTitle: "Note")
        guard case .parsed(let capture) = CaptureDispatch.parseDetailed(
            window: win, app: app, registry: ParserRegistry()
        ) else { return XCTFail("expected .parsed") }
        XCTAssertEqual(capture.content, "note body")
        XCTAssertEqual(capture.sourceApp, "Unknown")
    }

    func testGenericParserProducesTypedGenericContentAtVersionTwo() throws {
        let win = window([
            AXNode(role: "AXHeading", value: "Title", title: nil, url: nil,
                   frame: CGRect(x: 0, y: 0, width: 100, height: 24), focused: false,
                   children: [], headingLevel: 1),
            text("body line", y: 40),
        ], title: "Note")
        let app = AppInfo(bundleID: "com.example.unknown", name: "Unknown", windowTitle: "Note")
        let structured = try XCTUnwrap(try GenericAXParser().parseStructured(window: win, app: app))
        guard case .generic(let page) = structured else { return XCTFail("expected .generic") }
        XCTAssertEqual(page.regions.map(\.kind), [.main])
        XCTAssertEqual(page.regions[0].blocks.map(\.type), [.heading(level: 1), .paragraph])

        let capture = try XCTUnwrap(try GenericAXParser().parse(window: win, app: app))
        XCTAssertEqual(capture.structured, structured)
        XCTAssertEqual(capture.content, "# Title\nbody line")
        XCTAssertEqual(capture.content, ContentRenderer.render(structured, style: .full))
        XCTAssertEqual(capture.parserVersion, 2)
    }

    /// Spec 4d whole-page semantics: a v2 generic page supersedes the previous one, so it also
    /// never reaches the legacy-shaped accumulation bridge.
    func testGenericParserDeclaresTheReplaceAccumulationPolicy() throws {
        let win = window([text("body line")], title: "Note")
        let app = AppInfo(bundleID: "com.example.unknown", name: "Unknown", windowTitle: "Note")
        let capture = try XCTUnwrap(try GenericAXParser().parse(window: win, app: app))
        XCTAssertEqual(capture.accumulationPolicy, .replace)
    }

    func testGenericParserReturnsNilForAWindowWithNoReadableContent() throws {
        let win = window([AXNode(role: "AXButton", value: nil, title: nil, url: nil,
                                 frame: CGRect(x: 0, y: 0, width: 10, height: 10),
                                 focused: false, children: [])], title: "Note")
        let app = AppInfo(bundleID: "com.example.unknown", name: "Unknown", windowTitle: "Note")
        XCTAssertNil(try GenericAXParser().parseStructured(window: win, app: app))
        XCTAssertNil(try GenericAXParser().parse(window: win, app: app))
    }

    func testDefaultParseStructuredImplementationReturnsNil() throws {
        struct Unmigrated: SourceParser {
            func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
                ParsedCapture(sourceApp: "X", sourceKey: "x:1", sourceTitle: nil, content: "a\nb")
            }
        }
        let win = window([], title: nil)
        let app = AppInfo(bundleID: "x", name: "X", windowTitle: nil)
        XCTAssertNil(try Unmigrated().parseStructured(window: win, app: app))
        let capture = try XCTUnwrap(try Unmigrated().parse(window: win, app: app))
        XCTAssertNil(capture.structured)
        XCTAssertEqual(capture.resolvedStructured,
                       LegacyContentAdapter.adapt(renderedContent: "a\nb", kind: .generic))
    }

    func testEnvelopeCarriesTheParsersStructuredValueAndAcceptsAnOverride() {
        let structured = CapturedContent.tasks([
            TaskItem(title: "Ship M8a", status: .open, due: nil, dueString: nil,
                     project: nil, tags: [], notes: nil),
        ])
        let migrated = ParsedCapture(
            sourceApp: "Reminders", sourceKey: "reminder:task:1", sourceTitle: "Ship M8a",
            content: "- [ ] Ship M8a", contentKind: .task, parserVersion: 2,
            accumulationPolicy: .replace, offscreenPolicy: .visibleOnly(), structured: structured
        )
        let envelope = migrated.envelope(cleanSourceKey: "reminder:task:1", parserID: "RemindersParser",
                                         trigger: .appActivated, truncated: false)
        XCTAssertEqual(envelope.structured, structured)
        XCTAssertEqual(envelope.content, "- [ ] Ship M8a")

        let override = CapturedContent.generic(GenericPage(
            regions: [Region(kind: .main, blocks: [Block(type: .paragraph, text: "override")])],
            focused: nil, url: nil))
        let overridden = migrated.envelope(cleanSourceKey: "reminder:task:1", parserID: "X",
                                           trigger: .appActivated, truncated: false,
                                           structured: override)
        XCTAssertEqual(overridden.structured, override)
        XCTAssertEqual(overridden.content, "override")
    }

    func testUnmigratedParsersEnvelopeGetsTheLegacyAdaptation() {
        let unmigrated = ParsedCapture(sourceApp: "Notes", sourceKey: "notes:x", sourceTitle: "x",
                                       content: "line one\nline two", contentKind: .document)
        let envelope = unmigrated.envelope(cleanSourceKey: "notes:x", parserID: "NotesParser",
                                           trigger: .appActivated, truncated: false)
        XCTAssertEqual(envelope.structured.kind, .generic)
        XCTAssertEqual(envelope.content, "line one\nline two")
    }
}
