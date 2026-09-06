import XCTest
import MaxMiCore
@testable import MaxMiCapture

/// Claims the fake native app and always answers.
struct StubNativeParser: StructuredParser {
    static let config = ParserConfig(app: "StubNative", bundleIDs: ["com.example.native"],
                                     attributeSet: ["AXDOMClassList", "AXDOMIdentifier"])
    func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        .document(Document(title: "native", blocks: [], author: .unknown, url: nil))
    }
}

/// Claims a host and never answers, so the fall-through path is exercised.
struct StubSilentHostParser: StructuredParser {
    static let config = ParserConfig(app: "StubSilent", bundleIDs: [],
                                     hosts: ["silent.example.com"])
    func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? { nil }
}

/// Refuses instead of answering, which must mean "store nothing" — never a fallback capture.
struct StubRefusingParser: StructuredParser {
    static let config = ParserConfig(app: "StubRefusing", bundleIDs: ["com.example.refusing"])
    func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        throw ParserRefusal(reason: "no-header")
    }
}

final class StructuredParserRoutingTests: XCTestCase {
    func window(_ text: String = "body") -> AXNode {
        AXNode(role: "AXWindow", value: nil, title: "W", url: nil,
               frame: CGRect(x: 0, y: 0, width: 800, height: 600), focused: false,
               children: [AXNode(role: "AXStaticText", value: text, title: nil, url: nil,
                                 frame: CGRect(x: 0, y: 0, width: 100, height: 16),
                                 focused: false, children: [])])
    }

