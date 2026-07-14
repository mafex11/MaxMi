import XCTest
@testable import MaxMiCore

final class CaptureAccumulatorTests: XCTestCase {
    func testAppendItemsAddsOnlyNewTail() {
        let result = CaptureAccumulator.merge(
            previous: "Alice: one\nBob: two",
            incoming: "Bob: two\nCarol: three",
            policy: .appendItems,
            maxCharacters: 10_000
        )
        XCTAssertEqual(result.content, "Alice: one\nBob: two\nCarol: three")
        XCTAssertEqual(result.addedItemCount, 1)
        XCTAssertTrue(result.changed)
    }

    func testAppendItemsPrependsNewlyRevealedOlderItems() {
        let result = CaptureAccumulator.merge(
            previous: "Bob: two\nCarol: three",
            incoming: "Alice: one\nBob: two",
            policy: .appendItems,
            maxCharacters: 10_000
        )
        XCTAssertEqual(result.content, "Alice: one\nBob: two\nCarol: three")
        XCTAssertEqual(result.addedItemCount, 1)
    }

    func testContainedVisibleWindowDoesNotEraseConversation() {
        let result = CaptureAccumulator.merge(
            previous: "one\ntwo\nthree\nfour",
            incoming: "two\nthree",
            policy: .appendItems,
            maxCharacters: 10_000
        )
        XCTAssertEqual(result.content, "one\ntwo\nthree\nfour")
        XCTAssertFalse(result.changed)
    }

    func testRollingTextPreservesDisjointVisibleSections() {
        let result = CaptureAccumulator.merge(
            previous: "Document title\nFirst section",
            incoming: "Third section\nConclusion",
            policy: .rollingText,
            maxCharacters: 10_000
        )
        XCTAssertTrue(result.content.contains("First section"))
        XCTAssertTrue(result.content.contains("Third section"))
    }

    func testEditedFullDocumentReplacesInsteadOfDuplicatingSnapshot() {
        let previous = "Title\nline one\nold middle\nline three\nConclusion"
        let incoming = "Title\nline one\nnew middle\nline three\nConclusion"
        let result = CaptureAccumulator.merge(
            previous: previous,
            incoming: incoming,
            policy: .rollingText,
            maxCharacters: 10_000
        )
        XCTAssertEqual(result.content, incoming)
        XCTAssertFalse(result.content.contains("old middle"))
    }

    func testReplaceStillSupportsTrueSnapshots() {
        let result = CaptureAccumulator.merge(
            previous: "old",
            incoming: "new",
            policy: .replace,
            maxCharacters: 10_000
        )
        XCTAssertEqual(result.content, "new")
    }

    func testAccumulatedContextIsBounded() {
        let incoming = String(repeating: "x", count: 5_000)
        let result = CaptureAccumulator.merge(
            previous: nil,
            incoming: incoming,
            policy: .rollingText,
            maxCharacters: 1_000
        )
        XCTAssertEqual(result.content.count, 1_000)
        XCTAssertTrue(result.content.contains("…"))
    }
}
