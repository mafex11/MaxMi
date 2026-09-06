import XCTest
@testable import MaxMiCore

final class LegacyContentAdapterTests: XCTestCase {
    /// A corpus of strings shaped like real rendered captures, including the blank lines a
    /// rendered `.document` and a multi-segment `.terminal` produce.
    static let corpus: [String] = [
        "",
        "single line",
        "Alice: one\nBob: two\nCarol: three",
        "# Design notes\n\nIntro line\n## Regions\n- top\n  - nested",
        "$ swift test\n2 failures\n\n$ swift build\ncompiling\n… (running)",
        "URL: https://example.com/a\nbody\n## Sidebar\nDownloads",
        "leading blank\n\n\ntrailing newline\n",
        "\nstarts with a newline",
        "tabs\tand   spaces  ",
    ]

    func testAdaptProducesOneMainRegionOfParagraphs() {
        guard case .generic(let page) = LegacyContentAdapter.adapt(
            renderedContent: "one\ntwo", kind: .conversation
        ) else { return XCTFail("adapt always returns .generic") }
        XCTAssertEqual(page.regions.count, 1)
        XCTAssertEqual(page.regions[0].kind, .main)
        XCTAssertEqual(page.regions[0].blocks.map(\.text), ["one", "two"])
        XCTAssertEqual(page.regions[0].blocks.map(\.type), [.paragraph, .paragraph])
        XCTAssertNil(page.focused)
        XCTAssertNil(page.url)
    }

    func testAdaptIgnoresKindAndAlwaysReturnsGeneric() {
        for kind in CaptureContentKind.allCases {
            XCTAssertEqual(LegacyContentAdapter.adapt(renderedContent: "x", kind: kind).kind, .generic)
        }
    }

    func testRoundTripIsByteForByte() {
        for original in Self.corpus {
            let adapted = LegacyContentAdapter.adapt(renderedContent: original, kind: .generic)
            XCTAssertEqual(ContentRenderer.render(adapted, style: .full), original,
                           "round-trip must be byte-for-byte for \(original.debugDescription)")
        }
    }

    func testEnvelopeWithoutStructuredKeepsContentAndAdapts() {
        let envelope = CaptureEnvelope(
            sourceApp: "Notes", sourceKey: "notes:x", sourceTitle: "x",
            content: "note body\n\nsecond paragraph", contentKind: .document,
            parserID: "NotesParser", parserVersion: 1,
            accumulationPolicy: .rollingText, offscreenPolicy: .visibleOnly(),
            trigger: .appActivated, truncated: false
        )
        XCTAssertEqual(envelope.content, "note body\n\nsecond paragraph")
        XCTAssertEqual(envelope.structured.kind, .generic)
        XCTAssertEqual(ContentRenderer.render(envelope.structured, style: .full), envelope.content)
    }

    func testEnvelopeWithStructuredDerivesContentFromIt() {
        let structured = CapturedContent.conversation(Conversation(
            channel: "#dev", isGroup: true,
            messages: [Message(id: "1", sender: "Ana", text: "ping", timestamp: nil,
                               timeString: "09:20", isUser: false, isDraft: false)]
        ))
        let envelope = CaptureEnvelope(
            sourceApp: "Slack", sourceKey: "slack:acme/dev", sourceTitle: "dev",
            content: "IGNORED", contentKind: .conversation,
            parserID: "SlackParser", parserVersion: 2,
            accumulationPolicy: .appendItems, offscreenPolicy: .visibleOnly(),
            trigger: .conversationChanged, truncated: false,
            structured: structured
        )
        XCTAssertEqual(envelope.content, "(From: Ana)(sent 09:20): ping")
        XCTAssertEqual(envelope.structured, structured)
    }

    func testLegacyFactoryStillWorksAndCarriesGenericStructure() {
        let envelope = CaptureEnvelope.legacy(
            sourceApp: "Web", sourceKey: "https://example.com", sourceTitle: "T", content: "a\nb"
        )
        XCTAssertEqual(envelope.contentKind, .generic)
        XCTAssertEqual(envelope.parserID, "legacy")
        XCTAssertEqual(envelope.content, "a\nb")
        XCTAssertEqual(ContentRenderer.render(envelope.structured, style: .full), "a\nb")
    }
}