    func context(bundleID: String, url: String? = nil) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: bundleID, name: "App", windowTitle: "W"), url: url)
    }

    // MARK: - Config defaults

    func testStructuredParserParseIsThrowingSoARefusalCanTravel() throws {
        // A refusal is not a fall-through: nothing is stored for this window, exactly as
        // `CaptureDispatch.parseDetailed` already does for a refusing SourceParser.
        let registry = ParserRegistry(structuredParsers: [StubRefusingParser()], hostParsers: [])
        XCTAssertThrowsError(try CaptureDispatch.structuredCapture(
            window: window(), context: context(bundleID: "com.example.refusing"),
            registry: registry)) { error in
            XCTAssertEqual(error as? ParserRefusal, ParserRefusal(reason: "no-header"))
        }
    }

    func testParserConfigDefaults() {
        let config = ParserConfig(app: "X", bundleIDs: ["a"])
        XCTAssertEqual(config.hosts, [])
        XCTAssertEqual(config.attributeSet, [])
        XCTAssertEqual(config.offscreenPolicy, .visibleOnly())
        XCTAssertFalse(config.preferOverNative)
        XCTAssertNil(config.minAppVersion)
    }

    func testParseContextConvenienceInitTakesWindowTitleFromTheApp() {
        let ctx = ParseContext(app: AppInfo(bundleID: "b", name: "App", windowTitle: "Title"))
        XCTAssertEqual(ctx.windowTitle, "Title")
        XCTAssertNil(ctx.url)
        XCTAssertNil(ctx.previousStructured)
    }

    // MARK: - Host extraction

    func testHostFromURLIsLowercasedAndNilSafe() {
        XCTAssertEqual(ParserRegistry.host(fromURL: "https://App.Slack.com/client/T1"), "app.slack.com")
        XCTAssertNil(ParserRegistry.host(fromURL: nil))
        XCTAssertNil(ParserRegistry.host(fromURL: "not a url"))
    }

    // MARK: - Registry routing

    func testStructuredParserResolvesByBundleID() {
        let registry = ParserRegistry(structuredParsers: [StubNativeParser()], hostParsers: [])
        XCTAssertTrue(registry.structuredParser(for: "com.example.native") is StubNativeParser)
        XCTAssertNil(registry.structuredParser(for: "com.example.unknown"))
    }

    func testStructuredParserResolvesByExactHostAndBySuffixEntry() {
        struct SuffixHostParser: StructuredParser {
            static let config = ParserConfig(app: "Suffix", bundleIDs: [],
                                             hosts: ["app.slack.com", ".slack.com"])
            func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
                .generic(GenericPage(regions: [], focused: nil, url: nil))
            }
        }
        let registry = ParserRegistry(structuredParsers: [], hostParsers: [SuffixHostParser()])
        XCTAssertTrue(registry.structuredParser(forHost: "app.slack.com") is SuffixHostParser)
        XCTAssertTrue(registry.structuredParser(forHost: "acme.slack.com") is SuffixHostParser,
                      "a leading-dot entry means suffix match")
        XCTAssertNil(registry.structuredParser(forHost: "slackalike.com"))
    }

    func testPreferOverNativeDecidesTheOrderBetweenHostAndNative() {
        struct EagerHostParser: StructuredParser {
            static let config = ParserConfig(app: "Eager", bundleIDs: [],
                                             hosts: ["eager.example.com"], preferOverNative: true)
            func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
                .document(Document(title: "host", blocks: [], author: .unknown, url: nil))
            }
        }
        struct PoliteHostParser: StructuredParser {
            static let config = ParserConfig(app: "Polite", bundleIDs: [],
                                             hosts: ["polite.example.com"], preferOverNative: false)
            func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
                .document(Document(title: "host", blocks: [], author: .unknown, url: nil))
            }
        }
        let registry = ParserRegistry(structuredParsers: [StubNativeParser()],
                                      hostParsers: [EagerHostParser(), PoliteHostParser()])
        XCTAssertTrue(registry.structuredParser(
            bundleID: "com.example.native", url: "https://eager.example.com/a") is EagerHostParser)
        XCTAssertTrue(registry.structuredParser(
            bundleID: "com.example.native", url: "https://polite.example.com/a") is StubNativeParser,
            "without preferOverNative the native parser keeps the window")
        XCTAssertTrue(registry.structuredParser(
            bundleID: "com.example.other", url: "https://polite.example.com/a") is PoliteHostParser,
            "with no native claim the host parser is used regardless")
    }

    func testForcedAttributesAreTheUnionOfTheClaimingParsersAttributeSet() {
        let registry = ParserRegistry(structuredParsers: [StubNativeParser()], hostParsers: [])
        XCTAssertEqual(registry.forcedAttributes(for: "com.example.native"),
                       ["AXDOMClassList", "AXDOMIdentifier"],
                       "the whole declared set is forced, not just the first entry")
        XCTAssertEqual(registry.forcedAttributes(for: "com.example.unknown"), [],
                       "an app with no v2 parser pays nothing for DOM attributes")
        XCTAssertTrue(registry.forcedAttributes(for: "com.example.native")
                        .isSubset(of: AXReader.domAttributeNames),
                      "only names AXReader honours may be forced")
    }

    func testTheRealRegistryExposesItsStructuredHosts() {
        // Every host entry must be lowercase, or the lookup can never hit it.
        for host in ParserRegistry().registeredStructuredHosts {
            XCTAssertEqual(host, host.lowercased(), "host entry \(host) must be lowercase")
        }
    }

    // MARK: - Dispatch

    func testAClaimingParserReturnsItsContentAndItsTypeName() throws {
        let registry = ParserRegistry(structuredParsers: [StubNativeParser()], hostParsers: [])
        let result = try CaptureDispatch.structuredCapture(
            window: window(), context: context(bundleID: "com.example.native"), registry: registry)
        guard case .parsed(let content, let parserName) = result else {
            return XCTFail("expected .parsed, got \(result)")
        }
        XCTAssertEqual(content, .document(Document(title: "native", blocks: [],
                                                   author: .unknown, url: nil)))
        XCTAssertEqual(parserName, "StubNativeParser")
    }

    func testAParserReturningNilFallsThroughToGenericPageExtractorAndNamesItself() throws {
        let registry = ParserRegistry(structuredParsers: [], hostParsers: [StubSilentHostParser()])
        let result = try CaptureDispatch.structuredCapture(
            window: window("real body"),
            context: context(bundleID: "com.example.browser", url: "https://silent.example.com/x"),
            registry: registry)
        guard case .fellThrough(let content, let notHandledBy) = result else {
            return XCTFail("expected .fellThrough, got \(result)")
        }
        XCTAssertEqual(notHandledBy, "StubSilentHostParser")
        guard case .generic(let page) = content else { return XCTFail("expected .generic") }
        XCTAssertEqual(page.url, "https://silent.example.com/x")
        XCTAssertEqual(page.regions.first?.blocks.map(\.text), ["real body"])
        // Phase A's helper is the ONE spelling of the §8 marker; Phase D adds no overload.
        XCTAssertEqual(CaptureDispatch.fallbackParserID(failedParser: try XCTUnwrap(notHandledBy)),
                       "GenericPageExtractor.v2/fallback/StubSilentHostParser")
    }

    func testNoRegisteredParserAlsoFallsThroughButNamesNoParser() throws {
        let registry = ParserRegistry(structuredParsers: [], hostParsers: [])
        let result = try CaptureDispatch.structuredCapture(
            window: window("plain"), context: context(bundleID: "com.example.nothing"),
            registry: registry)
        guard case .fellThrough(_, let notHandledBy) = result else {
            return XCTFail("expected .fellThrough, got \(result)")
        }
        XCTAssertNil(notHandledBy, "with nobody to blame there is no fallback marker at all")
    }

    func testTheTestSeamRegistryStillCompilesWithAnExplicitParserTable() {
        // Phase A's seam (ParserRegistry.init(parsers:), used by ParserFallthroughTests) gains two
        // stored properties and must still initialise them.
        let registry = ParserRegistry(parsers: [:])
        XCTAssertNil(registry.structuredParser(for: "com.example.native"))
        XCTAssertTrue(registry.registeredStructuredHosts.isEmpty)
    }

    func testFallThroughUsesTheClaimingParsersOffscreenPolicyBudget() throws {
        struct BoundedSilentParser: StructuredParser {
            static let config = ParserConfig(app: "Bounded", bundleIDs: ["com.example.bounded"],
                                             offscreenPolicy: .accessibilityScroll(maxSteps: 3))
            func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? { nil }
        }
        let registry = ParserRegistry(structuredParsers: [BoundedSilentParser()], hostParsers: [])
        // A node far below the window is only collected under an accessibilityScroll policy.
        let win = AXNode(role: "AXWindow", value: nil, title: nil, url: nil,
                         frame: CGRect(x: 0, y: 0, width: 800, height: 600), focused: false,
                         children: [AXNode(role: "AXStaticText", value: "far below", title: nil,
                                           url: nil,
                                           frame: CGRect(x: 0, y: 9_000, width: 100, height: 16),
                                           focused: false, children: [])])
        let result = try CaptureDispatch.structuredCapture(
            window: win, context: context(bundleID: "com.example.bounded"), registry: registry)
        guard case .fellThrough(.generic(let page), _) = result else {
            return XCTFail("expected a generic fall-through, got \(result)")
        }
        XCTAssertEqual(page.regions.first?.blocks.map(\.text), ["far below"])
    }
}
